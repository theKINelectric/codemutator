defmodule Mutator.Workspaces do
  @moduledoc """
  Subject snapshots and per-mutant worker trees under `temporary_subject/`.

  Layout (MVP_PLAN.md §3):

      temporary_subject/<run_id>/
        snapshot/                 pristine source copy; never a subprocess cwd
        workers/<site_key>/project/  fresh whole-tree copy per mutant
        scratch/<site_key>/       private HOME / zig caches per execution
        logs/                     baseline and mutant logs

  The snapshot copies the *current working tree* including uncommitted source
  (a git clone would miss edits and fail non-git subjects), excluding VCS
  metadata and original build caches. Copy exclusions are separate from
  mutation exclusions: tests and vendored dependencies are copied but never
  mutated. No hardlinks or symlinks back to the original: physical copies
  only. Escaping symlinks in the subject are rejected.

  The service never runs a tool with cwd inside the submitted directory.
  """

  defstruct [:root, :run_dir, :snapshot, :logs, :workers, :scratch]

  def workspace_root do
    Application.get_env(:mutator, :workspace_root) || "temporary_subject"
  end

  @doc """
  Prepare the run workspace and copy the subject into snapshot/. With a
  `copy_scope` (the run's path filter), only the scoped subtree plus the
  root project files are copied — subjects can carry gigabytes of experiment
  history beside the code under test.
  """
  def prepare(run_id, source_path, copy_scope \\ nil) do
    root = workspace_root()
    source = Path.expand(source_path)
    excludes = Application.get_env(:mutator, :copy_excludes, [])

    with :ok <- validate_source(source),
         run_dir = Path.join(root, run_id),
         :ok <- reset_dir(run_dir),
         :ok <- File.mkdir_p(run_dir),
         snapshot = Path.join(run_dir, "snapshot"),
         {:ok, manifest} <- copy_scoped(source, snapshot, excludes, copy_scope) do
      :ok = File.mkdir_p(Path.join(run_dir, "logs"))
      :ok = File.mkdir_p(Path.join(run_dir, "workers"))
      :ok = File.mkdir_p(Path.join(run_dir, "scratch"))

      ws = %__MODULE__{
        root: root,
        run_dir: run_dir,
        snapshot: snapshot,
        logs: Path.join(run_dir, "logs"),
        workers: Path.join(run_dir, "workers"),
        scratch: Path.join(run_dir, "scratch")
      }

      {:ok, ws, manifest}
    end
  end

  def run_dir(run_id), do: Path.join(workspace_root(), run_id)

  @doc """
  A fresh whole-tree copy of the snapshot for one mutant: the worker project.
  Scratch (private HOME and caches) sits beside it. Returns paths for the
  execution layer.
  """
  # `scratch_key` defaults to the site key; execution slots pass a shared
  # slot key so the zig caches (content-addressed) stay warm across that
  # slot's mutants — a fresh cache per site would force a full rebuild every
  # mutant.
  def make_worker(ws, site_key, opts \\ []) do
    scratch_key = Keyword.get(opts, :scratch_key, site_key)
    project = Path.join([ws.workers, site_key, "project"])
    scratch = Path.join(ws.scratch, scratch_key)

    with :ok <- reset_dir(Path.join(ws.workers, site_key)),
         {:ok, _manifest} <- copy_tree(ws.snapshot, project, []) do
      :ok = File.mkdir_p(Path.join(scratch, "home"))
      :ok = File.mkdir_p(Path.join(scratch, "zig-local"))
      :ok = File.mkdir_p(Path.join(scratch, "zig-global"))

      {:ok,
       %{
         project: project,
         scratch: scratch,
         home: Path.join(scratch, "home"),
         zig_local_cache: Path.join(scratch, "zig-local"),
         zig_global_cache: Path.join(scratch, "zig-global")
       }}
    end
  end

  # A lane is a persistent project tree for one execution slot. Mutants are
  # patched into it in place and restored afterwards: same-path edits always
  # invalidate zig's stat manifests, so its cache stays warm AND correct —
  # empirically, a cache shared across tree COPIES is blind to any change in
  # the copy (recorded during M4; even a syntax error passes at cache-hit
  # speed). The reference tool uses the same per-worker-directory model.
  def make_lane(ws, lane_key) do
    project = Path.join([ws.workers, "lane-#{lane_key}", "project"])
    scratch = Path.join(ws.scratch, "lane-#{lane_key}")

    with :ok <- reset_dir(Path.join(ws.workers, "lane-#{lane_key}")),
         {:ok, _manifest} <- copy_tree(ws.snapshot, project, []) do
      :ok = File.mkdir_p(Path.join(scratch, "home"))
      :ok = File.mkdir_p(Path.join(scratch, "zig-local"))
      :ok = File.mkdir_p(Path.join(scratch, "zig-global"))

      {:ok,
       %{
         lane: lane_key,
         project: project,
         scratch: scratch,
         home: Path.join(scratch, "home"),
         zig_local_cache: Path.join(scratch, "zig-local"),
         zig_global_cache: Path.join(scratch, "zig-global")
       }}
    end
  end

  @doc "Remove a worker tree after its process group is dead. Slot scratch is kept: it is reused by the slot's later mutants."
  def cleanup_worker(ws, site_key) do
    reset_dir(Path.join(ws.workers, site_key))
    :ok
  end

  @doc "Remove the whole run workspace."
  def cleanup_run(run_id) do
    reset_dir(run_dir(run_id))
  end

  @doc """
  Manifest of every file's path and sha256 under `dir` (relative, sorted).
  Used to prove the original subject is untouched after a run.
  """
  def manifest(dir) do
    dir
    |> list_files()
    |> Enum.map(fn path ->
      rel = Path.relative_to(path, dir)
      hash = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
      {rel, hash}
    end)
    |> Enum.sort()
  end

  def same_manifest?(a, b), do: a == b

  # -- copy ------------------------------------------------------------------

  # rsync with --no-links: worker trees contain zero symlinks, so no build
  # can follow a link back into the original tree. Excluded entries (VCS
  # metadata, original build caches) never enter the copy at all.
  defp copy_tree(src, dest, excludes) do
    src = Path.expand(src)
    dest = Path.expand(dest)

    args =
      ["-a", "--no-links"] ++
        Enum.flat_map(excludes, &["--exclude", &1]) ++ [src <> "/", dest]

    # rsync creates only the last path component of dest; GNU rsync fails
    # when its parent is missing (macOS openrsync happens to create it).
    :ok = File.mkdir_p(Path.dirname(dest))

    case System.cmd("rsync", args, stderr_to_stdout: true) do
      {_out, 0} ->
        File.mkdir_p(dest)
        {:ok, manifest(dest)}

      {out, code} ->
        {:error, {:copy_failed, code, String.slice(out, 0, 400)}}
    end
  end

  # Root files every build needs regardless of scope; scoped directories are
  # copied whole beneath them. Rust: Cargo.toml/Cargo.lock are the manifest +
  # lockfile (detection and `cargo test` both need them); rust-toolchain pins
  # the toolchain; build.rs is the build script (copied for the build, still
  # never mutated — Detector.build_script?/2).
  @root_files ~w(build.zig build.zig.zon mix.exs mix.lock Package.swift
                 Package.resolved settings.gradle settings.gradle.kts
                 build.gradle build.gradle.kts gradle.properties .mise.toml
                 Cargo.toml Cargo.lock rust-toolchain.toml rust-toolchain
                 build.rs)

  defp copy_scoped(src, dest, excludes, nil),
    do: copy_tree(src, dest, excludes)

  defp copy_scoped(src, dest, excludes, scope) do
    scope = String.trim_leading(scope, "/")

    with :ok <- File.mkdir_p(dest) do
      # root files first
      Enum.each(@root_files, fn f ->
        s = Path.join(src, f)
        if File.regular?(s), do: File.cp!(s, Path.join(dest, f))
      end)

      # Tests live beside the scoped code, and builds need their inputs:
      # config, vendored deps, priv (migrations/static), assets. Missing any
      # of these turns `mix test` into an interactive Hex prompt that hangs
      # to the deadline (observed in the self-hosting dogfood).
      extra_dirs = ~w(test tests spec config deps priv assets .cargo) ++
                     ~w(gradle gradlew build.gradle settings.gradle Packages Package.swift)

      Enum.each(extra_dirs, fn d ->
        sdir = Path.join(src, d)
        if File.dir?(sdir), do: copy_tree(sdir, Path.join(dest, d), excludes)
      end)

      Enum.each(~w(gradlew), fn f ->
        sfile = Path.join(src, f)
        if File.regular?(sfile), do: File.cp!(sfile, Path.join(dest, f))
      end)

      case File.dir?(Path.join(src, scope)) do
        true ->
          case copy_tree(Path.join(src, scope), Path.join(dest, scope), excludes) do
            {:ok, _} -> {:ok, manifest(dest)}
            error -> error
          end

        false ->
          {:error, {:scope_not_found, scope}}
      end
    end
  end

  # -- validation ------------------------------------------------------------

  defp validate_source(source) do
    root = workspace_root() |> Path.expand()
    # The subject must not be or contain the service itself.
    cwd = Path.expand(".")
    expanded = Path.expand(source)

    cond do
      not File.dir?(source) ->
        {:error, :not_a_directory}

      expanded == root or String.starts_with?(expanded, root <> "/") ->
        {:error, :source_inside_workspace}

      cwd == expanded or String.starts_with?(cwd, expanded <> "/") ->
        {:error, :source_contains_service}

      true ->
        :ok
    end
  end

  defp reset_dir(dir) do
    case File.rm_rf(dir) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, {:reset_failed, dir, reason}}
    end
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          case File.dir?(path) do
            true -> list_files(path)
            false -> [path]
          end
        end)

      {:error, _} ->
        []
    end
  end
end
