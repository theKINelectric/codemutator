defmodule Mutator.Languages.Rust do
  @moduledoc """
  Rust adapter. Projects are detected by a root `Cargo.toml` and tested with
  `cargo test` — the subject's own test command, run inside the lane's private
  copy of the tree.

  Each lane gets a private `CARGO_HOME` under its scratch dir so registry
  caches and credential reads never touch the user's real cargo state; the
  build `target/` dir lives inside the lane's project copy and stays warm
  across mutants (lanes patch in place, same model as Zig's caches).

  Outcome classification reads the `cargo test` tail:

    * `test result: FAILED.` — the test binary ran and a test failed →
      killed (assertion; Rust panics report through the same verdict)
    * `error: test failed` — the test binary died without a verdict
      (abort, SIGSEGV in a harness) → killed (runtime crash)
    * `error[...]`/`error: could not compile` — rustc rejected the mutant
      before any test ran → invalid (not evidence against the suite)
    * exit 0 → survived
    * timeout → killed (timeout)
  """

  @behaviour Mutator.Languages.Adapter

  @impl true
  def id, do: :rust

  @impl true
  def name, do: "Rust"

  @impl true
  def markers, do: ["Cargo.toml"]

  @impl true
  def source_extensions, do: [".rs"]

  @impl true
  def detect(subject_root) do
    if File.exists?(Path.join(subject_root, "Cargo.toml")),
      do: :ok,
      else: {:error, :no_cargo_toml}
  end

  @impl true
  def preflight(_subject_root, worker) do
    case System.find_executable("cargo") do
      nil ->
        {:error, :toolchain_unavailable}

      cargo ->
        {:ok,
         %{
           argv: [cargo, "test"],
           env:
             %{
               "CARGO_HOME" => Path.join(worker.scratch, "cargo-home"),
               "HOME" => worker.home
             }
             |> passthrough_rustup()
         }}
    end
  end

  # The `cargo` on PATH is usually a rustup proxy: it resolves its toolchain
  # from `RUSTUP_HOME`/the real `~/.rustup`, not from the lane's private
  # HOME. Pass those vars through so the shim still works inside a lane.
  defp passthrough_rustup(env) do
    env
    |> put_env("RUSTUP_HOME", System.get_env("RUSTUP_HOME") || user_rustup_home())
    |> put_env("RUSTUP_TOOLCHAIN", System.get_env("RUSTUP_TOOLCHAIN"))
  end

  defp put_env(env, _key, nil), do: env
  defp put_env(env, key, value), do: Map.put(env, key, value)

  defp user_rustup_home do
    case System.fetch_env("HOME") do
      {:ok, home} ->
        candidate = Path.join(home, ".rustup")
        if File.dir?(candidate), do: candidate

      :error ->
        nil
    end
  end

  @impl true
  def classify({:timeout, _}), do: {:killed, :timeout}
  def classify({:ok, %{exit_code: 0}}), do: :survived

  def classify({:ok, %{exit_code: _code, tail: tail}}) do
    cond do
      tail =~ "test result: FAILED" -> {:killed, :assertion}
      tail =~ "error: test failed" -> {:killed, :runtime_crash}
      tail =~ "test result:" -> :unclassified
      tail =~ "error" -> :invalid
      true -> :unclassified
    end
  end
end
