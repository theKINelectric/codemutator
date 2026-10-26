defmodule Mutator.WorkspacesTest do
  @moduledoc """
  Scoped-snapshot regression tests: a `scope_filter` copies only the scoped
  subtree *plus the root files the build needs*. Missing Cargo.toml/Cargo.lock
  made scoped Rust submissions fail detection — supervisor finding, kept here
  as the repair receipt.
  """

  use ExUnit.Case, async: false

  alias Mutator.Languages.{Detector, Rust}
  alias Mutator.Workspaces

  @fixture Path.expand("../fixtures/rust/mathlib", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "mut_ws_#{System.unique_integer([:positive])}")
    Application.put_env(:mutator, :workspace_root, root)

    on_exit(fn ->
      Application.delete_env(:mutator, :workspace_root)
      File.rm_rf(root)
    end)

    :ok
  end

  test "scoped rust snapshot carries the cargo manifest and detects" do
    assert {:ok, ws, _manifest} = Workspaces.prepare("scoped-rust", @fixture, "src/")

    assert File.exists?(Path.join(ws.snapshot, "Cargo.toml"))
    assert File.exists?(Path.join(ws.snapshot, "Cargo.lock"))
    assert File.exists?(Path.join(ws.snapshot, "src/lib.rs"))
    assert {:ok, Rust} = Detector.detect(ws.snapshot)
    assert Detector.mutable_files(Rust, ws.snapshot, "src/") == ["src/lib.rs"]
  end

  test "unscoped rust snapshot is the whole tree" do
    assert {:ok, ws, _manifest} = Workspaces.prepare("full-rust", @fixture, nil)
    assert File.exists?(Path.join(ws.snapshot, "Cargo.toml"))
    assert {:ok, Rust} = Detector.detect(ws.snapshot)
  end

  test "scoped zig snapshot still carries build.zig" do
    zig = Path.expand("../fixtures/zig/mathlib", __DIR__)
    assert {:ok, ws, _} = Workspaces.prepare("scoped-zig", zig, "src/")
    assert File.exists?(Path.join(ws.snapshot, "build.zig"))
    assert File.exists?(Path.join(ws.snapshot, "src/math.zig"))
  end
end
