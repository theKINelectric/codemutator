# 💥🔫 codeMUTATOR

Mutation testing as a service · developed by 🛸🕳️ **iStellar~iModal**

A standalone web service inspired by [unclebob's
mutator](https://codeberg.org/unclebob/mutator.mirror) (read-only reference at
`__centaurus_repos/_community/mutator`): submit a local project directory, the
service clones it under `temporary_subject/`, applies one mutation at a time
to a private copy, runs the subject's own tests, and reports killed/survived
outcomes with per-function scores.

Built with **Phoenix 1.7 + FlowExtra (railway pipelines on GenStage) +
SQLite** (`ecto_sqlite3`). Qualified for **Zig 0.16**; **Elixir** and **Swift**
adapters implement the same boundary (qualification pending); **Kotlin** is
detected and reported as `toolchain_unavailable` until a JDK/Gradle profile
exists on this host.

    Score = killed / (killed + survived)

`invalid` (compiler-rejected mutations), `error` (infrastructure), and
`cancelled`/`interrupted` outcomes are excluded from the score but counted
visibly — a deliberate difference from the reference tool, which counts
compile failures as kills (MVP_PLAN.md §1).

## Run it

Development:

```bash
mix setup          # deps + sqlite + assets
mix phx.server     # http://localhost:4300/runs
```

Production (this host): `/Users/lloyd/PRODUCTION_SERVERS/apps/codemutator` —
`bin/mutator stop|start` (via the `start` launcher; loopback :4300, SQLite and
workspaces under its `data/` directory).

## Agents

Most consumers of this service are agents. Three first-class interfaces:

**CLI** (`bin/codemutator`, pure python3, no deps):

```bash
bin/codemutator run /abs/path/to/project --scope lib/ --limit 12 --wait
bin/codemutator outcomes <id> survived
bin/codemutator cancel <id>
bin/codemutator info
```

**JSON API** (loopback, no auth): `POST /api/runs`, `GET /api/runs/:id`,
`GET /api/runs/:id/outcomes`, `POST /api/runs/:id/cancel`, service card at
`GET /agents.json`. Human-readable instructions live at `/agents`.

**MCP server** (`bin/codemutator_mcp.py`): tools `submit_run`, `get_run`,
`list_outcomes`, `cancel_run`:

```json
{ "mcpServers": { "codemutator": {
    "command": "/Volumes/Centaurus-A/__centaurus_repos/mutator/bin/codemutator_mcp.py",
    "env": { "CODEMUTATOR_URL": "http://localhost:4300" } } } }
```

An agent skill is installed at `~/.agents/skills/codemutator/` (and shipped in
`skills/codemutator/`).

Submit an absolute path (e.g. `/Volumes/.../honey_badger`), optionally with a
path filter (`src/`) and a mutant limit for a first bounded run. The original
directory is never a subprocess cwd and never written; a run works entirely
inside `temporary_subject/<run_id>/`:

    temporary_subject/<run_id>/
      snapshot/            pristine copy (rsync --no-links; caches/VCS excluded)
      workers/lane-N/      persistent per-slot project trees, patched in place
      scratch/lane-N/      private HOME and zig caches per lane
      logs/                baseline + per-mutant logs (argv/env provenance headers)

## Architecture

| Boundary | Responsibility |
| --- | --- |
| `MutatorWeb.RunLive.*` | submit, browse, live progress via PubSub; no test runs in requests |
| `Mutator.Runs` | context: submit/preview/cancel, idempotent outcome writes, scoring |
| `Mutator.Execution.Scheduler` | durable queue, one active run, restart reconciliation |
| `Mutator.Execution.RunCoordinator` | per-run fan-out/fan-in, lanes, budget, cancellation |
| `Mutator.Pipelines.PrepareRun` | FlowExtra railway: workspace → detect → baseline → scan |
| `Mutator.Pipelines.ExecuteMutant` | FlowExtra railway: `execute [count: 2] → record [count: 1]` |
| `Mutator.Execution.ProcessRunner` | argv subprocesses, own process groups, TERM→KILL deadlines, streamed logs |
| `Mutator.Workspaces` | snapshots, lanes, manifests (original-untouched proof) |
| `Mutator.Languages.*` | adapter behaviour + Zig/Elixir/Swift/Kotlin + detector |
| `Mutator.Scanner` (+ `.Lexer`) | token scanner: sites + function spans, per-language operator tables |

## Two host-specific facts worth knowing

1. **Two zig installs.** `~/.zig/zig` is 0.14.0 and cannot link libc on this
   macOS; mise's `zig@0.16.0` resolves to the working homebrew build. The
   adapter verifies the *binary's* version before use.

2. **A zig cache shared across tree copies is blind.** `--cache-dir` reuse
   over rsync'd copies made even a syntax-error file "pass" at cache-hit
   speed (zig's stat manifests consider the copy unchanged). Execution
   therefore uses persistent **lane trees patched in place** — same-path
   edits always invalidate — with per-lane caches that stay warm and correct.
   The reference tool's per-worker-directory model, adapted.

## Mutation operators (MVP set)

| Language | Operators |
| --- | --- |
| Zig | `true`↔`false`; `==`↔`!=`; `<`↔`<=`; `>`↔`>=`; binary `+`↔`-`; `and`↔`or`; delete prefix `!` and unary `-`; `0`↔`1`. No `*`//` (pointer syntax). |
| Elixir | the above plus `*`↔`/`, `&&`↔`||`, delete `not`. `do:` one-liners skipped (documented subset). |
| Swift | Java-style set; `<`/`>` only with a definite expression LHS (generics). `x!` never touched. |
| Kotlin | Java-style set plus `===`↔`!==`; `!in`/`!is`/`!!` never touched. Detection-only until a toolchain exists. |

Skipped everywhere: strings, comments, test bodies, top-level initializers,
type syntax. Uncertain constructs are never mutated.

## Development

```bash
mix test                                            # unit + gates
mix test test/mutator/e2e_run_test.exs --include e2e  # real zig fixture through the engine
```

Milestones and acceptance gates: [MVP_PLAN.md](MVP_PLAN.md).
