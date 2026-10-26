defmodule MutatorWeb.PageControllerTest do
  use MutatorWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "codeMUTATOR"
    assert html_response(conn, 200) =~ "iStellar~iModal"
  end
end
