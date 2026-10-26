defmodule Mutator.Runs.Site do
  @moduledoc """
  One selected mutation inside one run: a byte span in one file, an operator,
  and the replacement text. `site_key` is deterministic (file hash + span +
  operator + replacement) so a rerun of the same subject yields the same keys.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @scheduling_states ~w(pending dispatched terminal)

  schema "sites" do
    field :site_key, :string
    field :file, :string
    field :function, :string
    field :function_line, :integer
    field :function_end_line, :integer
    field :line, :integer
    field :byte_start, :integer
    field :byte_end, :integer
    field :file_hash, :string
    field :operator, :string
    field :original, :string
    field :replacement, :string
    field :scheduling_state, :string, default: "pending"

    belongs_to :run, Mutator.Runs.Run
    has_one :outcome, Mutator.Runs.Outcome

    timestamps(type: :utc_datetime)
  end

  def changeset(site, attrs) do
    site
    |> cast(attrs, [
      :run_id,
      :site_key,
      :file,
      :function,
      :function_line,
      :function_end_line,
      :line,
      :byte_start,
      :byte_end,
      :file_hash,
      :operator,
      :original,
      :replacement,
      :scheduling_state
    ])
    |> validate_required([
      :run_id,
      :site_key,
      :file,
      :function,
      :line,
      :byte_start,
      :byte_end,
      :file_hash,
      :operator,
      :original,
      :replacement
    ])
    |> validate_inclusion(:scheduling_state, @scheduling_states)
    |> unique_constraint(:site_key, name: :sites_run_id_site_key_index)
  end
end
