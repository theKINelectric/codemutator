defmodule Mutator.Pipelines.PrepareRun do
  @moduledoc """
  The preparation railway (MVP_PLAN.md §3): one run input goes in, a prepared
  run with persisted sites comes out.

      prepare_workspace -> detect_language -> run_baseline -> scan_and_persist

  Domain failures (baseline failed, no sites, toolchain missing) are normal
  data on the railway — `{:error, reason}` short-circuits to `{:error, ...}`
  and the coordinator marks the run. Only unexpected exceptions reach the
  error pipe.
  """

  use FlowExtra.Pipeline

  alias Mutator.{Languages.Detector, Runs, Workspaces}
  alias Mutator.Execution.ProcessRunner

  # Elixir subjects cold-compile the whole dependency tree in the baseline
  # copy; 30 minutes covers Phoenix-scale projects on this host.
  @baseline_deadline_ms 30 * 60_000
  @baseline_floor_ms 30_000
  @mutant_cap_ms 20 * 60_000
  @run_budget_ms 30 * 60_000

  pipe :prepare_workspace
  pipe :detect_language
  pipe :run_baseline
  pipe :scan_and_persist

  error_pipe :on_unexpected_error

  defstruct [
    :run_id, :source_path, :ws, :adapter, :language, :argv_template, :env_template,
    :baseline_ms, :mutant_timeout_ms, :scan_result, :error, :baseline_worker
  ]

  # -- stages ----------------------------------------------------------------

  def prepare_workspace(%__MODULE__{} = data, _opts) do
    Runs.transition(Runs.get_run(data.run_id), "preparing")

    scope = run_scope(data.run_id)

    case Workspaces.prepare(Integer.to_string(data.run_id), data.source_path, scope) do
      {:ok, ws, _manifest} ->
        %{data | ws: ws}

      {:error, reason} ->
        %{data | error: {:workspace, reason}}
    end
  end

  def detect_language(%__MODULE__{error: nil} = data, _opts) do
    Runs.transition(Runs.get_run(data.run_id), "baselining", %{artifact_root: data.ws.run_dir})

    with {:ok, adapter} <- Detector.detect(data.ws.snapshot),
         {:ok, worker} <- Workspaces.make_worker(data.ws, "baseline"),
         # The baseline copy runs with private caches like any mutant worker.
         {:ok, %{argv: argv, env: env}} <- adapter.preflight(data.ws.snapshot, worker) do
      require Logger
      Logger.info("run #{data.run_id} baseline argv: #{Enum.join(argv, " ")}")
      Runs.transition(Runs.get_run(data.run_id), "baselining", %{toolchain: %{"argv" => argv}})
      %{
        data
        | adapter: adapter,
          language: adapter.name(),
          argv_template: argv,
          env_template: env,
          baseline_worker: worker
      }
    else
      {:error, reason} ->
        %{data | error: {:preflight, reason}}
    end
  end

  def detect_language(%__MODULE__{} = data, _opts), do: data

  def run_baseline(%__MODULE__{error: nil, argv_template: argv, env_template: env} = data, _opts) do
    cwd = data.baseline_worker.project
    log = Path.join(data.ws.logs, "baseline.log")

    case ProcessRunner.run(argv, cwd: cwd, log_path: log, timeout_ms: @baseline_deadline_ms, env: env) do
      {:ok, %{exit_code: 0, elapsed_ms: elapsed}} ->
        timeout_ms = mutant_timeout(elapsed)
        %{data | baseline_ms: elapsed, mutant_timeout_ms: timeout_ms}

      {:ok, %{tail: tail}} ->
        %{data | error: {:baseline_failed, String.slice(tail, 0, 2_000)}}

      {:timeout, _} ->
        %{data | error: {:baseline_failed, "baseline timed out"}}
    end
  end

  def run_baseline(%__MODULE__{} = data, _opts), do: data

  def scan_and_persist(%__MODULE__{error: nil} = data, _opts) do
    Runs.transition(Runs.get_run(data.run_id), "scanning")

    scope = run_scope(data.run_id)
    files = Detector.mutable_files(data.adapter, data.ws.snapshot, scope)

    sites =
      Enum.flat_map(files, fn rel ->
        source = File.read!(Path.join(data.ws.snapshot, rel))
        file_hash = Mutator.Scanner.file_hash(source)

        data.adapter.id()
        |> Mutator.Scanner.scan(rel, source)
        |> Enum.map(&%{&1 | file_hash: file_hash})
      end)

    total = length(sites)
    selected = limit_sites(sites, run_limit(data.run_id))
    count = Runs.insert_sites(data.run_id, selected)

    %{
      data
      | scan_result: %{
          files_scanned: length(files),
          candidates: total,
          selected: count
        }
    }
  end

  def scan_and_persist(%__MODULE__{} = data, _opts), do: data

  def on_unexpected_error(error, %__MODULE__{} = data, _opts) do
    %{data | error: {:unexpected, inspect(Exception.message(error))}}
  end

  # -- helpers ---------------------------------------------------------------

  defp mutant_timeout(baseline_ms) do
    # Warm-lane mutants recompile one file, not the tree: 3x the (cold)
    # baseline is generous headroom without timing out healthy runs.
    max(@baseline_floor_ms, 3 * baseline_ms) |> min(@mutant_cap_ms)
  end

  # Path substring filter from the submit form, e.g. "src/" narrows the
  # subject to its main source tree. Deterministic selection stays byte-order.
  defp run_scope(run_id) do
    case Runs.get_run(run_id) do
      %{scope_filter: nil} -> nil
      %{scope_filter: ""} -> nil
      %{scope_filter: f} -> f
      _ -> nil
    end
  end

  defp run_limit(run_id) do
    case Runs.get_run(run_id) do
      %{mutant_limit: nil} -> nil
      %{mutant_limit: n} when is_integer(n) -> n
      _ -> nil
    end
  end

  defp limit_sites(sites, nil), do: sites

  # Round-robin across files instead of byte-concatenated: a bounded sample
  # then covers the whole scope (a subject's first file can alone carry more
  # sites than the limit), staying deterministic — file order, then byte
  # order within a file.
  defp limit_sites(sites, n) when is_integer(n) and n >= 0 do
    sites
    |> Enum.group_by(& &1.file)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> interleave([])
    |> Enum.take(n)
    |> Enum.sort_by(& &1.byte_start)
  end

  defp limit_sites(sites, _), do: sites

  defp interleave([], acc), do: acc

  defp interleave([[] | rest], acc), do: interleave(rest, acc)

  defp interleave(groups, acc) do
    heads = Enum.map(groups, &hd/1)
    tails = Enum.map(groups, &tl/1)
    interleave(Enum.reject(tails, &(&1 == [])), acc ++ heads)
  end

  def run_budget_ms, do: @run_budget_ms
end
