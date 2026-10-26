defmodule Mutator.Pipelines.ExecuteMutant do
  @moduledoc """
  The execution railway (MVP_PLAN.md §3). One site in, one terminal outcome
  persisted.

      execute [count: 2] -> record [count: 1]

  `execute` owns the whole worker lifecycle inside one stage callback —
  workspace copy, verified patch, subprocess run, classification, and cleanup
  (after/finally) — so each replica owns its resources. FlowExtra `count`
  replicates a stage; the coordinator is the fan-out/fan-in boundary, this
  pipeline transforms one site at a time.
  """

  use FlowExtra.Pipeline

  alias Mutator.{Runs, Workspaces}
  alias Mutator.Execution.ProcessRunner

  pipe(:execute, count: 2)
  pipe(:record, count: 1)

  error_pipe(:on_unexpected_error)

  defstruct [
    :run_id,
    :site_id,
    :site_key,
    :file,
    :byte_start,
    :byte_end,
    :original,
    :replacement,
    :file_hash,
    :timeout_ms,
    :argv,
    :env,
    :adapter,
    :ws_root,
    :lane,
    :status,
    :reason,
    :exit_code,
    :elapsed_ms,
    :log_path,
    :tail,
    :error
  ]

  # -- stages ----------------------------------------------------------------

  def execute(%__MODULE__{} = data, _opts) do
    run_dir = data.ws_root

    ws = %Workspaces{
      root: Path.dirname(run_dir),
      run_dir: run_dir,
      snapshot: Path.join(run_dir, "snapshot"),
      logs: Path.join(run_dir, "logs"),
      workers: Path.join(run_dir, "workers"),
      scratch: Path.join(run_dir, "scratch")
    }

    lane_key = data.lane || "0"
    lane_project = Path.join([ws.workers, "lane-#{lane_key}", "project"])

    lane = %{project: lane_project}
    execute_in_lane(data, ws, lane)
  end

  # Patch in place, run, always restore (MVP_PLAN.md §3: resource ownership
  # inside one stage callback). The lane tree persists across its mutants, so
  # its caches stay warm; before each patch the file hash and the original
  # bytes are verified against the snapshot, so a dirty lane aborts as
  # `stale_site` instead of testing the wrong code.
  defp execute_in_lane(%__MODULE__{} = data, _ws, lane) do
    file_path = Path.join(lane.project, data.file)
    log_path = Path.join([data.ws_root, "logs", "#{data.site_key}.log"])

    with {:ok, source} <- File.read(file_path),
         :ok <- verify_span(source, data),
         :ok <- File.write(file_path, patch(source, data)) do
      try do
        result =
          ProcessRunner.run(data.argv,
            cwd: lane.project,
            log_path: log_path,
            timeout_ms: data.timeout_ms,
            env: data.env
          )

        classify_into(data, result)
      after
        # Always restore, even on timeout or crash: the lane serves the next
        # mutant, and verify_span catches any residue as `stale_site`.
        :ok = restore(file_path, source)
      end
    else
      {:error, :stale_site} ->
        %{data | status: "error", reason: "stale_site"}

      {:error, reason} ->
        %{data | status: "error", reason: inspect(reason)}
    end
  end

  defp verify_span(source, data) do
    actual_hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

    cond do
      actual_hash != data.file_hash ->
        {:error, :stale_site}

      binary_part(source, data.byte_start, data.byte_end - data.byte_start) != data.original ->
        {:error, :stale_site}

      true ->
        :ok
    end
  end

  defp patch(source, data) do
    binary_part(source, 0, data.byte_start) <>
      data.replacement <>
      binary_part(source, data.byte_end, byte_size(source) - data.byte_end)
  end

  defp restore(file_path, original_source) do
    File.write(file_path, original_source)
  end

  defp classify_into(data, {:timeout, %{elapsed_ms: elapsed, log_path: log}}) do
    %{data | status: "killed", reason: "timeout", elapsed_ms: elapsed, log_path: log}
  end

  defp classify_into(
         data,
         {:ok, %{exit_code: code, elapsed_ms: elapsed, tail: tail, log_path: log}}
       ) do
    data = %{data | exit_code: code, elapsed_ms: elapsed, tail: tail, log_path: log}

    case data.adapter.classify({:ok, %{exit_code: code, tail: tail}}) do
      :survived -> %{data | status: "survived"}
      {:killed, reason} -> %{data | status: "killed", reason: Atom.to_string(reason)}
      :invalid -> %{data | status: "invalid"}
      :unclassified -> %{data | status: "error", reason: "unclassified"}
    end
  end

  def record(%__MODULE__{} = data, _opts) do
    reason = data.reason || error_reason(data.error)

    attrs = %{
      status: data.status || "error",
      reason: reason,
      phase: "mutant",
      exit_code: data.exit_code,
      elapsed_ms: data.elapsed_ms,
      log_path: data.log_path,
      log_excerpt: data.tail && String.slice(data.tail, 0, 2_000)
    }

    case Runs.record_outcome(data.run_id, data.site_id, attrs) do
      {:ok, _} -> data
      {:error, reason} -> %{data | error: {:record, inspect(reason)}}
    end
  end

  def on_unexpected_error(error, %__MODULE__{} = data, _opts) do
    attrs = %{status: "interrupted", reason: inspect(Exception.message(error)), phase: "execute"}

    Runs.record_outcome(data.run_id, data.site_id, attrs)
    data
  end

  defp error_reason(nil), do: nil
  defp error_reason({tag, detail}), do: "#{tag}: #{detail}"
  defp error_reason(other), do: inspect(other)
end
