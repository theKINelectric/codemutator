---
name: codemutator
description: Submit a local codebase to the codeMUTATOR mutation-testing service (Zig qualified; Elixir/Swift adapters; Kotlin detection). Use when the user asks to mutation-test, score test-suite strength, find surviving mutants, or "run codemutator/mutator on <path>". Returns killed/survived per mutant and a score killed/(killed+survived).
---

# codeMUTATOR — mutation testing as a service

Service: **http://localhost:4300** (production instance, loopback only).
CLI: `bin/codemutator` in a codeMUTATOR checkout.

## When to use

- "How strong are the tests in <project>?" → submit, wait, report score + survivors.
- "Find weak spots / surviving mutants in <file or dir>" → scope the submission.
- Never submit a directory that contains the service itself; always absolute paths.

## Core workflow

```bash
B=/path/to/codemutator/bin/codemutator

# 1. submit and wait (bounded sample first!)
$B run /abs/path/to/project --scope lib/ --limit 12 --wait

# 2. evidence
$B outcomes <id> killed      # what the suite catches
$B outcomes <id> survived    # what slips through — the actionable list
$B outcomes <id> invalid     # compiler-rejected mutants (excluded from score)
```

Equivalent HTTP: `POST /api/runs` `{"source_path":"/abs/path","scope_filter":"lib/","mutant_limit":12}` then poll `GET /api/runs/:id` until `"terminal":true`; full rows at `GET /api/runs/:id/outcomes`. Service card: `GET /agents.json`.

## Reading results

- **score = killed / (killed + survived)**; `invalid`/`error`/`cancelled` excluded but counted.
- `survived` in code the suite never exercises (CLI mains, dead branches) is expected — those are coverage findings, not test bugs.
- `survived` inside functions the suite *does* exercise = weak assertions: read `log_path` for the exact mutant diff context.
- States: queued → preparing → baselining → scanning → running → completed | failed | cancelled | interrupted | budget_exhausted. One active run; others queue.
- A failed baseline (subject tests don't pass unmutated) fails the run with the log tail — fix the subject first.
- A full unscoped run can be huge; always pass `--scope` and `--limit` for a first sample, then widen.

## Guarantees

The submitted directory is **never written**; all execution happens on service-side copies under `temporary_subject/<run_id>/` (its own logs are kept per run). Site selection is deterministic (round-robin across files). Each mutant's subprocess has its own process group with TERM→KILL deadlines; a run never hangs past its budget (default 60 min dispatch deadline, drains in-flight work).

## Language support

| Language | Status |
| --- | --- |
| Zig 0.16 | qualified (`zig build test`, mise-pinned, per-lane caches) |
| Elixir | adapter (`MIX_ENV=test mix test`) |
| Swift | adapter (`swift test`, SwiftPM only, no Xcode projects) |
| Kotlin | detection only — reports `toolchain_unavailable` |

## MCP

For MCP-capable clients, run `bin/codemutator_mcp.py` (tools: submit_run, get_run, list_outcomes, cancel_run).
