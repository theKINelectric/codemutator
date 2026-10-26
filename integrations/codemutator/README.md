# codemutator — Claude Mod

Bounded **asynchronous** mutation-testing integration for a locally running
[codeMUTATOR](https://codeberg.org/kin_electric/codemutator) service. Mutation
runs take minutes, so nothing here ever blocks a hook: runs are submitted
explicitly, polled once per session boundary, and reported when the service
reaches a terminal state.

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
- changed tree since submission → **stale refusal**: the run is reported as
  not current and never promoted to a verdict.

Scoring follows the service contract: `killed / (killed + survived)`;
`invalid`/`error`/`cancelled` are excluded from the denominator and shown as
counts. A zero denominator surfaces "no score" rather than a fake number.

## Source immutability

The fingerprint at submission covers the scoped source tree plus the root
manifests (`Cargo.toml`, `mix.exs`, `build.zig`, …). It is re-derived at
report time; mismatch ⇒ stale. The service itself works on workspace copies —
the submitted tree is never written (see `runs/portfolio-rust-20261025/`
receipts).

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
- Fingerprint bounds: ≤ 512 files / ≤ 8 MiB of source; oversize ⇒ `unknown`,
  nothing submitted.
- No source content is sent anywhere but the configured local API.

## Layout

```
.claude-plugin/plugin.json   manifest
hooks/hooks.json             module registration
hooks/register.mjs           Mod (commands + Stop boundary)
tests/mod_test.mjs           contract controls (node --test)
tests/mod.test.ts            native surface tests (claude plugin test)
```

## Qualification

- `claude plugin validate` — strict pass (hooks, declared calls, env reads).
- `claude plugin test` — 4/4 native-surface tests (submit→poll→terminal,
  stale refusal, one-active-run + cancel, quiet boundary).
- `node --test tests/mod_test.mjs` — 5/5 contract controls including
  submit-while-down and boundary fail-open with a pending run.
- **Real-service execution** — `tests/real_service_harness.mjs` binds the
  actual Mod to real fetch/fs against a running service: run #3
  submit→boundary→completed (score 0.75, 3k/1s), source digest unchanged,
  run #4 cancel→terminal confirmed. Receipts:
  `licorice/runs/portfolio-rust-20261025/mod-codemutator/`.
- Engine e2e: `test/mutator/e2e_run_test.exs` (scoped Rust run, workspace
  cleaned).
