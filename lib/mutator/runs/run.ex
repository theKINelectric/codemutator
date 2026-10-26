defmodule Mutator.Runs.Run do
  @moduledoc """
  One mutation-testing run against one subject directory.

  State progression (MVP_PLAN.md §2):

      queued -> preparing -> baselining -> scanning -> running -> completed
                                                          |-> failed
      terminal alternatives: cancelled | interrupted | budget_exhausted
  """

  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(queued preparing baselining scanning running completed failed cancelled interrupted budget_exhausted)
  @terminal ~w(completed failed cancelled interrupted budget_exhausted)

  schema "runs" do
    field :source_path, :string
    field :snapshot_hash, :string
    field :language, :string
    field :toolchain, :map, default: %{}
    field :scanner_version, :string, default: "zig-token-1"
    field :test_argv, {:array, :string}, default: []
    field :scope_filter, :string
    field :mutant_limit, :integer
    field :state, :string, default: "queued"
    field :failure_reason, :string
    field :artifact_root, :string
    field :baseline_ms, :integer
    field :mutant_timeout_ms, :integer
    field :run_budget_ms, :integer
    field :selected_sites, :integer, default: 0
    field :terminal_sites, :integer, default: 0
    field :killed, :integer, default: 0
    field :survived, :integer, default: 0
    field :invalid, :integer, default: 0
    field :error_count, :integer, default: 0
    field :cancelled_count, :integer, default: 0

    has_many :sites, Mutator.Runs.Site
    has_many :outcomes, Mutator.Runs.Outcome

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :source_path,
      :snapshot_hash,
      :language,
      :toolchain,
      :scanner_version,
      :test_argv,
      :scope_filter,
      :mutant_limit,
      :state,
      :failure_reason,
      :artifact_root,
      :baseline_ms,
      :mutant_timeout_ms,
      :run_budget_ms,
      :selected_sites,
      :terminal_sites,
      :killed,
      :survived,
      :invalid,
      :error_count,
      :cancelled_count
    ])
    |> validate_required([:source_path, :language, :test_argv])
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:source_path, name: :runs_source_path_state_index)
  end

  def terminal?(%__MODULE__{state: state}), do: state in @terminal
  def states, do: @states
end
