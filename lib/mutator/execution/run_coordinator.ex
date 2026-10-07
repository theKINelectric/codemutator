defmodule Mutator.Execution.RunCoordinator do
  @moduledoc """
  Per-run lifecycle owner (MVP_PLAN.md §2, §3).

  1. Runs `Mutator.Pipelines.PrepareRun` once (workspace, detect, baseline,
     scan, persist sites).
  2. Starts one `ExecuteMutant` pipeline (admission capacity 4, execute stage
     replicated ×2) and dispatches pending sites through at most 4 supervised
     caller tasks calling the pipeline with `:infinity` — subprocess and run
     deadlines are enforced inside the runner, and the coordinator enforces
     the overall run budget. A caller timeout does not cancel FlowExtra work,
     so callers never time out (MVP_PLAN.md §3).
  3. Fan-in: when every selected site is terminal, finalizes the run
     (completed / failed / cancelled / budget_exhausted), cleans up the
     workspace, and broadcasts.

  A baseline failure dispatches zero mutants. Cancellation stops new
  dispatches; in-flight mutants finish (bounded by their own deadlines) and
  every still-pending site is explicitly cancelled.
  """

  require Logger
  import Ecto.Query

  alias Mutator.{Runs, Workspaces}
  alias Mutator.Pipelines.{ExecuteMutant, PrepareRun}

  # One lane per execution slot; in-flight is capped at the lane count so
  # each in-flight mutant owns its lane tree exclusively.
  @lanes 2
  @max_in_flight @lanes
  @poll_ms 100

  @doc "Run one run to a terminal state. Blocks; call from a supervised task."
  def run(run_id) do
    run = Runs.get_run(run_id)

    case PrepareRun.call(prepare_pipeline(run_id), %PrepareRun{run_id: run_id, source_path: run.source_path}, :infinity) do
      %PrepareRun{error: nil} = prepared ->
        dispatch_loop(run_id, prepared)

      %PrepareRun{error: reason} ->
        fail_run(run_id, reason)

      {:error, reason} ->
        fail_run(run_id, {:pipeline, inspect(reason)})

      other ->
        fail_run(run_id, {:unexpected, inspect(other)})
    end
  rescue
    e ->
      Logger.error("run #{run_id} crashed: #{Exception.message(e)}")
      fail_run(run_id, {:crash, Exception.message(e)})
  end

  defp prepare_pipeline(run_id) do
    PrepareRun.start(%{run_id: run_id})
  end

  # -- dispatch loop ---------------------------------------------------------

  defp dispatch_loop(run_id, %PrepareRun{} = prepared) do
    case Runs.list_sites(run_id) do
      [] ->
        # Zero selected sites completes with N/A score.
        finalize(run_id, "completed")

      sites ->
        lanes =
          Map.new(0..(@lanes - 1), fn i ->
            {:ok, lane} = Workspaces.make_lane(prepared.ws, Integer.to_string(i))
            {Integer.to_string(i), lane}
          end)

        pipeline = ExecuteMutant.start(%{admission_capacity: @max_in_flight + 2})
        budget_ms = Runs.get_run(run_id).run_budget_ms || PrepareRun.run_budget_ms()

        Runs.transition(Runs.get_run(run_id), "running", %{run_budget_ms: budget_ms})

        budget_deadline = System.monotonic_time(:millisecond) + budget_ms +
                            (prepared.baseline_ms || 0)

        {:ok, task_sup} = Task.Supervisor.start_link(name: via(run_id))

        try do
          loop(
            %{
              run_id: run_id,
              pipeline: pipeline,
              task_sup: task_sup,
              prepared: prepared,
              pending: sites,
              in_flight: %{},
              slot_counter: 0,
              lanes: lanes,
              budget_deadline: budget_deadline
            }
          )
        after
          ExecuteMutant.stop(pipeline)
          GenServer.stop(task_sup)
        end
    end
  end

  defp via(run_id), do: {:via, :global, {:mutator, {__MODULE__, run_id}}}

  defp loop(%{pending: [], in_flight: inflight} = state) when map_size(inflight) == 0 do
    finish_all(state)
  end

  defp loop(state) do
    state = reap(state)
    state = maybe_fill(state)

    cond do
      state.pending == [] and map_size(state.in_flight) == 0 ->
        finish_all(state)

      cancelled?(state.run_id) ->
        drain_and_cancel(state)

      System.monotonic_time(:millisecond) > state.budget_deadline ->
        drain_and_exhaust(state)

      true ->
        Process.sleep(@poll_ms)
        loop(state)
    end
  end

  # A mutant owns its lane tree exclusively: dispatch waits for a free lane.
  defp maybe_fill(%{in_flight: inflight, pending: pending} = state)
       when map_size(inflight) >= @lanes or pending == [],
       do: state

  defp maybe_fill(state) do
    busy_lanes =
      state.in_flight |> Map.values() |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    free_lanes = Enum.reject(Map.keys(state.lanes), &(&1 in busy_lanes))

    if free_lanes == [] or cancelled?(state.run_id) or
         System.monotonic_time(:millisecond) > state.budget_deadline do
      state
    else
      [lane_key | _] = free_lanes
      [site | rest] = state.pending
      n = state.slot_counter

      {:ok, pid} =
        Task.Supervisor.start_child(state.task_sup, fn ->
          dispatch_site(state, site, n, lane_key)
        end)

      Runs.mark_site_dispatched(site)

      %{
        state
        | pending: rest,
          in_flight: Map.put(state.in_flight, pid, {site.id, lane_key}),
          slot_counter: n + 1
      }
    end
  end

  defp reap(%{in_flight: inflight, run_id: run_id} = state) do
    {dead, alive} = Enum.split_with(inflight, fn {pid, _} -> not Process.alive?(pid) end)

    state =
      Enum.reduce(dead, state, fn {_pid, entry}, acc ->
        {site_id, _lane_key} = entry

        has_outcome =
          from(o in Mutator.Runs.Outcome, where: o.site_id == ^site_id)
          |> Mutator.Repo.exists?()

        unless has_outcome do
          Runs.record_outcome(run_id, site_id, %{
            status: "interrupted",
            reason: "caller task died before a terminal outcome",
            phase: "dispatch"
          })
        end

        rebuild_lane(acc, elem(entry, 1))
      end)

    %{state | in_flight: Map.new(alive)}
  end

  # A lane whose last mutant died may carry patch/restore residue; rebuild it
  # from the snapshot so the slot keeps serving. Rebuild failure surfaces on
  # the next site as stale_site (safe abort).
  defp rebuild_lane(state, lane_key) do
    case Workspaces.make_lane(state.prepared.ws, lane_key) do
      {:ok, lane} -> %{state | lanes: Map.put(state.lanes, lane_key, lane)}
      {:error, _} -> state
    end
  end


  defp dispatch_site(state, site, _dispatch_index, lane_key) do
    lane = state.lanes[lane_key]

    {:ok, %{argv: argv, env: env}} =
      state.prepared.adapter.preflight(state.prepared.ws.snapshot, lane)
    input = %ExecuteMutant{
      run_id: state.run_id,
      site_id: site.id,
      site_key: site.site_key,
      file: site.file,
      byte_start: site.byte_start,
      byte_end: site.byte_end,
      original: site.original,
      replacement: site.replacement,
      file_hash: site.file_hash,
      timeout_ms: state.prepared.mutant_timeout_ms,
      argv: argv,
      env: env,
      adapter: state.prepared.adapter,
      ws_root: state.prepared.ws.run_dir,
      lane: lane_key
    }

    ExecuteMutant.call(state.pipeline, input, :infinity)
  catch
    # A definite admission refusal leaves the site pending for a later pass
    # (FlowExtra.AdmissionError); an uncertain outcome is interrupted work —
    # never an invented success or failure.
    :error, %FlowExtra.AdmissionError{} = e ->
      require Logger
      Logger.warning("site #{site.id} refused: #{inspect(e.__struct__)}")
      {:error, :refused}
  end

  # -- finalization ----------------------------------------------------------

  defp finish_all(state) do
    cond do
      cancelled?(state.run_id) -> finalize(state.run_id, "cancelled")
      true -> finalize(state.run_id, "completed")
    end
  end

  defp drain_and_cancel(state) do
    wait_for_in_flight(state)
    mark_remaining(state.run_id, "cancelled", "run cancelled")
    finalize(state.run_id, "cancelled")
  end

  defp drain_and_exhaust(state) do
    wait_for_in_flight(state)
    mark_remaining(state.run_id, "cancelled", "budget exhausted")
    finalize(state.run_id, "budget_exhausted")
  end


  defp wait_for_in_flight(state) do
    unless map_size(state.in_flight) == 0 do
      Process.sleep(@poll_ms)
      state = reap(state)
      wait_for_in_flight(state)
    end
  end

  defp mark_remaining(run_id, status, reason) do
    run = Runs.get_run(run_id)

    run
    |> Runs.pending_sites()
    |> Enum.each(fn site ->
      Runs.record_outcome(run_id, site.id, %{status: status, reason: reason, phase: "dispatch"})
    end)
  end

  defp finalize(run_id, state_name) do
    run = Runs.get_run(run_id)
    Runs.transition(run, state_name)

    unless System.get_env("MUTATOR_KEEP_WS") == "1" do
      Workspaces.cleanup_run(Integer.to_string(run_id))
    end

    :ok
  end

  defp fail_run(run_id, reason) do
    run = Runs.get_run(run_id)

    Runs.transition(run, "failed", %{
      failure_reason: inspect(reason) |> String.slice(0, 2_000)
    })

    keep = Application.get_env(:mutator, :keep_failed_workspace, false) or System.get_env("MUTATOR_KEEP_WS") == "1"

    unless keep do
      Workspaces.cleanup_run(Integer.to_string(run_id))
    end
  end

  defp cancelled?(run_id) do
    match?(%{state: "cancelled"}, Runs.get_run(run_id))
  end
end
