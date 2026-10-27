# codemutator — Claude Mod

Bounded **asynchronous** mutation-testing integration for a locally running
[codeMUTATOR](https://codeberg.org/kin_electric/codemutator) service. Mutation
runs take minutes, so nothing here ever blocks a hook: runs are submitted
explicitly, polled once per session boundary, and reported when the service
reaches a terminal state.

JavaScript/TypeScript projects opt into the service with a root
`.codemutator.json` profile. The profile names explicit Node test files, a
TypeScript project (or no typecheck), and source include/exclude patterns.
The Mod sends a project path and mutation scope; it does not install packages,
run package scripts, or infer a test command. See the [service README](../../README.md)
for the profile schema and supported execution lane. JSX/TSX syntax parsing
does not imply that the Node runner can execute JSX/TSX.

## Commands

| Command | Effect |
| --- | --- |
| `/codemutator-run [scope] [mutants] [budget_ms]` | Submit a scoped, bounded run for the current project. Defaults `src`, `9` mutants, `120000` ms — caps: **9 mutants, 120 s**. One active run per session+project. |
| `/codemutator-status` | Pending runs for this session+project with live service state. |
| `/codemutator-cancel <id>` | Request cancellation, then verify a terminal state on a fresh read — never trusts the cancel POST alone. |
| `/codemutator` | Same as status. |

## Boundary behavior

`classic.Stop` polls **once** per pending run — a single `GET /api/runs/:id`,
never a wait loop:

- still running → short notice, nothing else;
- terminal → fetches outcomes, re-fingerprints the working tree, writes a
  versioned evidence envelope (`schema: codemutator-mod/1`), and reports;
- changed fingerprint since submission → **stale refusal**: the run is reported as
  not current and never promoted to a verdict.
- unreadable or oversized fingerprint at report time → **unknown**: the Mod
  records `fingerprint_complete: false` and refuses to promote the run.

Scoring follows the service contract: `killed / (killed + survived)`;
`invalid`/`error`/`cancelled` are excluded from the denominator and shown as
counts. A zero denominator surfaces "no score" rather than a fake number.

## Source freshness and immutability

For a project containing `.codemutator.json`, the fingerprint covers all
regular project files outside the excluded directories below, even when the
mutation scope is `src`. This includes `.js`, `.jsx`, `.mjs`, `.cjs`, `.ts`,
`.tsx`, `.mts`, `.cts`, declarations such as `.d.ts`/`.d.mts`/`.d.cts`, tests,
fixture data, the profile, package and lock files, custom TypeScript configs,
and configs reached through `extends`. Profile include/exclude patterns
select mutation candidates; they do not remove test or typecheck inputs from
the freshness fingerprint. Links and other nonregular project inputs make
the fingerprint unknown.

For other projects, the existing scoped source fingerprint remains, with the
eight JS/TS extensions added to the supported source suffixes. Root manifests
are included independently of scope: Cargo, Mix, Zig, Swift, Gradle and mise
manifests, plus `.codemutator.json`, `package.json`, `package-lock.json`,
`npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`,
and `tsconfig.json`. `config_digest` hashes the contents of these recognized
manifests. Tool identity `codemutator-mod@0.3.0` participates in the source
digest, so pending results fingerprinted by an older tool cannot be promoted
as current by this version.

The excluded directory names are `.git`, `deps`, `_build`, `target`,
`node_modules`, `vendor`, `dist`, `build`, `.build`, `.zig-cache`, `zig-out`,
and `.elixir_ls`. Installed dependencies, build products, runtime versions,
environment variables and external files are outside this fingerprint. A
current source digest is a project-source freshness check; it does not prove
that every runtime input stayed identical. Package and lock changes still
invalidate the result.

The Mod host normally exposes file reads as text. It hashes round-trippable
UTF-8 text, or raw `Uint8Array`/`ArrayBuffer` bytes if the host supplies them.
Replacement characters or unpaired surrogates from a text-only host make
the fingerprint unknown, because the original file bytes cannot be proven.
This conservatively rejects some valid text and binary fixtures; binary
inputs are never silently ignored or hashed through lossy decoding.

The digest is re-derived at report time; a mismatch refuses promotion. The
service operates on workspace copies and owns its separate source-custody
checks. The earlier Rust receipts are in
`licorice/runs/portfolio-rust-20261025/`.

## Configuration

| Env | Default | Notes |
| --- | --- | --- |
| `CODEMUTATOR_API` | `http://127.0.0.1:4300` | local service URL |
| `CODEMUTATOR_MOD_STATE` | `~/.local/state/codemutator-mod` | per-project state + evidence envelopes |
| `CODEMUTATOR_SUBMIT_MS` | `10000` | submit-POST bound (250 ms–60 s); timeout ⇒ uncertain submission |

State is keyed by `sha256(canonical project root)` and records
`{session, run_id, source_digest, scope, limits}` per pending run.

## Boundaries and failure posture

- Advisory only — the Mod never blocks a stop, never denies a tool call,
  never retries a submit on its own.
- The SDK has no request abort: a `/api/runs` POST that outlives
  `CODEMUTATOR_SUBMIT_MS` is an **uncertain submission** — it may still
  complete server-side. The one-run reservation is retained (persisted flag
  + retained promise): a second `/codemutator-run` is refused; the boundary
  reconciles — a late response adopting a landed run becomes the session's
  run, a server-side failure clears the reservation, and after
  `budget + 120 s` any orphan is terminal by construction and the flag
  releases. `/codemutator-status` shows the reservation.
- Response bodies over **256 KiB bytes** (UTF-8 counted, post-buffering — the
  SDK delivers whole bodies) are `over-cap` ⇒ unreadable, never a verdict.
- Service unreachable / malformed responses → `unknown` notice, fail-open.
- Fingerprint bounds: ≤ 512 files / ≤ 8 MiB of hashed inputs, including root
  manifests, and ≤ 4096 visited directory entries. Exceeding a bound at
  submission means `unknown` and no POST; exceeding a bound at report time
  means an incomplete fingerprint and no promoted verdict. The host buffers
  each file read before the byte bound can be checked.
- No source content is sent anywhere but the configured local API.

## Layout

```
.claude-plugin/plugin.json   manifest
hooks/hooks.json             module registration
hooks/register.mjs           Mod (commands + Stop boundary)
tests/mod_test.mjs           contract controls (node --test)
tests/mod.test.ts            native surface tests (claude plugin test)
```

## Verification

- `node --test tests/mod_test.mjs` — 40/40 dependency-free contract controls,
  including submit→edit→terminal stale refusal for every JS/TS extension,
  declarations, tests, profile, manifest/config and fixture inputs, plus
  incomplete-fingerprint refusal and existing asynchronous lifecycle tests.
  These tests use a simulated Mod host and service; they do not qualify the
  JavaScript runner against a live service.
- Earlier `claude plugin validate` — strict pass (hooks, declared calls,
  env reads), before the JS/TS fingerprint update.
- Earlier `claude plugin test` — 4/4 native-surface tests (submit→poll→terminal,
  stale refusal, one-active-run + cancel, quiet boundary).
- Earlier **Rust real-service execution** — `tests/real_service_harness.mjs` binds the
  actual Mod to real fetch/fs against a running service: run #3
  submit→boundary→completed (score 0.75, 3k/1s), source digest unchanged,
  run #4 cancel→terminal confirmed. Receipts:
  `licorice/runs/portfolio-rust-20261025/mod-codemutator/`.
- Engine e2e: `test/mutator/e2e_run_test.exs` (scoped Rust run, workspace
  cleaned).
