# 💥🔫 codeMUTATOR

Mutation testing as a service · developed by 🛸🕳️ **iStellar~iModal**

A standalone web service inspired by [unclebob's
mutator](https://codeberg.org/unclebob/mutator.mirror) (read-only reference at
`__centaurus_repos/_community/mutator`): submit a local project directory, the
service copies its current working tree under `temporary_subject/`, applies one mutation at a time
to a private copy, runs the configured tests, and reports killed/survived
outcomes with per-function scores.

Built with **Phoenix 1.7 + FlowExtra (railway pipelines on GenStage) +
SQLite** (`ecto_sqlite3`). Qualified for **Zig 0.16** and **Rust** (cargo
1.98, e2e-verified) and an explicit **JavaScript/TypeScript** Node-test profile
(exercised on Node 26.10.0 + TypeScript 6.0.3); **Elixir** and **Swift** adapters implement the same
boundary (qualification pending); **Kotlin** is detected and reported as
`toolchain_unavailable` until a JDK/Gradle profile exists on this host.

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

## JavaScript and TypeScript

The qualified initial execution profile uses **Node's built-in `node:test`
runner**, physical dependency files and explicit source/test selection. The
adapter accepts Node **26.6 or newer within the 26.x series**; the service
fixtures were exercised on **26.10.0**, with TypeScript **6.0.3**. Vitest,
Jest, browser/DOM execution, JSX/TSX execution and linked package-manager
workspaces need their own qualification. There is no implicit `npm test`.

Install the trusted shared syntax parser beside this repository before starting
the service. Its locked parser is infrastructure shared with PoopBags; parsing
never imports the subject or loads its configuration:

```sh
cd ../js_ts_parser
npm ci --ignore-scripts
cd ../mutator
mix deps.get
```

Create an explicit root `.codemutator.json` in the subject:

```json
{
  "schemaVersion": 1,
  "language": "javascript-typescript",
  "runner": {"kind": "node-test", "files": ["test/client.test.mjs"]},
  "typecheck": {"kind": "typescript", "project": "tsconfig.json"},
  "source": {"include": ["src/**/*.ts"], "exclude": []}
}
```

The profile is strict JSON with exact fields, at most 64 KiB. Tests use explicit
relative file paths. Source include/exclude accepts simple `*`, `**` and `?`
globs; hidden path components require an explicit dot in the pattern. Unknown
versions, runners, fields and escaping paths fail before execution.
`package.json` alone never opts a Phoenix or other polyglot project into the JS
adapter. The explicit profile takes precedence over other language markers.

For JavaScript without a compiler gate, use `"typecheck":{"kind":"none"}` and
choose JS source patterns. The TypeScript qualification uses
`"kind":"typescript"`: a full `tsc --project ... --noEmit --incremental false`
check runs before the baseline and **before every mutant's tests**. Node's type
stripping alone is not type checking. Node executes only its supported erasable
TypeScript syntax; tsconfig aliases/transforms and project-reference builds are
outside this execution profile. A compiler-rejected mutant is `invalid`; a
missing compiler, module or other infrastructure failure is `error`. A passing
process with no real tests, or only skipped tests, is also an error.

Node resolves from operator configuration `CODEMUTATOR_NODE` (or the
`:javascript_node` application setting), then PATH. TypeScript resolves from
`:javascript_tsc`, `CODEMUTATOR_TSC`, or the physical worker's
`node_modules/typescript/lib/tsc.js`. These paths select trusted infrastructure;
the subject JSON cannot select an executable. For example, start the service
with `CODEMUTATOR_TSC=/absolute/installed/typescript/lib/tsc.js` when the compiler
is managed outside the subject. Missing tools produce an explicit preflight
failure. The service never installs subject dependencies, runs package lifecycle
scripts, or downloads a compiler while executing a run.

Prepare any required dependencies before submission. **The initial JS profile
rejects symlinks**, including ordinary npm `node_modules/.bin` links; it does not
remove or rewrite the user's links. Use dependency tooling to prepare a separate,
fully materialized physical tree when needed. pnpm/Yarn/workspace link layouts
are not qualified. Source `include`/`exclude` and `--scope` select mutation sites;
the entire physical subject is copied so tests, declarations and compiler inputs
remain available. Declaration files and tests are never mutation targets.

The shared AST parser understands `.js/.jsx/.mjs/.cjs/.ts/.tsx/.mts/.cts`, including
arrow functions, qualified nested callbacks and methods. That static syntax
coverage does not imply that the Node execution profile can run JSX/TSX. Parser
errors, missing parser dependencies and custody mismatches fail preparation;
they do not become a successful empty scan.

Run provenance includes the validated profile and its SHA-256, actual parser
package/policy versions, actual selected Node and TypeScript versions, and the
effective argv. The native execution backend preserves one verified byte patch,
separate compiler/test outcomes and the existing score denominator. StrykerJS
was evaluated separately; it is not nested inside the native worker.

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
| `Mutator.Languages.*` | adapter behaviour + Zig/Elixir/Swift/Kotlin/Rust/JavaScript-TypeScript + detector |
| `Mutator.Scanner` (+ `.Lexer`, `.JavaScript`) | lexical scanners plus the shared JS/TS AST bridge; exact byte sites and function ownership |

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
| JavaScript / TypeScript | AST boundary/equality operators; binary `+`↔`-`; `&&`↔`||`; boolean flips; logical-not removal preserving token separation; numeric 0↔1. Type syntax, declaration files, test callbacks, comments and literal text excluded. |
| Rust | `true`↔`false`; `==`↔`!=`; binary `+`↔`-`, `*`↔`/`; `&&`↔`||`; delete prefix `!` and unary `-`; `0`↔`1`. `<`/`>` only with a definite expression LHS (generics). `#[test]`/`mod tests` bodies, `macro_rules!`, `*const`/deref `*`, closure `||`, lifetimes, and raw strings never touched. |

Skipped everywhere: strings, comments, test bodies, top-level initializers,
type syntax. Uncertain constructs are never mutated.

## Development

```bash
mix test                                            # unit + gates
mix test test/mutator/e2e_run_test.exs --include e2e  # real zig + rust fixtures through the engine
CODEMUTATOR_E2E_TSC=/absolute/installed/typescript/lib/tsc.js mix test test/mutator/javascript_e2e_test.exs --include e2e
CODEMUTATOR_E2E_TSC=/absolute/installed/typescript/lib/tsc.js node --test test/js_ts_runner/*.test.mjs
```

The Node suite requires an explicitly configured installed compiler and the shared
parser checkout; it fails clearly if either is missing. No compiler archive is
vendored or fetched by the tests. Its controls include a surviving HTTP 200
boundary mutant caught by a stronger assertion, type-invalid versus missing
dependency outcomes, environment isolation, and process-group cleanup after an
untrappable wrapper exit. The service E2E gate covers persisted provenance,
baseline refusal, mutation execution and cancellation/source custody.

Milestones and acceptance gates: [MVP_PLAN.md](MVP_PLAN.md).
