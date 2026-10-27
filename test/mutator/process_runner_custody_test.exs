defmodule Mutator.ProcessRunnerCustodyTest do
  use ExUnit.Case, async: false
  alias Mutator.Execution.ProcessRunner
  @tag :tmp_dir
  test "a successful wrapper exit cannot leave a background descendant behind", %{tmp_dir: root} do
    marker = Path.join(root, "orphan")
    child = "import time,pathlib; time.sleep(0.6); pathlib.Path(#{inspect(marker)}).touch()"

    parent =
      "import subprocess,sys; subprocess.Popen([sys.executable,'-c',#{inspect(child)}], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); print('spawned')"

    assert {:ok, %{exit_code: 0}} =
             ProcessRunner.run(["/usr/bin/python3", "-c", parent],
               cwd: root,
               log_path: Path.join(root, "exit.log"),
               timeout_ms: 3000
             )

    Process.sleep(900)
    refute File.exists?(marker), "background descendant survived a normal wrapper exit"
  end

  @tag :tmp_dir
  test "TERM-resistant descendants are killed before the process-group deadline returns", %{
    tmp_dir: root
  } do
    marker = Path.join(root, "resisted")

    child =
      "import signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(3.0); pathlib.Path(#{inspect(marker)}).touch()"

    parent =
      "import subprocess,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); subprocess.Popen([sys.executable,'-c',#{inspect(child)}], stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); time.sleep(10)"

    assert {:timeout, _} =
             ProcessRunner.run(["/usr/bin/python3", "-c", parent],
               cwd: root,
               log_path: Path.join(root, "kill.log"),
               timeout_ms: 500
             )

    Process.sleep(1000)
    refute File.exists?(marker), "TERM-resistant descendant survived the KILL deadline"
  end
end
