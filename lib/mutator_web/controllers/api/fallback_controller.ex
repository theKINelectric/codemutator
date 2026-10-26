defmodule MutatorWeb.API.FallbackController do
  @moduledoc "Uniform JSON errors for the agent API."
  use MutatorWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn |> put_status(:not_found) |> json(%{error: "run not found"})
  end

  def call(conn, {:error, :bad_id}) do
    conn |> put_status(:bad_request) |> json(%{error: "invalid run id"})
  end

  def call(conn, {:error, :already_terminal}) do
    conn |> put_status(:conflict) |> json(%{error: "run already terminal"})
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid submission", details: errors_on(changeset)})
  end

  def call(conn, {:error, reason}) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
