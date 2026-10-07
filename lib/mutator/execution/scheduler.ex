defmodule Mutator.Execution.Scheduler do
  @moduledoc """
  Durable queue selection: one active run, at most three queued (MVP_PLAN.md
  §1). `notify/0` is called on submit; completion re-triggers. If the VM
  dies, startup reconciliation marks interrupted work and queued runs are
  picked up again.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Mutator.Execution.RunCoordinator
  alias Mutator.Runs


  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def notify do
    if GenServer.whereis(__MODULE__), do: send(__MODULE__, :kick)
    :ok
  end

  @impl true
  def init(_opts) do
    reconcile_on_startup()
    send(self(), :kick)
    {:ok, %{task: nil}}
  end

  @impl true
  def handle_info(:kick, %{task: nil} = state) do
    case next_queued() do
      nil ->
        {:noreply, state}

      run ->
        task = Task.Supervisor.async_nolink(Mutator.TaskSup, fn ->
          Logger.info("scheduler starting run #{run.id}")
          RunCoordinator.run(run.id)
        end)

        {:noreply, %{state | task: task}}
    end
  end

  def handle_info(:kick, state), do: {:noreply, state}

  def handle_info({ref, :ok}, %{task: %Task{ref: ref}} = state) do
    {:noreply, %{state | task: nil}, {:continue, :next}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("active run task down: #{inspect(reason)}")
    {:noreply, %{state | task: nil}, {:continue, :next}}
  end

  # Stale monitor from a task whose result already arrived.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_continue(:next, state) do
    send(self(), :kick)
    {:noreply, state}
  end

  defp next_queued do
    from(r in Runs.Run, where: r.state == "queued", order_by: [asc: r.inserted_at], limit: 1)
    |> Mutator.Repo.one()
  end

  defp reconcile_on_startup do
    # Work from a previous VM is unknown; a fresh rerun is offered instead of
    # an automatic resume (MVP_PLAN.md §2).
    from(r in Runs.Run, where: r.state in ~w(preparing baselining scanning running))
    |> Mutator.Repo.update_all(set: [state: "interrupted"])
  end

end
