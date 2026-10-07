defmodule MutatorWeb.RunLive.Index do
  use MutatorWeb, :live_view

  alias Mutator.Runs

  @impl true
  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(Mutator.PubSub, "runs")

    {:ok,
     socket
     |> assign(:runs, Runs.list_runs())
     |> assign(:form, to_form(%{"source_path" => "", "mutant_limit" => ""}))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: socket

  @impl true
  def handle_event("submit", %{"source_path" => path, "mutant_limit" => limit, "scope_filter" => scope}, socket) do
    attrs = %{
      source_path: String.trim(path),
      mutant_limit: parse_limit(limit),
      scope_filter: scope
    }

    case Runs.submit_run(attrs) do
      {:ok, run} ->
        {:noreply, push_navigate(socket, to: ~p"/runs/#{run.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(Map.merge(attrs, %{"mutant_limit" => limit}), as: :run, errors: changeset.errors))}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    Runs.cancel_run(String.to_integer(id))
    {:noreply, assign(socket, :runs, Runs.list_runs())}
  end

  @impl true
  def handle_info(:runs_changed, socket) do
    {:noreply, assign(socket, :runs, Runs.list_runs())}
  end

  def handle_info({:mutator, _run_id, _event}, socket) do
    {:noreply, assign(socket, :runs, Runs.list_runs())}
  end

  defp parse_limit(""), do: nil

  defp parse_limit(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp score_badge(run) do
    case Runs.score(run) do
      nil -> "N/A"
      s -> "#{Float.round(s * 100, 1)}%"
    end
  end

  defp state_class(state) do
    case state do
      s when s in ~w(completed) -> "bg-emerald-100 text-emerald-800"
      s when s in ~w(failed) -> "bg-rose-100 text-rose-800"
      s when s in ~w(cancelled interrupted budget_exhausted) -> "bg-amber-100 text-amber-800"
      _ -> "bg-sky-100 text-sky-800"
    end
  end
end
