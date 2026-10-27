defmodule MutatorWeb.RunLive.Show do
  use MutatorWeb, :live_view

  alias Mutator.Runs

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    run = Runs.get_run(id)

    if run do
      Runs.subscribe(run.id)

      {:ok,
       socket
       |> assign(:run, run)
       |> assign(:outcomes, Runs.list_outcomes(run.id))
       |> assign(:functions, Runs.function_scores(run.id))}
    else
      {:ok, socket |> put_flash(:error, "Run not found") |> redirect(to: ~p"/runs")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel", _params, socket) do
    Runs.cancel_run(socket.assigns.run.id)
    {:noreply, assign(socket, :run, Runs.get_run(socket.assigns.run.id))}
  end

  @impl true
  def handle_info({:mutator, _run_id, _event}, socket) do
    run = Runs.get_run(socket.assigns.run.id)

    {:noreply,
     socket
     |> assign(:run, run)
     |> assign(:outcomes, Runs.list_outcomes(run.id))
     |> assign(:functions, Runs.function_scores(run.id))}
  end

  defp progress_percent(run) do
    if run.selected_sites > 0 do
      Float.round(run.terminal_sites / run.selected_sites * 100, 1)
    else
      0.0
    end
  end

  defp score_display(run) do
    case Runs.score(run) do
      nil -> "N/A"
      s -> "#{Float.round(s * 100, 1)}%"
    end
  end

  defp fn_score(f) do
    case f.score do
      nil -> "N/A"
      s -> "#{Float.round(s * 100, 1)}%"
    end
  end
end
