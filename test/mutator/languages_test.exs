defmodule Mutator.LanguagesTest do
  @moduledoc """
  Adapter contract tests for the Rust adapter: detection on a root
  `Cargo.toml`, `.rs` mutable-file walking with the standard exclusions
  (`tests/`, `target/`, root `build.rs`), `cargo test` preflight env, and
  tail classification of cargo verdicts.
  """

  use ExUnit.Case, async: true

  alias Mutator.Languages.{Detector, Rust}

  @fixture Path.expand("../fixtures/rust/mathlib", __DIR__)

  describe "rust detection and mutable files" do
    test "detects on root Cargo.toml" do
      assert {:ok, Rust} = Detector.detect(@fixture)
      assert Rust.id() == :rust
      assert Rust.markers() == ["Cargo.toml"]
      assert Rust.source_extensions() == [".rs"]
    end

    test "no cargo toml means no detection" do
      root = Path.join(System.tmp_dir!(), "mut_norust_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      assert Rust.detect(root) == {:error, :no_cargo_toml}
    end

    test "mutable files collect .rs sources and exclude build.rs/tests/target" do
      files = Detector.mutable_files(Rust, @fixture)
      assert "src/lib.rs" in files
      refute Enum.any?(files, &(&1 == "build.rs"))
      refute Enum.any?(files, &String.starts_with?(&1, "tests/"))
      refute Enum.any?(files, &String.starts_with?(&1, "target/"))

      root = Path.join(System.tmp_dir!(), "mut_rustwalk_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "src"))
      File.mkdir_p!(Path.join(root, "tests"))
      File.mkdir_p!(Path.join(root, "target/debug"))

      File.write!(
        Path.join(root, "Cargo.toml"),
        "[package]\nname=\"x\"\nversion=\"0.1.0\"\nedition=\"2021\"\n"
      )

      File.write!(Path.join(root, "src/lib.rs"), "fn f() {}")
      File.write!(Path.join(root, "src/extra.rs"), "fn g() {}")
      File.write!(Path.join(root, "build.rs"), "fn main() {}")
      File.write!(Path.join(root, "tests/it.rs"), "#[test] fn t() {}")
      File.write!(Path.join(root, "target/debug/gen.rs"), "fn gen() {}")
      on_exit(fn -> File.rm_rf(root) end)

      assert Detector.mutable_files(Rust, root) == ["src/extra.rs", "src/lib.rs"]
    end
  end

  describe "rust preflight" do
    test "argv is the subject's own test command with a private cargo home" do
      worker = %{scratch: "/tmp/scr", home: "/tmp/scr/home"}
      assert {:ok, %{argv: [cargo, "test"], env: env}} = Rust.preflight(@fixture, worker)
      assert env["CARGO_HOME"] == "/tmp/scr/cargo-home"
      assert env["HOME"] == "/tmp/scr/home"
      assert cargo =~ "cargo"
    end
  end

  describe "rust classify" do
    test "pass tail survives, failed tests kill, compile errors are invalid" do
      assert Rust.classify({:ok, %{exit_code: 0, tail: "test result: ok. 3 passed"}}) == :survived

      assert Rust.classify(
               {:ok, %{exit_code: 101, tail: "test result: FAILED. 2 passed; 1 failed"}}
             ) ==
               {:killed, :assertion}

      assert Rust.classify({:ok, %{exit_code: 101, tail: "error: test failed, to rerun pass"}}) ==
               {:killed, :runtime_crash}

      assert Rust.classify(
               {:ok,
                %{
                  exit_code: 101,
                  tail: "error[E0308]: mismatched types\nerror: could not compile `mathlib`"
                }}
             ) ==
               :invalid

      assert Rust.classify({:ok, %{exit_code: 101, tail: "test result: ok. 0 failed"}}) ==
               :unclassified

      assert Rust.classify({:timeout, %{}}) == {:killed, :timeout}
    end
  end
end
