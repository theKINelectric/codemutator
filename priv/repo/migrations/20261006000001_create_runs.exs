defmodule Mutator.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs) do
      add :source_path, :text, null: false
      add :snapshot_hash, :text
      add :language, :text, null: false
      add :toolchain, :map, default: %{}
      add :scanner_version, :text, null: false
      add :test_argv, {:array, :text}, null: false
      add :scope_filter, :text
      add :mutant_limit, :integer
      add :state, :text, null: false, default: "queued"
      add :failure_reason, :text
      add :artifact_root, :text
      add :baseline_ms, :integer
      add :mutant_timeout_ms, :integer
      add :run_budget_ms, :integer
      add :selected_sites, :integer, default: 0
      add :terminal_sites, :integer, default: 0
      add :killed, :integer, default: 0
      add :survived, :integer, default: 0
      add :invalid, :integer, default: 0
      add :error_count, :integer, default: 0
      add :cancelled_count, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:runs, [:state])
    create index(:runs, [:inserted_at])

    create table(:sites) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :site_key, :text, null: false
      add :file, :text, null: false
      add :function, :text, null: false
      add :function_line, :integer, null: false
      add :function_end_line, :integer, null: false
      add :line, :integer, null: false
      add :byte_start, :integer, null: false
      add :byte_end, :integer, null: false
      add :file_hash, :text, null: false
      add :operator, :text, null: false
      add :original, :text, null: false
      add :replacement, :text, null: false
      add :scheduling_state, :text, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sites, [:run_id, :site_key])
    create index(:sites, [:run_id, :scheduling_state])

    create table(:outcomes) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :status, :text, null: false
      add :reason, :text
      add :phase, :text
      add :exit_code, :integer
      add :elapsed_ms, :integer
      add :log_path, :text
      add :log_excerpt, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:outcomes, [:run_id, :site_id])
    create index(:outcomes, [:run_id, :status])
  end
end
