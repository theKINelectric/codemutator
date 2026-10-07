defmodule MutatorWeb.AgentsPageController do
  use MutatorWeb, :controller

  def index(conn, _params) do
    base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}"
    render(conn, :index, base_url: base_url)
  end
end
