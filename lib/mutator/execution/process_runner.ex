defmodule Mutator.Execution.ProcessRunner do
  @moduledoc """
  Argument-vector subprocess execution with process-group ownership,
  deadlines, and streamed logs (MVP_PLAN.md §2).

  Every command runs through `/usr/bin/python3 -c WRAPPER -- cmd…` where the
  wrapper calls `setpgid(0, 0)` before `execvp`. The process group therefore
  starts at the wrapper and survives exec: `kill(-os_pid, SIG)` reaches the
  command and every descendant (compilers, test runners) without touching the
  BEAM's own group.

  Deadline policy: TERM to the group, two seconds of grace, then KILL.
  Output streams into a log file owned by the runner; a bounded tail is
  returned for classification.

  The command's cwd is always a workspace copy — the service never runs a
  tool inside the submitted directory.
  """

  @grace_ms 2_000
  @tail_bytes 8_000

  @wrapper ~s"""
  import os, sys
  try:
      os.setpgid(0, 0)
  except PermissionError:
      # Already a group leader (some port spawn paths do this): the group
      # root is this pid either way, so group kills still work.
      if os.getpid() != os.getpgrp():
          raise
  os.execvp(sys.argv[1], sys.argv[1:])
  """

  @enforce_keys [:argv, :cwd, :log_path]
  defstruct [:argv, :cwd, :log_path, :env, :timeout_ms]

  def run(argv, opts) when is_list(argv) do
    cwd = Keyword.fetch!(opts, :cwd)
    log_path = Keyword.fetch!(opts, :log_path)
    timeout = Keyword.get(opts, :timeout_ms, 60_000)
    extra_env = Keyword.get(opts, :env, %{})

    File.mkdir_p(Path.dirname(log_path))
    log = File.open!(log_path, [:write, :utf8])

    # Provenance header: what ran, where, with which environment overrides.
    IO.binwrite(
      log,
      "#! argv: #{Enum.join(argv, " ")}\n" <>
        "#! cwd: #{cwd}\n" <>
        "#! env+: #{inspect(extra_env || %{})}\n" <>
        "#! PATH: #{System.get_env("PATH")}\n"
    )

    wrapped = ["/usr/bin/python3", "-c", @wrapper | argv]

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: Enum.drop(wrapped, 1),
      cd: cwd,
      env: env_list(extra_env),
      parallelism: true
    ]

    port = Port.open({:spawn_executable, hd(wrapped)}, port_opts)
    started = System.monotonic_time(:millisecond)

    {:os_pid, group_id} = Port.info(port, :os_pid)

    try do
      await(%{
        port: port,
        log: log,
        timeout_at: started + timeout,
        started: started,
        buffer: "",
        log_path: log_path
      })
    after
      # The group can outlive its leader. Service-mode JS children share
      # this group; retain its identity even after the port has exited.
      System.cmd("/bin/kill", ["-9", "-#{group_id}"], stderr_to_stdout: true)
    end
  end

  defp await(%{port: port} = st) do
    deadline_wait = max(st.timeout_at - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        IO.binwrite(st.log, chunk)
        buffer = append_bounded(st.buffer, chunk)
        await(%{st | buffer: buffer})

      {^port, {:exit_status, code}} ->
        File.close(st.log)
        elapsed = System.monotonic_time(:millisecond) - st.started

        {:ok,
         %{
           exit_code: code,
           signal: nil,
           elapsed_ms: elapsed,
           log_path: st.log_path,
           tail: st.buffer
         }}
    after
      deadline_wait ->
        kill_group(port)

        receive do
          {^port, {:exit_status, _code}} -> :ok
        after
          @grace_ms ->
            kill_group(port, :kill)

            receive do
              {^port, {:exit_status, _code}} -> :ok
            after
              1_000 -> :ok
            end
        end

        File.close(st.log)
        elapsed = System.monotonic_time(:millisecond) - st.started

        {:timeout,
         %{
           exit_code: nil,
           signal: :term_then_kill,
           elapsed_ms: elapsed,
           log_path: st.log_path,
           tail: st.buffer
         }}
    end
  end

  defp kill_group(port, signal \\ :term) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid),
         true <- is_integer(os_pid) do
      sig = if signal == :kill, do: 9, else: 15
      System.cmd("/bin/kill", ["-#{sig}", "-#{os_pid}"])
    else
      _ -> :ok
    end
  end

  defp append_bounded(buffer, chunk) do
    data = buffer <> chunk

    if byte_size(data) > @tail_bytes,
      do: binary_part(data, byte_size(data) - @tail_bytes, @tail_bytes),
      else: data
  end

  # Subject subprocesses must see a normal development environment, not the
  # service's release environment: RELEASE_*/ERTS vars and a PATH whose first
  # entries point into this very release make child toolchains (mix protocol
  # consolidation spawning `erl`, etc.) resolve release binaries and die on
  # release bootfiles. Observed during the self-hosting dogfood run.
  @release_vars ~w(RELEASE_ROOT RELEASE_NAME RELEASE_VSN RELEASE_MUTABLE_DIR
                   RELEASE_COMMAND_FILENAME BINDIR ROOTDIR PROGNAME
                   MIX_ENV MIX_HOME MIX_ARCHIVES ERTS_INCLUDE_PATH)

  # Port `env:` is MODIFY semantics: unlisted variables are inherited and
  # `{name, false}` unsets. So rejected release variables need explicit
  # unsets, and PATH is always set explicitly — an empty sanitized PATH
  # would otherwise unset it for the child (both observed in the release
  # during the self-hosting dogfood).
  defp env_list(extra) do
    entries =
      :os.getenv()
      |> Enum.map(&List.to_string/1)
      |> Enum.map(fn entry -> :binary.split(entry, "=") end)

    inherited =
      for [k, v] <- entries, k not in @release_vars, k != "PATH" do
        {String.to_charlist(k), String.to_charlist(v)}
      end

    unsets =
      for [k, _] <- entries, k in @release_vars do
        {String.to_charlist(k), false}
      end

    added =
      Enum.map(extra, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    inherited ++ unsets ++ [{~c"PATH", String.to_charlist(sane_path())}] ++ added
  end

  # The child PATH minus this release's own directories; a floor guarantees
  # standard tool locations even under a scrubbed launcher environment.
  defp sane_path do
    self_root = :code.root_dir() |> List.to_string()

    kept =
      (System.get_env("PATH") || "")
      |> String.split(":", trim: true)
      |> Enum.reject(&String.starts_with?(&1, self_root <> "/"))

    case kept do
      [] -> "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      _ -> Enum.join(kept, ":")
    end
  end
end
