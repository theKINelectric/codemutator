defmodule Mutator.JavaScriptE2ETest do
  @moduledoc """
  Opt-in service qualification for the explicit Node test profile.

  Runs physical temporary fixtures through the scheduler, baseline, shared AST
  scanner, worker patch, trusted runner and persisted outcome APIs. Requires
  Node with TypeScript stripping and an explicit CODEMUTATOR_E2E_TSC compiler
  path (or CODEMUTATOR_TSC); no package installation occurs in these tests.
  """

  use Mutator.DataCase, async: false

  alias Mutator.{Runs, Workspaces}

  @moduletag :e2e
  @moduletag timeout: 180_000
  @boundary "export function isSuccess(status: number): boolean { return status >= 200 && status < 300; }\n"

  setup do
    compiler = System.get_env("CODEMUTATOR_E2E_TSC") || System.get_env("CODEMUTATOR_TSC")

    assert is_binary(compiler) and File.regular?(compiler),
           "Set CODEMUTATOR_E2E_TSC to a qualified TypeScript lib/tsc.js or bin/tsc file before including :e2e"

    node = Application.get_env(:mutator, :javascript_node) || System.find_executable("node")
    assert is_binary(node), "Node is required for JavaScript/TypeScript E2E qualification"
    assert {node_version, 0} = System.cmd(node, ["--version"])
    assert {compiler_version, 0} = System.cmd(node, [compiler, "--version"])

    root =
      Path.join(System.tmp_dir!(), "mutator_javascript_e2e_#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspaces")
    File.mkdir_p!(root)

    original =
      Map.new(
        [:workspace_root, :javascript_node, :javascript_tsc],
        &{&1, Application.fetch_env(:mutator, &1)}
      )

    Application.put_env(:mutator, :workspace_root, workspace)
    Application.put_env(:mutator, :javascript_node, node)
    Application.put_env(:mutator, :javascript_tsc, compiler)

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:mutator, key, value)
        {key, :error} -> Application.delete_env(:mutator, key)
      end)

      File.rm_rf!(root)
    end)

    {:ok,
     root: root,
     workspace: workspace,
     node_version: String.trim(node_version),
     compiler_version: compiler_version |> String.trim() |> String.replace_prefix("Version ", "")}
  end

  test "the same HTTP 200 boundary survives weak tests and is killed by the missing assertion",
       context do
    weak = fixture(context.root, "weak", @boundary, boundary_test(false))
    strong = fixture(context.root, "strong", @boundary, boundary_test(true))
    weak_before = Workspaces.manifest(weak)
    strong_before = Workspaces.manifest(strong)

    # Keeping only src/ as the mutation scope must still copy root profile,
    # tsconfig and tests needed by the explicit runner.
    weak_run = completed_run(weak, scope_filter: "src/")
    strong_run = completed_run(strong, scope_filter: "src/")
    [weak_site] = Runs.list_sites(weak_run.id)
    [strong_site] = Runs.list_sites(strong_run.id)
    [weak_outcome] = Runs.list_outcomes(weak_run.id)
    [strong_outcome] = Runs.list_outcomes(strong_run.id)

    for site <- [weak_site, strong_site] do
      assert site.file == "src/client.ts"
      assert site.function == "isSuccess"
      assert site.original == ">="
      assert site.replacement == ">"
      assert binary_part(@boundary, site.byte_start, site.byte_end - site.byte_start) == ">="
      assert site.file_hash == sha256(@boundary)
    end

    assert weak_site.site_key == strong_site.site_key
    assert weak_outcome.status == "survived"
    assert weak_outcome.exit_code == 0
    assert strong_outcome.status == "killed"
    assert strong_outcome.exit_code == 21
    assert weak_run.survived == 1 and weak_run.killed == 0
    assert strong_run.killed == 1 and strong_run.survived == 0
    assert Runs.score(weak_run) == 0.0
    assert Runs.score(strong_run) == 1.0

    for {run, subject, before} <- [
          {weak_run, weak, weak_before},
          {strong_run, strong, strong_before}
        ] do
      assert_provenance(run, subject, context)
      assert run.selected_sites == 1 and run.terminal_sites == 1
      assert Workspaces.same_manifest?(before, Workspaces.manifest(subject))
      assert_cleaned(run, context.workspace)
    end
  end

  test "a compiler rejection is invalid and never contributes to mutation score", context do
    source = "export function result(): 0 { return 0; }\n"

    tests = """
    import test from 'node:test';
    import assert from 'node:assert/strict';
    import {result} from '../src/client.ts';
    test('literal result', () => assert.equal(result(), 0));
    """

    subject = fixture(context.root, "invalid", source, tests)
    before = Workspaces.manifest(subject)
    run = completed_run(subject)
    [site] = Runs.list_sites(run.id)
    [outcome] = Runs.list_outcomes(run.id)

    assert site.original == "0" and site.replacement == "1"
    assert outcome.status == "invalid"
    assert outcome.exit_code == 20
    assert String.contains?(outcome.log_excerpt || "", "typecheck")
    assert run.invalid == 1 and run.killed == 0 and run.survived == 0
    assert is_nil(Runs.score(run))
    assert Workspaces.same_manifest?(before, Workspaces.manifest(subject))
    assert_cleaned(run, context.workspace)
  end

  test "a missing compiler fails the baseline without inventing a detected mutant", context do
    subject = fixture(context.root, "missing_compiler", @boundary, boundary_test(true))
    before = Workspaces.manifest(subject)
    Application.put_env(:mutator, :javascript_tsc, Path.join(context.root, "missing-tsc.js"))
    {:ok, queued} = Runs.submit_run(%{source_path: subject, mutant_limit: 1})
    run = wait_terminal(queued.id)

    assert run.state == "failed"
    assert String.contains?(String.downcase(run.failure_reason || ""), "compiler")
    assert Runs.list_sites(run.id) == []
    assert Runs.list_outcomes(run.id) == []
    assert run.killed == 0 and run.survived == 0
    assert is_nil(Runs.score(run))
    assert Workspaces.same_manifest?(before, Workspaces.manifest(subject))
    assert_cleaned(run, context.workspace)
  end

  test "a dependency failure reached only by a mutant is infrastructure, not a test kill",
       context do
    source = "export function shouldLoad(): boolean { return false; }\n"

    tests = """
    import test from 'node:test';
    import assert from 'node:assert/strict';
    import {shouldLoad} from '../src/client.ts';
    test('optional dependency', async () => {
      if (shouldLoad()) await import('codemutator-e2e-deliberately-absent-package');
      assert.equal(typeof shouldLoad(), 'boolean');
    });
    """

    subject = fixture(context.root, "missing_dependency", source, tests)
    before = Workspaces.manifest(subject)
    run = completed_run(subject)
    [site] = Runs.list_sites(run.id)
    [outcome] = Runs.list_outcomes(run.id)

    assert site.original == "false" and site.replacement == "true"
    assert outcome.status == "error"
    assert outcome.exit_code == 22
    assert String.contains?(outcome.log_excerpt || "", "missing_dependency")
    assert run.error_count == 1 and run.killed == 0 and run.survived == 0
    assert is_nil(Runs.score(run))
    assert Workspaces.same_manifest?(before, Workspaces.manifest(subject))
    assert_cleaned(run, context.workspace)
  end

  test "an exit-zero command cannot advance the baseline without executed-test evidence",
       context do
    alias Mutator.Languages.JavaScript
    alias Mutator.Pipelines.PrepareRun

    forged =
      "CODEMUTATOR_JS_RESULT " <>
        Jason.encode!(%{
          protocol: 1,
          status: "passed",
          reason: nil,
          phase: "worker",
          tests: %{executed: 0, counts: %{passed: 1, failed: 0, cancelled: 0}},
          runtime: %{node: context.node_version}
        }) <> "\n"

    for {name, output} <- [
          {"missing_sentinel", "command exited zero without a test receipt\n"},
          {"zero_tests", forged}
        ] do
      subject = fixture(context.root, name, @boundary, boundary_test(true))
      before = Workspaces.manifest(subject)
      # Insert an already-baselining row without scheduling it: this control
      # drives the public pipeline stage with a real subprocess, never patches
      # the trusted runner or executes inside the original submitted tree.
      run =
        Repo.insert!(
          Mutator.Runs.Run.changeset(%Mutator.Runs.Run{}, %{
            source_path: subject,
            language: "javascript",
            test_argv: ["auto"],
            state: "baselining"
          })
        )

      {:ok, ws, _manifest} = Workspaces.prepare(Integer.to_string(run.id), subject)
      {:ok, worker} = Workspaces.make_worker(ws, "baseline")
      node = Application.fetch_env!(:mutator, :javascript_node)

      input = %PrepareRun{
        run_id: run.id,
        source_path: subject,
        ws: ws,
        adapter: JavaScript,
        baseline_worker: worker,
        toolchain_meta: %{},
        argv_template: [node, "-e", "process.stdout.write(#{Jason.encode!(output)});"],
        env_template: %{"NODE_OPTIONS" => "", "NODE_PATH" => ""}
      }

      result = PrepareRun.run_baseline(input, [])

      assert {:baseline_failed, "invalid JavaScript runner result or no executed tests"} =
               result.error

      assert is_nil(result.baseline_ms)
      assert is_nil(result.mutant_timeout_ms)
      assert Runs.list_sites(run.id) == []
      assert Runs.list_outcomes(run.id) == []
      assert Runs.get_run(run.id).toolchain == %{}
      assert Workspaces.same_manifest?(before, Workspaces.manifest(subject))
      Workspaces.cleanup_run(Integer.to_string(run.id))
      assert_cleaned(run, context.workspace)
    end
  end

  test "cancelling a JavaScript run drains in-flight work and preserves the original source",
       context do
    tests =
      boundary_test(true)
      |> String.replace(
        "() => {",
        "async () => {\n  await new Promise(resolve => setTimeout(resolve, 300));"
      )

    subject = fixture(context.root, "cancelled", @boundary, tests)
    before = Workspaces.manifest(subject)

    {:ok, queued} =
      Runs.submit_run(%{source_path: subject, scope_filter: "src/", mutant_limit: 3})

    wait_dispatched(queued.id, System.monotonic_time(:millisecond) + 30_000)
    assert {:ok, _} = Runs.cancel_run(queued.id)

    # cancel_run marks the row immediately. Cleanup is the observable point
    # after the coordinator has drained existing executions and pending sites.
    assert_cleaned(queued, context.workspace)
    run = Runs.get_run(queued.id)
    sites = Runs.list_sites(run.id)
    outcomes = Runs.list_outcomes(run.id)

    assert run.state == "cancelled"
    assert is_nil(run.failure_reason)
    assert run.selected_sites == 3 and run.terminal_sites == 3
    assert length(sites) == 3 and length(outcomes) == 3
    assert run.cancelled_count >= 1
    assert Enum.all?(sites, &(&1.scheduling_state == "terminal"))
    assert Enum.all?(outcomes, &(&1.status in ~w(killed survived invalid error cancelled)))
    assert Enum.any?(outcomes, &(&1.status == "cancelled"))
    assert Workspaces.same_manifest?(before, Workspaces.manifest(subject))
  end

  test "cancellation during an executing baseline cannot resurrect a run or dispatch mutants",
       context do
    source = "export function flag(): boolean { return false; }\n"

    tests = """
    import test from 'node:test';
    import assert from 'node:assert/strict';
    import {writeFileSync} from 'node:fs';
    import {flag} from '../src/client.ts';
    test('slow executing baseline', async () => {
      writeFileSync('.baseline-started', 'started');
      await new Promise(resolve => setTimeout(resolve, 500));
      assert.equal(typeof flag(), 'boolean');
    });
    """

    subject = fixture(context.root, "cancelled_baseline", source, tests)
    before = Workspaces.manifest(subject)
    {:ok, queued} = Runs.submit_run(%{source_path: subject, mutant_limit: 1})

    marker =
      Path.join([
        context.workspace,
        Integer.to_string(queued.id),
        "workers",
        "baseline",
        "project",
        ".baseline-started"
      ])

    wait_baseline_started(queued.id, marker, System.monotonic_time(:millisecond) + 30_000)
    assert Runs.get_run(queued.id).state == "baselining"
    assert {:ok, cancelled} = Runs.cancel_run(queued.id)
    assert cancelled.state == "cancelled"

    # Observing the immediate cancellation row is insufficient: the baseline
    # must finish and the coordinator must clean up before checking stickiness.
    assert_cleaned(queued, context.workspace)
    run = Runs.get_run(queued.id)
    assert run.state == "cancelled"
    assert is_nil(run.failure_reason)
    assert run.selected_sites == 0 and run.terminal_sites == 0
    assert Runs.list_sites(run.id) == []
    assert Runs.list_outcomes(run.id) == []
    assert Workspaces.same_manifest?(before, Workspaces.manifest(subject))
  end

  defp fixture(root, name, source, tests) do
    subject = Path.join(root, name)
    File.mkdir_p!(Path.join(subject, "src"))
    File.mkdir_p!(Path.join(subject, "test"))
    File.write!(Path.join(subject, "src/client.ts"), source)
    File.write!(Path.join(subject, "test/client.test.mjs"), tests)
    File.write!(Path.join(subject, "package.json"), Jason.encode!(%{type: "module"}))

    File.write!(
      Path.join(subject, "tsconfig.json"),
      Jason.encode!(%{
        compilerOptions: %{
          module: "NodeNext",
          moduleResolution: "NodeNext",
          target: "ES2022",
          strict: true,
          noEmit: true
        },
        include: ["src/**/*.ts"]
      })
    )

    File.write!(
      Path.join(subject, ".codemutator.json"),
      Jason.encode!(%{
        schemaVersion: 1,
        language: "javascript-typescript",
        runner: %{kind: "node-test", files: ["test/client.test.mjs"]},
        typecheck: %{kind: "typescript", project: "tsconfig.json"},
        source: %{include: ["src/**/*.ts"], exclude: []}
      })
    )

    subject
  end

  defp boundary_test(strong?) do
    assertion = if strong?, do: "assert.equal(isSuccess(200), true);", else: ""

    """
    import test from 'node:test';
    import assert from 'node:assert/strict';
    import {isSuccess} from '../src/client.ts';
    test('HTTP successful range', () => {
      assert.equal(isSuccess(201), true);
      assert.equal(isSuccess(299), true);
      assert.equal(isSuccess(199), false);
      assert.equal(isSuccess(300), false);
      #{assertion}
    });
    """
  end

  defp completed_run(subject, opts \\ []) do
    {:ok, queued} =
      Runs.submit_run(%{source_path: subject, mutant_limit: 1, scope_filter: opts[:scope_filter]})

    run = wait_terminal(queued.id)
    assert run.state == "completed", "run ended #{run.state}: #{inspect(run.failure_reason)}"
    run
  end

  defp assert_provenance(run, subject, context) do
    assert run.language == "javascript"
    assert run.scanner_version == "js-ts-ast-v1"
    assert run.test_argv == run.toolchain["argv"]
    assert Enum.any?(run.test_argv, &String.ends_with?(&1, "/bin/runner.mjs"))

    assert run.toolchain["profile"] ==
             Jason.decode!(File.read!(Path.join(subject, ".codemutator.json")))

    assert run.toolchain["profile_sha256"] ==
             sha256(File.read!(Path.join(subject, ".codemutator.json")))

    assert %{
             "parser" => "@babel/parser",
             "parser_version" => "7.29.9",
             "package_version" => "0.1.0",
             "policy" => "js-ts-ast-v1"
           } = run.toolchain["parser"]

    assert run.toolchain["runtime"]["node"] == context.node_version

    assert %{"name" => "typescript", "version" => compiler_version} =
             run.toolchain["runtime"]["compiler"]

    assert compiler_version == context.compiler_version
  end

  defp wait_terminal(id), do: do_wait_terminal(id, System.monotonic_time(:millisecond) + 90_000)

  defp wait_dispatched(id, deadline) do
    run = Runs.get_run(id)

    cond do
      run.state == "running" and
          Enum.any?(Runs.list_sites(id), &(&1.scheduling_state == "dispatched")) ->
        :ok

      Mutator.Runs.Run.terminal?(run) ->
        flunk(
          "run ended before cancellation could observe in-flight work: #{run.state} #{inspect(run.failure_reason)}"
        )

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("run never dispatched a JavaScript mutant")

      true ->
        Process.sleep(10)
        wait_dispatched(id, deadline)
    end
  end

  defp wait_baseline_started(id, marker, deadline) do
    run = Runs.get_run(id)

    cond do
      File.regular?(marker) ->
        :ok

      Mutator.Runs.Run.terminal?(run) ->
        flunk(
          "run ended before its baseline test started: #{run.state} #{inspect(run.failure_reason)}"
        )

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("baseline test never wrote its execution marker")

      true ->
        Process.sleep(10)
        wait_baseline_started(id, marker, deadline)
    end
  end

  defp do_wait_terminal(id, deadline) do
    run = Runs.get_run(id)

    cond do
      Mutator.Runs.Run.terminal?(run) ->
        run

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("run #{id} did not terminate from state #{run.state}")

      true ->
        Process.sleep(50)
        do_wait_terminal(id, deadline)
    end
  end

  defp assert_cleaned(run, workspace) do
    dir = Path.join(workspace, Integer.to_string(run.id))
    deadline = System.monotonic_time(:millisecond) + 10_000
    wait_removed(dir, deadline)
  end

  defp wait_removed(dir, deadline) do
    cond do
      not File.exists?(dir) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("workspace still present: #{dir}")

      true ->
        Process.sleep(25)
        wait_removed(dir, deadline)
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
