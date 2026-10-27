defmodule Mutator.Runs do
  @moduledoc """
  The public context for mutation runs (MVP_PLAN.md §2). Web and coordinator
  code goes through here; nothing else touches the schemas directly.

  Score = killed / (killed + survived); invalid/error/cancelled outcomes are
  excluded from the score but counted visibly.
  """

  import Ecto.Query
  alias Mutator.Repo
  alias Mutator.Runs.{Outcome, Run, Site}

  @pubsub Mutator.PubSub

  # -- submission ------------------------------------------------------------

  # Dispatch deadline for the mutation phase (not a wall-clock guarantee):
  # in-flight work drains after the deadline. Cold lane starts and warm
  # mutant costs dominate; 60 minutes covers a 20-site qualification here.
  defp default_budget_ms, do: 60 * 60_000

  @doc """
  Queue a run. Validates the source directory immediately (cheaply); heavy
  work happens in the coordinator. `mutant_limit` bounds the number of sites
  dispatched (deterministic selection: byte order).
  """
  def submit_run(attrs) do
    %Run{}
    |> Run.changeset(%{
      source_path: Path.expand(attrs[:source_path] || ""),
      language: attrs[:language] || "auto",
      test_argv: attrs[:test_argv] || ["auto"],
      scope_filter: attrs[:scope_filter],
      mutant_limit: attrs[:mutant_limit],
      run_budget_ms: attrs[:run_budget_ms] || default_budget_ms(),
      state: "queued"
    })
    |> Repo.insert()
    |> case do
      {:ok, run} ->
        Mutator.Execution.Scheduler.notify()
        {:ok, run}

      error ->
        error
    end
  end

  def get_run(id), do: Repo.get(Run, id)

  def list_runs(limit \\ 50) do
    from(r in Run, order_by: [desc: r.inserted_at], limit: ^limit)
    |> Repo.all()
  end

  def list_active_runs do
    from(r in Run, where: r.state in ~w(queued preparing baselining scanning running))
    |> Repo.all()
  end

  @doc "Request cancellation: stops new dispatch; in-flight mutants finish."
  def cancel_run(id) do
    run = get_run(id)

    if run && Run.terminal?(run) do
      {:error, :already_terminal}
    else
      run
      |> Run.changeset(%{state: "cancelled"})
      |> Repo.update()
      |> tap(fn {:ok, _} -> broadcast(run.id, :cancelled) end)
    end
  end

  # -- lifecycle -------------------------------------------------------------

  def transition(run, state, extra \\ %{}) do
    changeset = Run.changeset(run, Map.put(extra, :state, state))

    if changeset.valid? do
      # Cancellation is terminal even when a pipeline stage holds an older
      # struct. The predicate and write are one SQL operation, so an in-flight
      # baseline cannot overwrite a concurrent cancellation.
      query = from(r in Run, where: r.id == ^run.id)
      query = if state == "cancelled", do: query, else: where(query, [r], r.state != "cancelled")

      changes =
        changeset.changes
        |> Map.put(:state, state)
        |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))

      Repo.update_all(query, set: Map.to_list(changes))
      updated = Repo.get!(Run, run.id)
      broadcast(updated.id, {:state, updated.state})
      {:ok, updated}
    else
      {:error, changeset}
    end
  end

  # -- sites -----------------------------------------------------------------

  def insert_sites(run_id, sites) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(sites, fn s ->
        %{
          run_id: run_id,
          site_key: s.site_key,
          file: s.file,
          function: s.function,
          function_line: s.function_line,
          function_end_line: s.function_end_line,
          line: s.line,
          byte_start: s.byte_start,
          byte_end: s.byte_end,
          file_hash: s.file_hash,
          operator: s.operator,
          original: s.original,
          replacement: s.replacement,
          scheduling_state: "pending",
          inserted_at: now,
          updated_at: now
        }
      end)

    {_, _} =
      Repo.insert_all(Site, entries,
        on_conflict: :nothing,
        conflict_target: [:run_id, :site_key]
      )

    count_sites(run_id, :pending)
  end

  def pending_sites(run_id) do
    from(s in Site,
      where: s.run_id == ^run_id and s.scheduling_state == "pending",
      order_by: [asc: s.byte_start, asc: s.file]
    )
    |> Repo.all()
  end

  def count_sites(run_id, state) do
    from(s in Site, where: s.run_id == ^run_id and s.scheduling_state == ^to_string(state))
    |> Repo.aggregate(:count)
  end

  def list_sites(run_id) do
    from(s in Site, where: s.run_id == ^run_id, order_by: [asc: s.file, asc: s.byte_start])
    |> Repo.all()
  end

  # State-only updates bypass the full changeset: unary-delete sites carry
  # an empty `replacement` by design, which validate_required would reject.
  def mark_site_dispatched(site) do
    site |> Ecto.Changeset.change(scheduling_state: "dispatched") |> Repo.update()
  end

  # -- outcomes --------------------------------------------------------------

  @doc """
  Record a terminal outcome. Idempotent: a repeated identical terminal write
  is a no-op; a conflicting terminal write raises an invariant error
  (MVP_PLAN.md §2). Counters update on the run row in the same transaction.
  """
  def record_outcome(run_id, site_id, attrs) do
    Repo.transaction(fn ->
      site = Repo.get!(Site, site_id)

      existing = Repo.get_by(Outcome, run_id: run_id, site_id: site_id)

      outcome =
        case existing do
          nil ->
            %Outcome{run_id: run_id, site_id: site_id}
            |> Outcome.changeset(attrs)
            |> Repo.insert!()

          %Outcome{} = o ->
            if o.status == attrs[:status] do
              o
            else
              raise "conflicting terminal outcome for site #{site_id}: had #{o.status}, got #{attrs[:status]}"
            end
        end

      site
      |> Ecto.Changeset.change(scheduling_state: "terminal")
      |> Repo.update!()

      update_counters!(run_id, outcome.status)
      outcome
    end)
    |> case do
      {:ok, outcome} ->
        broadcast(run_id, {:outcome, outcome.status})
        {:ok, outcome}

      error ->
        error
    end
  end

  def list_outcomes(run_id) do
    from(o in Outcome, where: o.run_id == ^run_id, preload: [:site], order_by: [asc: o.site_id])
    |> Repo.all()
  end

  def update_counters!(run_id, status) do
    run = Repo.get!(Run, run_id)

    {killed, survived, invalid, errors, cancelled} =
      {run.killed, run.survived, run.invalid, run.error_count, run.cancelled_count}

    {killed, survived, invalid, errors, cancelled} =
      case status do
        "killed" -> {killed + 1, survived, invalid, errors, cancelled}
        "survived" -> {killed, survived + 1, invalid, errors, cancelled}
        "invalid" -> {killed, survived, invalid + 1, errors, cancelled}
        "error" -> {killed, survived, invalid, errors + 1, cancelled}
        "cancelled" -> {killed, survived, invalid, errors, cancelled + 1}
        "interrupted" -> {killed, survived, invalid, errors, cancelled + 1}
      end

    run
    |> Run.changeset(%{
      killed: killed,
      survived: survived,
      invalid: invalid,
      error_count: errors,
      cancelled_count: cancelled,
      terminal_sites: run.terminal_sites + 1
    })
    |> Repo.update!()
  end

  # -- scoring ---------------------------------------------------------------

  @doc "killed / (killed + survived), or nil when nothing was scored."
  def score(%Run{killed: k, survived: s}) when k + s > 0, do: k / (k + s)
  def score(_), do: nil

  @doc "Per-function aggregation derived from outcomes (no extra table)."
  def function_scores(run_id) do
    from(o in Outcome,
      join: s in assoc(o, :site),
      where: o.run_id == ^run_id,
      group_by: [s.file, s.function],
      select: %{
        file: s.file,
        function: s.function,
        killed: sum(fragment("case when ? = 'killed' then 1 else 0 end", o.status)),
        survived: sum(fragment("case when ? = 'survived' then 1 else 0 end", o.status)),
        invalid: sum(fragment("case when ? = 'invalid' then 1 else 0 end", o.status)),
        error: sum(fragment("case when ? = 'error' then 1 else 0 end", o.status))
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      Map.put(row, :score, score(%Run{killed: row.killed || 0, survived: row.survived || 0}))
    end)
  end

  # -- pubsub ----------------------------------------------------------------

  def subscribe(run_id) do
    Phoenix.PubSub.subscribe(@pubsub, "run:#{run_id}")
  end

  def broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, "run:#{run_id}", {:mutator, run_id, event})
  end
end
