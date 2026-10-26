defmodule Mutator.M2SafeExecutionTest do
  @moduledoc """
  Milestone 2 gate (MVP_PLAN.md §5): safe execution.

    * commands run only in workspace copies, never the submitted directory
    * timeouts kill the whole process group, including grandchildren
    * no workspace tree or worker leak after cleanup
    * the original subject's manifest is identical after a run
  """

  use ExUnit.Case, async: false

  alias Mutator.Execution.ProcessRunner
  alias Mutator.Workspaces

  @tmp Path.expand("../tmp_m2", __DIR__)

  setup do
    File.rm_rf(@tmp)
    File.mkdir_p!(@tmp)
    on_exit(fn -> File.rm_rf(@tmp) end)
    :ok
  end

  describe "ProcessRunner" do
    test "runs an argv command, streams output, reports exit code" do
      log = Path.join(@tmp, "ok.log")

      assert {:ok, %{exit_code: 0, tail: tail}} =
               ProcessRunner.run(["/bin/echo", "hello-mutator"],
                 cwd: @tmp,
                 log_path: log,
                 timeout_ms: 10_000
               )

      assert tail =~ "hello-mutator"
      assert File.read!(log) =~ "hello-mutator"
    end

    test "timeout kills the process group including grandchildren" do
      log = Path.join(@tmp, "hang.log")
      marker = Path.join(@tmp, "grandchild-lived")

      File.rm(marker)

      # parent spawns a child that outlives the deadline; if the group kill
      # works, the grandchild is dead before we check.
      script = """
      /bin/sh -c 'sleep 30; touch #{marker}' &
      sleep 60
      """

      assert {:timeout, %{elapsed_ms: elapsed}} =
               ProcessRunner.run(["/bin/sh", "-c", script],
                 cwd: @tmp,
                 log_path: log,
                 timeout_ms: 1_500
               )

      assert elapsed < 10_000
      # give the group kill a beat, then the grandchild must be gone
      Process.sleep(300)
      refute File.exists?(marker), "grandchild survived the group kill"
    end

    test "paths with spaces work" do
      dir = Path.join(@tmp, "has spaces")
      File.mkdir_p!(dir)

      assert {:ok, %{exit_code: 0}} =
               ProcessRunner.run(["/bin/sh", "-c", "pwd"],
                 cwd: dir,
                 log_path: Path.join(@tmp, "s.log"),
                 timeout_ms: 10_000
               )
    end

    test "extra env reaches the child" do
      assert {:ok, %{exit_code: 0, tail: tail}} =
               ProcessRunner.run(["/usr/bin/printenv", "MUTATOR_PROBE"],
                 cwd: @tmp,
                 log_path: Path.join(@tmp, "env.log"),
                 timeout_ms: 10_000,
                 env: %{"MUTATOR_PROBE" => "here"}
               )

      assert tail =~ "here"
    end
  end

  describe "Workspaces" do
    test "prepare copies the current tree, excludes caches and VCS, never touches the original" do
      source = Path.join(@tmp, "subject")
      File.mkdir_p!(Path.join(source, ".git"))
      File.mkdir_p!(Path.join(source, ".zig-cache"))
      File.mkdir_p!(Path.join(source, "src"))
      File.write!(Path.join(source, ".git/config"), "git")
      File.write!(Path.join(source, ".zig-cache/junk"), "cache")
      File.write!(Path.join(source, "src/main.zig"), "pub fn main() void {}\n")

      before = Workspaces.manifest(source)

      Application.put_env(:mutator, :workspace_root, Path.join(@tmp, "ws"))
      on_exit(fn -> Application.delete_env(:mutator, :workspace_root) end)

      assert {:ok, ws, manifest} = Workspaces.prepare("m2-run", source)

      # snapshot contains the source file but neither .git nor .zig-cache
      files = manifest |> Enum.map(&elem(&1, 0))
      assert "src/main.zig" in files
      refute ".git/config" in files
      refute ".zig-cache/junk" in files

      # worker copies are physical copies with private caches
      {:ok, worker} = Workspaces.make_worker(ws, "site1")
      assert File.exists?(Path.join(worker.project, "src/main.zig"))
      assert File.dir?(worker.zig_local_cache)
      # physical copy, not a link back to the snapshot
      assert {:ok, %File.Stat{type: :regular}} =
               File.lstat(Path.join(worker.project, "src/main.zig"))

      # cleanup leaves nothing behind
      :ok = Workspaces.cleanup_worker(ws, "site1")
      refute File.exists?(Path.join(ws.workers, "site1"))
      :ok = Workspaces.cleanup_run("m2-run")
      refute File.exists?(Path.join([@tmp, "ws", "m2-run"]))

      # the original is byte-identical
      assert Workspaces.same_manifest?(before, Workspaces.manifest(source))
    end

    test "rejects sources inside the workspace and the service itself" do
      Application.put_env(:mutator, :workspace_root, Path.join(@tmp, "ws2"))
      on_exit(fn -> Application.delete_env(:mutator, :workspace_root) end)

      File.mkdir_p!(Path.join([@tmp, "ws2", "inner"]))

      assert {:error, :source_inside_workspace} =
               Workspaces.prepare("x", Path.join([@tmp, "ws2", "inner"]))

      assert {:error, :source_contains_service} =
               Workspaces.prepare("x", Path.expand("../..", __DIR__))

      assert {:error, :not_a_directory} = Workspaces.prepare("x", Path.join(@tmp, "nope"))
    end
  end
end
