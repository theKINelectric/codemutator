defmodule Mutator.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MutatorWeb.Telemetry,
      Mutator.Repo,
      {Ecto.Migrator,
        repos: Application.fetch_env!(:mutator, :ecto_repos),
        skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:mutator, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Mutator.PubSub},
      # Mutation engine: supervised dispatch tasks + the one-active-run
      # scheduler (MVP_PLAN.md §2).
      {Task.Supervisor, name: Mutator.TaskSup},
      Mutator.Execution.Scheduler,
      # Start to serve requests, typically the last entry
      MutatorWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Mutator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MutatorWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end
end
