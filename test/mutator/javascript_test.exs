defmodule Mutator.JavaScriptTest do
  use ExUnit.Case, async: false
  alias Mutator.Languages.{Detector, ElixirLang, JavaScript}
  alias Mutator.Scanner

  setup do
    root = Path.join(System.tmp_dir!(), "mutator_js_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp profile(root, updates \\ %{}) do
    defaults = %{
      "schemaVersion" => 1,
      "language" => "javascript-typescript",
      "runner" => %{"kind" => "node-test", "files" => ["test/client.test.mjs"]},
      "typecheck" => %{"kind" => "none"},
      "source" => %{"include" => ["src/**/*.js", "src/**/*.ts"], "exclude" => ["src/excluded/**"]}
    }

    File.write!(Path.join(root, ".codemutator.json"), Jason.encode!(Map.merge(defaults, updates)))
  end

  defp file(root, path, content \\ "function f(){return true;}\n") do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp sentinel(status, reason, extra \\ %{}) do
    value =
      Map.merge(
        %{"protocol" => 1, "status" => status, "reason" => reason, "phase" => "worker"},
        extra
      )

    "CODEMUTATOR_JS_RESULT " <> Jason.encode!(value) <> "\n"
  end

  test "package.json alone cannot override an Elixir project", %{root: root} do
    file(root, "mix.exs", "defmodule Subject.MixProject do end")
    file(root, "package.json", "{}")
    assert {:ok, ElixirLang} = Detector.detect(root)
    assert {:error, :no_codemutator_profile} = JavaScript.detect(root)
    profile(root)
    assert {:ok, JavaScript} = Detector.detect(root)
  end

  test "strict profile validation rejects invalid JSON, unknown fields and escaped paths", %{
    root: root
  } do
    for updates <- [
          %{"schemaVersion" => 99},
          %{"watch" => true},
          %{"runner" => %{"kind" => "node-test", "files" => []}},
          %{"runner" => %{"kind" => "node-test", "files" => ["../escape.mjs"]}}
        ] do
      profile(root, updates)
      assert {:error, {:invalid_javascript_profile, _}} = Detector.detect(root)
    end

    File.write!(Path.join(root, ".codemutator.json"), "export default {}")
    assert {:error, {:invalid_javascript_profile, _}} = JavaScript.read_profile(root)
  end

  test "profile source selection excludes tests declarations generated paths symlinks and excluded sources",
       %{root: root} do
    profile(root)

    for path <- [
          "src/ok.js",
          "src/nested/ok.ts",
          "src/.hidden.js",
          "src/.cache/hidden.ts",
          "src/a.test.ts",
          "src/a.spec.js",
          "src/a.d.ts",
          "src/tests/embedded.ts",
          "src/excluded/no.js",
          "node_modules/pkg/no.js",
          "dist/no.js",
          "outside.js"
        ] do
      file(root, path)
    end

    File.ln_s!(Path.join(root, "src/ok.js"), Path.join(root, "src/link.js"))
    assert Detector.mutable_files(JavaScript, root) == ["src/nested/ok.ts", "src/ok.js"]
    assert Detector.mutable_files(JavaScript, root, "src/nested/") == ["src/nested/ok.ts"]
  end

  test "source discovery fails visibly for a malformed profile", %{root: root} do
    file(root, ".codemutator.json", "{")
    assert_raise ArgumentError, ~r/profile/, fn -> Detector.mutable_files(JavaScript, root) end
  end

  test "preflight supplies trusted CLI argv with actual worker paths", %{root: root} do
    profile(root)
    file(root, "test/client.test.mjs", "import test from 'node:test'; test('x',()=>{});")

    worker = %{
      project: root,
      scratch: Path.join(root, "scratch"),
      home: Path.join(root, "scratch/home")
    }

    assert {:ok,
            %{
              argv: [
                node,
                script,
                "--worker",
                project,
                "--timeout",
                "600000",
                "--service-owned-group"
              ],
              env: env
            }} =
             JavaScript.preflight(root, worker)

    assert Path.type(node) == :absolute
    assert File.regular?(script)
    assert String.ends_with?(script, "/priv/js_ts_runner/bin/runner.mjs")
    assert project == Path.expand(root)
    assert env["HOME"] == worker.home
    assert env["NODE_OPTIONS"] == ""
  end

  test "preflight reports symlink topology explicitly", %{root: root} do
    profile(root)
    file(root, "test/client.test.mjs", "")
    File.ln_s!(Path.join(root, "test/client.test.mjs"), Path.join(root, "link"))
    worker = %{project: root, scratch: root, home: root}
    assert {:error, :unsupported_workspace_symlink} = JavaScript.preflight(root, worker)
  end

  test "classification requires bounded validated final sentinel and matching exits" do
    pass =
      sentinel("passed", nil, %{
        "tests" => %{
          "executed" => 1,
          "counts" => %{"passed" => 1, "failed" => 0, "cancelled" => 0}
        },
        "runtime" => %{"node" => "v26.10.0"}
      })

    assert JavaScript.classify({:ok, %{exit_code: 0, tail: pass}}) == :survived

    assert JavaScript.classify({:ok, %{exit_code: 21, tail: sentinel("killed", "assertion")}}) ==
             {:killed, :assertion}

    assert JavaScript.classify({:ok, %{exit_code: 21, tail: sentinel("killed", "runtime_crash")}}) ==
             {:killed, :runtime_crash}

    assert JavaScript.classify({:ok, %{exit_code: 20, tail: sentinel("invalid", "typecheck")}}) ==
             :invalid

    assert JavaScript.classify(
             {:ok, %{exit_code: 22, tail: sentinel("error", "missing_dependency")}}
           ) == :unclassified

    assert JavaScript.classify({:ok, %{exit_code: 0, tail: ""}}) == :unclassified

    assert JavaScript.classify({:ok, %{exit_code: 0, tail: pass <> "trailing damage"}}) ==
             :unclassified

    assert JavaScript.classify({:ok, %{exit_code: 21, tail: pass}}) == :unclassified

    assert JavaScript.classify(
             {:ok,
              %{exit_code: 0, tail: sentinel("passed", nil, %{"tests" => %{"executed" => 0}})}}
           ) == :unclassified

    assert JavaScript.classify({:timeout, %{}}) == {:killed, :timeout}
    assert {:ok, %{"runtime" => %{"node" => "v26.10.0"}}} = JavaScript.result_metadata(pass)
    assert {:error, _} = JavaScript.result_metadata(String.duplicate("x", 8001))
  end

  test "AST scanner reports exact UTF8 spans qualified owners and path-distinct keys" do
    source = "// 🌌 café\nexport const eligible = (age: number) => age >= 18;"
    assert [site] = Scanner.scan(:javascript, "src/a.ts", source)
    assert site.function == "eligible"
    assert site.function_line == 2
    assert site.function_end_line == 2
    assert site.operator == "comparison"
    assert binary_part(source, site.byte_start, site.byte_end - site.byte_start) == ">="
    assert site.replacement == ">"
    assert byte_size(site.site_key) == 32
    assert byte_size(site.file_hash) == 64
    assert Scanner.scan(:typescript, "src/a.ts", source) == [site]
    assert [other] = Scanner.scan(:javascript, "src/b.ts", source)
    refute other.site_key == site.site_key
  end

  test "AST scanner handles arrows callbacks and avoids test/type syntax" do
    source = """
    type Truth = true;
    const check = (n: number) => n >= 18;
    const map = (xs: number[]) => xs.map(x => x + 1);
    test('ignore', () => 1 + 1 >= 0);
    """

    sites = Scanner.scan(:javascript, "src/a.ts", source)
    assert Enum.any?(sites, &(&1.function == "check" and &1.original == ">="))
    assert Enum.any?(sites, &String.contains?(&1.function, "callback"))
    refute Enum.any?(sites, &(&1.line == 4))
    refute Enum.any?(sites, &(&1.line == 1))
  end

  test "parser failure raises rather than silently reporting no mutation sites" do
    assert_raise ArgumentError, ~r/parser/, fn ->
      Scanner.scan(:javascript, "src/a.ts", "const = ;")
    end

    assert_raise ArgumentError, ~r/path/, fn ->
      Scanner.scan(:javascript, "../escape.ts", "function f(){return true;}")
    end
  end
end
