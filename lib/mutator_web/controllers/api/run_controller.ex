defmodule MutatorWeb.API.RunController do
  @moduledoc """
  Agent-facing JSON API. Loopback-trusted: no auth (bind to 127.0.0.1).

      POST /api/runs              submit: {source_path, scope_filter?, mutant_limit?, run_budget_ms?}
      GET  /api/runs/:id          status + counts + score
      GET  /api/runs/:id/outcomes full outcome rows (join sites)
      POST /api/runs/:id/cancel   request cancellation

  Responses are plain JSON, stable shapes, safe for scripted polling.
  """

  use MutatorWeb, :controller

  alias Mutator.Runs

  action_fallback MutatorWeb.API.FallbackController

  def create(conn, params) do
    attrs = %{
      source_path: params["source_path"],
      scope_filter: params["scope_filter"],
      mutant_limit: parse_int(params["mutant_limit"]),
      run_budget_ms: parse_int(params["run_budget_ms"])
    }

    with {:ok, run} <- Runs.submit_run(attrs) do
      conn
      |> put_status(:created)
      |> json(run_json(run))
    end
  end

  def show(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         %Runs.Run{} = run <- Runs.get_run(id) do
      json(conn, run_json(run))
    else
      {_, _} -> {:error, :bad_id}
      nil -> {:error, :not_found}
    end
  end

  def outcomes(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         %Runs.Run{} = run <- Runs.get_run(id) do
      json(conn, %{
        run_id: run.id,
        state: run.state,
        score: score_value(run),
        outcomes:
          Enum.map(Runs.list_outcomes(run.id), fn o ->
            %{
              site_id: o.site_id,
              file: o.site.file,
              line: o.site.line,
              function: o.site.function,
              operator: o.site.operator,
              original: o.site.original,
              replacement: o.site.replacement,
              status: o.status,
              reason: o.reason,
              elapsed_ms: o.elapsed_ms,
              log_path: o.log_path
            }
          end)
      })
    else
      {_, _} -> {:error, :bad_id}
      nil -> {:error, :not_found}
    end
  end

  def cancel(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         %Runs.Run{} = run <- Runs.get_run(id),
         {:ok, run} <- Runs.cancel_run(run.id) do
      json(conn, run_json(run))
    else
      {_, _} -> {:error, :bad_id}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp run_json(run) do
    %{
      id: run.id,
      state: run.state,
      terminal: Mutator.Runs.Run.terminal?(run),
      source_path: run.source_path,
      language: run.language,
      scope_filter: run.scope_filter,
      mutant_limit: run.mutant_limit,
      run_budget_ms: run.run_budget_ms,
      selected_sites: run.selected_sites,
      terminal_sites: run.terminal_sites,
      killed: run.killed,
      survived: run.survived,
      invalid: run.invalid,
      errors: run.error_count,
      cancelled: run.cancelled_count,
      baseline_ms: run.baseline_ms,
      score: score_value(run),
      failure_reason: run.failure_reason,
      detail_url: "/runs/#{run.id}",
      outcomes_url: "/api/runs/#{run.id}/outcomes"
    }
  end

  defp score_value(run) do
    case Runs.score(run) do
      nil -> nil
      s -> Float.round(s, 4)
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(_), do: nil
end
