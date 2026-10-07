defmodule Mutator.Release do
  @moduledoc "Release tasks: migrations at deploy time (releases skip the boot migrator)."

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(:mutator, :ecto_repos)
  defp load_app, do: Application.ensure_all_started(:mutator)
end
