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
    assert terminal in ~w(completed), "run ended in #{terminal}: #{inspect(Runs.get_run(run_id).failure_reason)}"

    run = Runs.get_run(run_id)
    outcomes = Runs.list_outcomes(run_id)
    sites = Runs.list_sites(run_id)

    File.write!("/tmp/e2e_outcomes.txt", Enum.map_join(outcomes, "\n", fn o ->
      "#{o.site.function}:#{o.site.line} #{o.site.original}->#{o.site.replacement} = #{o.status} (#{o.reason}) exit=#{o.exit_code} #{o.elapsed_ms}ms"
    end))

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
    refute File.exists?(Path.join(@ws_root, Integer.to_string(run_id)))
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
end
