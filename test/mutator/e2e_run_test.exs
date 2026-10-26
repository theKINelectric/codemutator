defmodule Mutator.E2ERunTest do
  @moduledoc """
  M4 gate: a real Zig subject through the whole engine — scheduler picks the
  queued run, PrepareRun clones + baselines + scans, ExecuteMutant dispatches
  through the flow_extra pipeline, outcomes land in SQLite, the score
  computes, and the original subject directory is byte-identical.

  Requires the mise zig 0.16.0 toolchain (verified by binary version).
  """

  use Mutator.DataCase, async: false

  alias Mutator.{Runs, Workspaces}

  @fixture Path.expand("../fixtures/zig/mathlib", __DIR__)
  @ws_root Path.expand("../tmp_e2e", __DIR__)

  @tag :e2e
  @tag timeout: 300_000
  test "full mutation run against the zig fixture" do
    Ecto.Adapters.SQL.Sandbox.mode(Mutator.Repo, {:shared, self()})

    File.rm_rf(@ws_root)
    Application.put_env(:mutator, :workspace_root, @ws_root)
    on_exit(fn -> Application.delete_env(:mutator, :workspace_root) end)

    before = Workspaces.manifest(@fixture)

    {:ok, run} = Runs.submit_run(%{source_path: @fixture, mutant_limit: 8})
    run_id = run.id

    # give the scheduler the whole run's budget; poll for a terminal state
    terminal = wait_terminal(run_id, 15 * 60_000)

    assert terminal in ~w(completed),
           "run ended in #{terminal}: #{inspect(Runs.get_run(run_id).failure_reason)}"

    run = Runs.get_run(run_id)
    outcomes = Runs.list_outcomes(run_id)
    sites = Runs.list_sites(run_id)

    File.write!(
      "/tmp/e2e_outcomes.txt",
      Enum.map_join(outcomes, "\n", fn o ->
        "#{o.site.function}:#{o.site.line} #{o.site.original}->#{o.site.replacement} = #{o.status} (#{o.reason}) exit=#{o.exit_code} #{o.elapsed_ms}ms"
      end)
    )

    assert length(sites) == 8, "mutant limit respected"
    assert length(outcomes) == 8, "one terminal row per selected site"
    assert run.terminal_sites == 8
    assert run.killed >= 1, "the add(+)/sign(==) mutations must be killed"
    assert run.survived >= 1, "the clamp boundary mutations must survive"
    assert run.invalid >= 0

    score = Runs.score(run)
    assert is_float(score) and score > 0.0 and score < 1.0

    # outcomes join back to their sites with verified patches
    assert Enum.all?(outcomes, &(&1.site.file in ["src/math.zig"]))

    # per-function aggregation derives from outcomes
    fns = Runs.function_scores(run_id)
    assert Enum.any?(fns, &(&1.function == "add"))
    assert Enum.any?(fns, &(&1.function == "clamp"))

    # the original subject is untouched, and the workspace is cleaned up
    assert Workspaces.same_manifest?(before, Workspaces.manifest(@fixture))
    assert wait_cleaned(run_id), "workspace dir still present after terminal state"
  end

  @fixture_rust Path.expand("../fixtures/rust/mathlib", __DIR__)

  @tag :e2e
  @tag timeout: 300_000
  test "full mutation run against the rust fixture" do
    Ecto.Adapters.SQL.Sandbox.mode(Mutator.Repo, {:shared, self()})

    File.rm_rf(@ws_root)
    Application.put_env(:mutator, :workspace_root, @ws_root)
    on_exit(fn -> Application.delete_env(:mutator, :workspace_root) end)

    before = Workspaces.manifest(@fixture_rust)

    {:ok, run} = Runs.submit_run(%{source_path: @fixture_rust, mutant_limit: 9})
    run_id = run.id

    terminal = wait_terminal(run_id, 15 * 60_000)

    assert terminal in ~w(completed),
           "run ended in #{terminal}: #{inspect(Runs.get_run(run_id).failure_reason)}"

    run = Runs.get_run(run_id)
    outcomes = Runs.list_outcomes(run_id)
    sites = Runs.list_sites(run_id)

    File.write!(
      "/tmp/e2e_rust_outcomes.txt",
      Enum.map_join(outcomes, "\n", fn o ->
        "#{o.site.function}:#{o.site.line} #{o.site.original}->#{o.site.replacement} = #{o.status} (#{o.reason}) exit=#{o.exit_code} #{o.elapsed_ms}ms"
      end)
    )

    assert length(sites) == 9, "expected 9 sites in the fixture, got #{length(sites)}"
    assert length(outcomes) == 9
    assert run.terminal_sites == 9
    assert run.killed >= 2, "the add(+), clamp(&&), and sign(-1/literal) mutations must be killed"

    assert run.survived >= 1,
           "the normalized()<lo boundary and equivalent literal mutations must survive"

    assert Enum.all?(outcomes, &(&1.site.file in ["src/lib.rs"]))

    fns = Runs.function_scores(run_id)
    assert Enum.any?(fns, &(&1.function == "add"))
    assert Enum.any?(fns, &(&1.function == "clamp"))
    assert Enum.any?(fns, &(&1.function == "sign"))

    # test bodies are never mutated, and the original subject is untouched
    refute Enum.any?(sites, &(&1.function in ["test_add", "test_clamp", "test_sign"]))
    assert Workspaces.same_manifest?(before, Workspaces.manifest(@fixture_rust))
    assert wait_cleaned(run_id), "workspace dir still present after terminal state"
  end

  @tag :e2e
  @tag timeout: 300_000
  test "scoped rust submission detects, baselines, and mutates under src/" do
    # Supervisor regression: scoped copies used to omit Cargo.toml/Cargo.lock
    # and fail with `{:preflight, :no_language_detected}`.
    Ecto.Adapters.SQL.Sandbox.mode(Mutator.Repo, {:shared, self()})

    File.rm_rf(@ws_root)
    Application.put_env(:mutator, :workspace_root, @ws_root)
    on_exit(fn -> Application.delete_env(:mutator, :workspace_root) end)

    before = Workspaces.manifest(@fixture_rust)

    {:ok, run} =
      Runs.submit_run(%{source_path: @fixture_rust, scope_filter: "src/", mutant_limit: 4})

    run_id = run.id
    terminal = wait_terminal(run_id, 15 * 60_000)

    assert terminal == "completed",
           "scoped run ended in #{terminal}: #{inspect(Runs.get_run(run_id).failure_reason)}"

    run = Runs.get_run(run_id)
    sites = Runs.list_sites(run_id)
    outcomes = Runs.list_outcomes(run_id)

    assert length(sites) == 4
    assert length(outcomes) == 4
    assert Enum.all?(sites, &String.starts_with?(&1.file, "src/"))
    assert run.killed + run.survived >= 1

    assert Workspaces.same_manifest?(before, Workspaces.manifest(@fixture_rust))
    assert wait_cleaned(run_id), "workspace dir still present after terminal state"
  end

  @tag :e2e
  @tag timeout: 300_000
  test "cancel drains pending sites and reaches cancelled, not failed" do
    # Regression (run #4 receipt): RunCoordinator.mark_remaining/3 passed the
    # Run struct to Runs.pending_sites/1 — the query cast crashed the drain
    # and the run's terminal state was recorded as `failed {:crash,...}`
    # instead of `cancelled`.
    Ecto.Adapters.SQL.Sandbox.mode(Mutator.Repo, {:shared, self()})

    File.rm_rf(@ws_root)
    Application.put_env(:mutator, :workspace_root, @ws_root)
    on_exit(fn -> Application.delete_env(:mutator, :workspace_root) end)

    before = Workspaces.manifest(@fixture_rust)

    {:ok, run} =
      Runs.submit_run(%{source_path: @fixture_rust, scope_filter: "src/", mutant_limit: 9})

    run_id = run.id
    assert wait_state(run_id, "running", 120_000), "run never reached running"
    {:ok, _} = Runs.cancel_run(run_id)

    terminal = wait_terminal(run_id, 15 * 60_000)

    assert terminal == "cancelled",
           "cancelled run ended in #{terminal}: #{inspect(Runs.get_run(run_id).failure_reason)}"

    run = Runs.get_run(run_id)
    assert is_nil(run.failure_reason)

    assert Enum.all?(
             Runs.list_outcomes(run_id),
             &(&1.status in ["killed", "survived", "invalid", "error", "cancelled"])
           )

    assert Workspaces.same_manifest?(before, Workspaces.manifest(@fixture_rust))
    assert wait_cleaned(run_id), "workspace dir still present after cancelled terminal state"
  end

  defp wait_state(run_id, target, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_state(run_id, target, deadline)
  end

  defp do_wait_state(run_id, target, deadline) do
    state = Runs.get_run(run_id).state

    cond do
      state == target ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(500)
        do_wait_state(run_id, target, deadline)
    end
  end

  defp wait_terminal(run_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait(run_id, deadline)
  end

  defp do_wait(run_id, deadline) do
    run = Runs.get_run(run_id)

    if Mutator.Runs.Run.terminal?(run) or System.monotonic_time(:millisecond) > deadline do
      run.state
    else
      Process.sleep(1_000)
      do_wait(run_id, deadline)
    end
  end

  # Terminal state is committed before the coordinator finishes removing the
  # workspace — a direct DB poll can observe `completed` while `rm_rf` of the
  # lane trees is still running. Poll for the removal too.
  defp wait_cleaned(run_id) do
    dir = Path.join(@ws_root, Integer.to_string(run_id))
    do_wait_cleaned(dir, System.monotonic_time(:millisecond) + 30_000)
  end

  defp do_wait_cleaned(dir, deadline) do
    cond do
      not File.exists?(dir) ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(250)
        do_wait_cleaned(dir, deadline)
    end
  end
end
