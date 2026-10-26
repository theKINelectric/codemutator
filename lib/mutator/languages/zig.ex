defmodule Mutator.Languages.Zig do
  @moduledoc """
  Zig adapter. Root `build.zig`; pinned toolchain resolved through mise (the
  subject's `.mise.toml` names the exact version); tests are `zig build test`.

  Private local/global zig caches per execution keep a worker from importing
  another's (or the original's) build cache (MVP_PLAN.md §4).
  """

  @behaviour Mutator.Languages.Adapter

  @impl true
  def id, do: :zig
  @impl true
  def name, do: "Zig"
  @impl true
  def markers, do: ["build.zig"]
  @impl true
  def source_extensions, do: [".zig"]

  @impl true
  def detect(subject_root) do
    if File.exists?(Path.join(subject_root, "build.zig")) do
      :ok
    else
      {:error, :no_build_zig}
    end
  end

  @impl true
  def preflight(subject_root, worker) do
    with {:ok, zig} <- resolve_zig(subject_root) do
      {:ok,
       %{
         argv: [
           zig,
           "build",
           "test",
           "--cache-dir",
           worker.zig_local_cache,
           "--global-cache-dir",
           worker.zig_global_cache
         ],
         env: %{
           "ZIG_LOCAL_CACHE_DIR" => worker.zig_local_cache,
           "ZIG_GLOBAL_CACHE_DIR" => worker.zig_global_cache,
           "HOME" => worker.home
         }
       }}
    end
  end

  # -- classification --------------------------------------------------------

  @impl true
  # Zig 0.16 test-failure output (observed in M4 qualification logs):
  #   assertion: "+- run test 2 pass, 1 fail", "error: '<test>' failed:",
  #               "expected X, found Y", "TestExpectedEqual"
  #   crash:      "+- run test 2 pass, 1 crash", "panic:", "terminated with signal"
  #   compile:    "error: ..." WITHOUT any run-test summary line
  def classify({:timeout, _}), do: {:killed, :timeout}
  def classify({:ok, %{exit_code: 0}}), do: :survived

  def classify({:ok, %{exit_code: _, tail: tail}}) do
    ran? = tail =~ "run test"

    cond do
      # Tests executed and a test binary crashed. The "run test N pass, M
      # crash" summary is the evidence tests ran; zig prints "the following
      # build command failed" for ANY failed step, so that marker alone must
      # not override test evidence.
      ran? and (tail =~ "panic:" or tail =~ "terminated with signal" or tail =~ "crash (") ->
        {:killed, :runtime_crash}

      # Tests executed and failed an expectation.
      ran? and (tail =~ "fail" or tail =~ "failed:") ->
        {:killed, :assertion}

      tail =~ "failed:" or tail =~ "TestExpected" ->
        {:killed, :assertion}

      # No test-run evidence: a failing build (compiler rejection, build
      # runner panic) — the mutation never produced a running test binary.
      tail =~ "error:" or tail =~ "panic:" or tail =~ "the following build command failed" ->
        :invalid

      true ->
        :unclassified
    end
  end

  # -- toolchain -------------------------------------------------------------

  # Resolution order for a pinned version: mise install path, homebrew
  # cellar, PATH. Every candidate is verified by running `zig version` — the
  # host has more than one install and an stale one can shadow mise (recorded
  # during M5 preparation; a wrong zig that cannot link shows up as a
  # baseline failure, so verification is cheap insurance).
  defp resolve_zig(subject_root) do
    wanted = pinned_version(subject_root)

    wanted
    |> candidates()
    |> Enum.find(&version_matches?(&1, wanted))
    |> case do
      nil -> {:error, :toolchain_unavailable}
      zig -> {:ok, zig}
    end
  end

  defp pinned_version(subject_root) do
    mise_toml = Path.join(subject_root, ".mise.toml")

    with {:ok, content} <- File.read(mise_toml),
         {_, [_, ver]} <- {:ok, Regex.run(~r/zig\s*=\s*"([^"]+)"/, content)} do
      ver
    else
      _ -> nil
    end
  end

  # Unpinned: newest cellar first, PATH last — this host's PATH zig is an
  # stale install that cannot link (recorded during M5 preparation).
  defp candidates(nil) do
    [
      cellar_zigs() |> Enum.reverse() |> List.first(),
      System.find_executable("zig")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp candidates(version) do
    prefix = version_prefix(version)

    [
      mise_exec_path(version),
      cellar_zigs()
      |> Enum.filter(&String.contains?(&1, "/#{prefix}."))
      |> Enum.reverse()
      |> List.first(),
      System.find_executable("zig")
    ]
    |> Enum.reject(&is_nil/1)
  end

  # "0.16.0-dev.123+abc" pins want "0.16.0" prefix matching.
  defp version_prefix(version) do
    case Regex.run(~r/^(\d+\.\d+)/, version) do
      {_, [major_minor]} -> major_minor
      _ -> version
    end
  end

  defp mise_exec_path(version) do
    case System.cmd("mise", ["where", "zig@#{version}"], stderr_to_stdout: true) do
      {dir, 0} -> Path.join(String.trim(dir), "zig")
      _ -> nil
    end
  end

  defp cellar_zigs do
    Path.wildcard("/opt/homebrew/Cellar/zig/*/bin/zig") |> Enum.sort()
  end

  defp version_matches?(zig, nil) do
    case System.cmd(zig, ["version"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp version_matches?(zig, wanted) do
    prefix = version_prefix(wanted)

    case System.cmd(zig, ["version"], stderr_to_stdout: true) do
      {out, 0} ->
        String.trim(out) == wanted or String.starts_with?(String.trim(out), prefix <> ".")

      _ ->
        false
    end
  end
end
