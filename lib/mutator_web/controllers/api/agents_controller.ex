defmodule MutatorWeb.API.AgentsController do
  @moduledoc """
  Machine-readable service card for agents: GET /agents.json describes the
  API shapes so an agent can self-configure without scraping HTML.
  """

  use MutatorWeb, :controller

  def show(conn, _params) do
    base = get_base_url(conn)

    json(conn, %{
      service: "codeMUTATOR",
      tagline: "mutation testing as a service",
      developer: "iStellar~iModal",
      languages: %{
        zig: "qualified (zig build test, mise-pinned)",
        rust:
          "qualified (cargo test; conservative lexical operators, excludes #[test] and macro bodies)",
        elixir: "adapter ready (MIX_ENV=test mix test)",
        swift: "adapter ready (swift test, SwiftPM only)",
        kotlin: "detection only — reports toolchain_unavailable"
      },
      score: "killed / (killed + survived); invalid/error/cancelled excluded",
      endpoints: %{
        submit: %{
          method: "POST",
          url: base <> "/api/runs",
          body: %{
            source_path: "/abs/path (required)",
            scope_filter: "src/ (optional path prefix)",
            mutant_limit: 20,
            run_budget_ms: 3_600_000
          }
        },
        status: %{method: "GET", url: base <> "/api/runs/{id}"},
        outcomes: %{method: "GET", url: base <> "/api/runs/{id}/outcomes"},
        cancel: %{method: "POST", url: base <> "/api/runs/{id}/cancel"}
      },
      states:
        ~w(queued preparing baselining scanning running completed failed cancelled interrupted budget_exhausted),
      guarantees: [
        "the submitted directory is never written: runs work on copies under temporary_subject/",
        "one active run at a time; additional submissions queue",
        "site selection is deterministic (round-robin across files, byte order within)"
      ]
    })
  end

  defp get_base_url(conn) do
    scheme = if conn.scheme == :http, do: "http", else: "https"
    "#{scheme}://#{conn.host}:#{conn.port}"
  end
end
