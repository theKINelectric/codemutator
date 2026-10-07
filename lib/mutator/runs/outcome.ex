defmodule Mutator.Runs.Outcome do
  @moduledoc """
  The terminal outcome of executing one mutant.

  Statuses (MVP_PLAN.md §1):

    * `killed`    — a test failed/crashed, or the mutant deadline was exceeded.
                    `reason`: `assertion` | `runtime_crash` | `timeout`.
    * `survived`  — the configured tests passed.
    * `invalid`   — the compiler rejected the mutation. Not a kill; excluded
                    from the score (deliberate difference from the reference).
    * `error`     — infrastructure failure. Dispatch stops.
    * `cancelled` — explicitly cancelled before a terminal result.
    * `interrupted` — work destroyed by a topology/process failure; unknown.

  Score = killed / (killed + survived).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(killed survived invalid error cancelled interrupted)
  @scored ~w(killed survived)

  schema "outcomes" do
    field :status, :string
    field :reason, :string
    field :phase, :string
    field :exit_code, :integer
    field :elapsed_ms, :integer
    field :log_path, :string
    field :log_excerpt, :string

    belongs_to :run, Mutator.Runs.Run
    belongs_to :site, Mutator.Runs.Site

    timestamps(type: :utc_datetime)
  end

  def changeset(outcome, attrs) do
    outcome
    |> cast(attrs, [:run_id, :site_id, :status, :reason, :phase, :exit_code, :elapsed_ms, :log_path, :log_excerpt])
    |> validate_required([:run_id, :site_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:site_id, name: :outcomes_run_id_site_id_index)
  end

  def scored?(%__MODULE__{status: status}), do: status in @scored
  def statuses, do: @statuses
end
