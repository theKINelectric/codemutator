defmodule Mutator.CancellationStateTest do
  use Mutator.DataCase, async: false
  alias Mutator.{Repo, Runs}
  alias Mutator.Runs.Run

  test "a cancelled run cannot be resurrected by transitions holding an older run struct" do
    stale =
      %Run{}
      |> Run.changeset(%{
        source_path: "/tmp/unscheduled-cancel-contract",
        language: "auto",
        test_argv: ["auto"],
        state: "baselining"
      })
      |> Repo.insert!()

    assert {:ok, %{state: "cancelled"}} = Runs.cancel_run(stale.id)

    for next <- ~w(baselining scanning running completed failed) do
      assert {:ok, %{state: "cancelled"}} =
               Runs.transition(stale, next, %{
                 failure_reason: "late stale update",
                 selected_sites: 99
               })

      actual = Runs.get_run(stale.id)
      assert actual.state == "cancelled"
      assert actual.failure_reason == nil
      assert actual.selected_sites == 0
    end
  end
end
