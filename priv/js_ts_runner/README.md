# JavaScript/TypeScript execution boundary

This directory contains the native Node-test worker used by
`Mutator.Languages.JavaScript`. The [project README](../../README.md#javascript-and-typescript)
describes subject setup, supported syntax and the explicit `.codemutator.json`
profile. No compiler, package-manager cache or downloaded archive is bundled here.

## Service invocation

```sh
node priv/js_ts_runner/bin/runner.mjs \
  --worker /absolute/service/workers/lane-0/project \
  --compiler /absolute/trusted/typescript/lib/tsc.js \
  --service-owned-group \
  --timeout 600000
```

Only these flags are accepted; the compiler is optional when the profile has no
typecheck gate. A configured compiler path takes precedence over the service's
`CODEMUTATOR_TSC`, then the worker's physical
`node_modules/typescript/lib/tsc.js`. Paths select operator-controlled tools;
the subject JSON cannot select executable code. No shell command, `npm test`,
dependency install, lifecycle script or watch mode is used.

The caller supplies an already isolated physical project tree. This worker does
not create another project copy or mutate/restore source: those responsibilities
belong to Workspaces and ExecuteMutant. It writes only its private scratch
home/cache/report beside the lane. A symlinked tree fails explicitly.

The adapter always passes `--service-owned-group`. In this mode every compiler
and test child inherits ProcessRunner's recorded process group; the project
checks have no inner deadline. ProcessRunner owns the deadline and final group
cleanup, including after an untrappable wrapper exit. Node/compiler identity
probes remain bounded to five seconds. This mode requires that caller lifecycle;
it is not a standalone way to obtain a deadline.

Only PATH, LANG, LC_* and TZ are inherited by subject/compiler subprocesses.
Private HOME/TMPDIR, CI and explicit Node settings are then added. Arbitrary
service variables and credentials are not inherited. Actual selected Node and
TypeScript versions are obtained by bounded `--version` probes and retained in
the result. Unknown or invalid identities fail before the project executes.

## Result protocol

The trusted reporter writes its structured summary to a separate scratch file,
so subject stdout cannot replace it. A real executed-test count is required:
Node's synthetic successful empty-file result, skipped tests and todo tests
alone do not satisfy that condition.

The CLI emits one final stdout line, with protocol 1 and bounded diagnostics:

```text
CODEMUTATOR_JS_RESULT {"protocol":1,"status":"passed","reason":null,"phase":"worker","tests":{"executed":2,"counts":{"passed":2,"failed":0,"cancelled":0}},"runtime":{"node":"v26.10.0","compiler":{"name":"typescript","version":"6.0.3"}},"compilerDiagnostics":[]}
```

The example versions identify the exercised toolchain; runtime values come from
the actual selected executables.

| Exit | Result |
| --- | --- |
| 0 | passed or survived |
| 20 | invalid: known compiler/syntax rejection |
| 21 | killed: assertion, runtime crash or standalone trial deadline |
| 22 | profile, dependency, no-test, infrastructure or unclassified error |

`JavaScript.result_metadata/1` validates the final sentinel, field bounds and
executed-test evidence. Its classifier also requires matching status/exit
semantics. A missing, malformed, zero-test or conflicting result is an error;
it is never inferred to be a kill from a generic nonzero exit. Compiler-rejected
mutants are excluded from the score, while assertions are scored kills. Missing
dependencies remain errors even when a mutation first reaches a dynamic import.

## Modules and verification

- `runner.mjs`: `readProfile`, `executeWorker`, `runSubject` and child ownership.
- `reporter.mjs`: Node-test event/result normalization.
- `scanner-bridge.mjs`: static protocol-1 facts mapped to Scanner.Site fields;
  hashes, UTF-8 byte slices and path-inclusive deterministic keys are verified.
- `bin/runner.mjs`: service flags and the bounded trial JSON entry point.

`executeWorker({workspaceRoot, compilerPath, nodePath, timeoutMs, serviceOwnedGroup})`
runs the supplied worker. The `runSubject` trial helper instead makes a
disposable physical copy, validates and applies a mutation, restores it and
cleans up. Standalone trial mode keeps its own detached groups/deadlines; the
trial CLI forwards TERM/INT to those groups. Production uses the service-owned
mode above.

Portable contract tests and weak/strong fixtures live under `test/js_ts_runner`
and `test/fixtures/js_ts_runner`. From the repository root:

```sh
CODEMUTATOR_E2E_TSC=/absolute/installed/typescript/lib/tsc.js \
  node --test test/js_ts_runner/*.test.mjs
```

The tests require an explicit installed compiler and the sibling shared parser.
They fail clearly when either is missing and never fetch a replacement. The
service E2E tests exercise this worker through the actual FlowExtra/SQLite
pipeline; standalone trials do not substitute for that gate.
