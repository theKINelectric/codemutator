defmodule Mutator.JavaScriptWorkspaceTest do
  use ExUnit.Case, async: false
  alias Mutator.Workspaces

  setup do
    root = Path.join(System.tmp_dir!(), "js_ws_#{System.unique_integer([:positive])}")
    source = Path.join(root, "original")
    File.mkdir_p!(Path.join(source, "src"))
    Application.put_env(:mutator, :workspace_root, Path.join(root, "runs"))

    on_exit(fn ->
      Application.delete_env(:mutator, :workspace_root)
      File.rm_rf(root)
    end)

    %{root: root, source: source}
  end

  test "scoped JavaScript copies profile, manifests, compiler config and physical dependencies",
       %{source: source} do
    for file <-
          ~w(.codemutator.json package.json package-lock.json tsconfig.json src/a.ts shared/config.json configs/custom.json test/a.test.mjs node_modules/example/index.js) do
      path = Path.join(source, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{}")
    end

    before = Workspaces.manifest(source)
    assert {:ok, ws, _} = Workspaces.prepare("scope", source, "src/")

    for file <-
          ~w(.codemutator.json package.json package-lock.json tsconfig.json src/a.ts shared/config.json configs/custom.json test/a.test.mjs node_modules/example/index.js) do
      assert File.read!(Path.join(ws.snapshot, file)) == "{}", "missing scoped input #{file}"
    end

    assert before == Workspaces.manifest(source)
  end

  test "explicit JS profile rejects source links before rsync can silently drop them", %{
    source: source
  } do
    File.write!(Path.join(source, ".codemutator.json"), "{}")
    File.write!(Path.join(source, "src/a.js"), "content")
    File.ln_s!("a.js", Path.join(source, "src/link.js"))

    assert {:error, {:unsupported_javascript_symlink, "src/link.js"}} =
             Workspaces.prepare("linked", source)
  end

  test "copy scope cannot escape the subject", %{source: source} do
    File.write!(Path.join(source, ".codemutator.json"), "{}")
    assert {:error, :invalid_scope} = Workspaces.prepare("escape", source, "../")
  end
end
