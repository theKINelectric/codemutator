defmodule MutatorWeb.API.AgentsControllerTest do
  use MutatorWeb.ConnCase
  alias Mutator.Languages.{Detector, JavaScript}

  test "the machine-readable JS profile is accepted by the real detector", %{conn: conn} do
    card = conn |> get(~p"/agents.json") |> json_response(200)

    assert Enum.all?(
             ~w(zig rust elixir swift kotlin javascript),
             &Map.has_key?(card["languages"], &1)
           )

    profile = card["execution_profiles"]["javascript_typescript"]
    assert profile["runner"] == "node-test"
    assert profile["declaration_files_mutated"] == false
    assert ".tsx" in profile["static_syntax_extensions"]
    refute ".tsx" in profile["test_file_extensions"]
    root = Path.join(System.tmp_dir!(), "mutator_card_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    example = profile["example"]
    File.write!(Path.join(root, profile["marker"]), Jason.encode!(example))
    assert {:ok, ^example} = JavaScript.read_profile(root)
    assert {:ok, JavaScript} = Detector.detect(root)
  end

  test "API service-card alias preserves the same execution profile contract", %{conn: conn} do
    root = conn |> get(~p"/agents.json") |> json_response(200)
    api = build_conn() |> get(~p"/api/agents") |> json_response(200)
    assert api["execution_profiles"] == root["execution_profiles"]
    assert api["states"] == root["states"]
    assert api["endpoints"]["submit"]["method"] == "POST"
  end
end
