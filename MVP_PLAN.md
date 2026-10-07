# Mutator as a service — proposed MVP

Build a local, single-host Phoenix service. Qualify Zig against HoneyBadger first, then qualify Elixir and Swift through the same adapter boundary. Detect Kotlin and return `toolchain_unavailable` until a Kotlin/JDK/build-tool combination has its own gate. The initial shipping gate is milestone 5; milestone 6 extends that release.

Use Phoenix 1.7.20, Elixir 1.20.4/OTP 28, SQLite through `ecto_sqlite3`, and the local `flowextra` dependency (`FlowExtra.*`; the Mix application/package name is `:flowextra`, not `:flow_extra`). Pin the dependency revision before release. A read-only smoke check confirmed Elixir 1.20.4/OTP 28 and Zig 0.16.0 through mise. The FlowExtra README reports qualification on OTP 29, so its OTP 28 downstream smoke gate is still required.

## 1. Scope and mutation policy

The UI accepts an absolute directory on the service host, detects the project, previews sites, and starts a background run. Include history, live progress, cancellation, per-file/per-function scores, survivor diffs, and outcome logs. Permit a file/directory filter and an explicit mutant limit; show the selected scope prominently. Use no coverage, one mutation per mutant, and the entire configured test command for each mutant.

Start with one active run, at most three queued runs, and two mutant workers. Bind to loopback and support trusted local projects. Public hosting, distributed workers, coverage, differential runs, equivalent-mutant detection, EDN integration, arbitrary shell commands, and reusable symlink overlays are later work.

The shared operator vocabulary is useful, but scanners must recognize language syntax and expression roles.

| Adapter | Mutation operators | Project/test boundary |
| --- | --- | --- |
| `Mutator.Languages.Zig` | `true` ↔ `false`; `==` ↔ `!=`; `<` ↔ `<=`; `>` ↔ `>=`; binary `+` ↔ `-`; `and` ↔ `or`; delete boolean `!` and unary numeric `-`; standalone integer `0` ↔ `1` | Root `build.zig`; pinned Zig 0.16.0; `zig build test` |
| `Mutator.Languages.Elixir` | Same literals/comparisons/arithmetic, plus `*` ↔ `/`; separately `and` ↔ `or` and `&&` ↔ `||`; delete `!`, `not`, and unary numeric `-` | Root `mix.exs`; `MIX_ENV=test mix test`; ordinary Mix projects first |
| `Mutator.Languages.Swift` | Java-style set, with `/` as division and `&&`/`||`; mutate built-in expression syntax only | SwiftPM `Package.swift`; `swift test`; no Xcode project support |
| `Mutator.Languages.Kotlin` | Proposed Java-style set; exclude `!in`, `!is`, generic delimiters, and declarations | Detection/status only initially; later a qualified Gradle wrapper/JDK profile |

For Zig, defer multiplication/division mutations until operand typing is available: `*` is also pointer syntax, and `/` has integer-specific requirements. Do not rewrite arbitrary integer multiplication into a division intrinsic in the first release. [Zig 0.16 language reference](https://ziglang.org/documentation/0.16.0/).

Emit sites inside supported production function bodies. Exclude comments, strings, character literals, documentation, test bodies, manifests, generated/vendor code, and type/declaration syntax. Zig tests can be embedded in production files, so filename filtering alone is insufficient. Defer top-level initializers, explicit comptime bodies, macros/quoted forms, and ambiguous syntax. Record skip reasons and present this as a supported subset.

Use a token stream with language-specific expression/function recognition for Zig; use Elixir's public quoted AST with literal/token metadata for function and expression classification, retaining original byte spans. Swift requires syntax-aware recognition, including generics, custom operators, raw/interpolated strings, and nested comments. If recognition is uncertain, skip the construct. No broad regex replacement. [Elixir parser API](https://hexdocs.pm/elixir/Code.html#string_to_quoted/2).

Each site records relative path, qualified function/signature and source range, original file hash, byte offset/length, line/column, operator ID, original text, replacement, and scanner version. Its deterministic key includes the file hash and mutation span. Verify hash and original bytes before patching; apply one patch to the unchanged snapshot. Function identity includes signature/range so overloads and Elixir clauses are not accidentally merged.

**Outcome policy:** `survived` means the configured tests passed; `killed` means a test failed/crashed or the mutant exceeded its deadline, with a reason such as `assertion`, `runtime_crash`, or `timeout`. Record compiler rejection as `invalid`, infrastructure failures as `error`, and unfinished work as `cancelled` or `interrupted`. An unrecognized nonzero exit is an error, not automatically a kill. Stop dispatch on infrastructure errors. Each adapter must qualify its diagnostic classifier; Zig's combined build/test command needs particular care.

Score = `killed / (killed + survived)`; zero denominator displays N/A. Display timeout kills separately. Invalid/error/cancelled/interrupted outcomes are excluded, with their counts visible. This deliberately differs from the reference tool, which includes compiler rejection in killed counts. An incomplete run's score is explicitly provisional.

## 2. Module boundaries and data

| Boundary | Responsibility |
| --- | --- |
| `MutatorWeb.RunLive.Index`, `.New`, `.Show` | Submit, preview, browse, cancel; subscribe to committed progress via Phoenix PubSub. Never run tests inside a web request/LiveView. |
| `Mutator.Runs` | Public context: `submit_run/1`, `preview_sites/1`, `get_run/1`, `list_outcomes/2`, `cancel_run/1`; state transitions, validation, score queries. |
| `Mutator.Runs.Run`, `.Site`, `.Outcome`; `Mutator.Repo` | Ecto schemas and SQLite queries. |
| `Mutator.Execution.Scheduler`, `.RunCoordinator` | Durable queue selection, one active run, per-run lifecycle, bounded dispatch, cancellation, completion, crash reconciliation. |
| `Mutator.Pipelines.PrepareRun`, `.ExecuteMutant` | FlowExtra railway transformations; no UI logic and no nested unbounded task fan-out. |
| `Mutator.Workspaces` | Snapshot/copy manifests, worker directories, private environment/cache paths, patch preconditions, bounded cleanup. |
| `Mutator.Execution.ProcessRunner` | Argument-vector subprocess execution, process ownership, streaming log files, deadlines, cancellation, filesystem write restriction. |
| `Mutator.Languages.Adapter`, `.Detector`; four language modules | Detect/preflight/prepare dependencies/scan/build command/classify output. Detection is separate from execution capability. |
| `Mutator.Runs.Writer` | Serialize short writes, record outcomes idempotently, commit progress before broadcasting. |

Use three tables initially:

- `runs`: source path, snapshot hash, language, toolchain/executable/version, scanner/operator versions, test argv, scope/filter/limit, state, selected/terminal counts, baseline durations, timeout policy, timestamps, failure reason, artifact root.
- `sites`: run FK, deterministic key, file/function/range/hash, patch span and replacement, scheduling state. Unique `(run_id, site_key)`.
- `outcomes`: run/site FK, status/reason/phase, exit code/signal, elapsed time, log path and bounded excerpt. Unique `(run_id, site_id)`; a repeated identical terminal write is a no-op and a conflicting terminal write raises an invariant error.

State progression: `queued → preparing → baselining → scanning → running → completed`; terminal alternatives include `failed`, `cancelled`, `interrupted`, and `budget_exhausted`. A baseline failure dispatches zero mutants. Zero selected sites completes with N/A. Cancellation closes every selected pending site explicitly. A restart preserves queued runs and marks active work interrupted after process reconciliation; MVP offers a fresh rerun rather than automatic resume.

Configure SQLite WAL, `busy_timeout: 5_000`, and a small pool (start at 2). Serialize application writes and keep transactions short; no transaction spans an external command. Derive function/file scores from outcomes instead of maintaining another table. Database sandbox tests run synchronously, as required by the adapter. [SQLite adapter configuration and limitations](https://hexdocs.pm/ecto_sqlite3/Ecto.Adapters.SQLite3.html).

## 3. Pipeline and workspace design

```text
RunLive → Runs.submit_run → SQLite queue → Scheduler/RunCoordinator
  PrepareRun: copy snapshot → detect/preflight → prepare dependencies
              → baseline on a copy → scan and persist selected sites
  RunCoordinator: select pending sites, dispatch bounded inputs
  ExecuteMutant: execute in fresh whole-tree workspace [count: 2]
                 → persist terminal outcome [count: 1]
  RunCoordinator: finalize after every selected site is terminal
```

`PrepareRun` accepts one run input. `ExecuteMutant` accepts one site input. FlowExtra `count` replicates a stage; it does not expand a list returned by `scan` into jobs. The coordinator is the explicit fan-out/fan-in boundary.

Use `pipe :execute, count: 2`, with workspace creation, patch, command, and cleanup within that execution callback; splitting them into unrelated replicas makes resource ownership harder. Then `pipe :record, count: 1`. Ordinary mutation outcomes travel on the normal track as typed data; the error pipe records unexpected exceptions and initiates run failure. Never rely on a default raising error handler to create durable outcomes.

Start the execution pipeline with `%{admission_capacity: 4}`. Keep at most four caller tasks in flight; runtime dispatch can lower effective concurrency to one. Replication count is declared in the DSL, so do not assume a start option changes it. Use supervised caller tasks with pipeline `call(..., :infinity)`: external commands and the run have enforced deadlines, while recording/cleanup must not be skipped by the default 5-second pipeline deadline. A caller timeout does not cancel FlowExtra work. A failed topology leaves the site's outcome uncertain until reconciled; do not automatically retry it. Definitive overload refusals remain pending. No task per site up front.

Layout under the service repo:

```text
temporary_subject/<run_id>/
  snapshot/                 pristine source; never a subprocess cwd
  prepared/                 dependency preparation; frozen before execution
  baseline/                 disposable copy used for clean tests
  workers/<site_id>/project/ fresh whole-tree copy per mutant
  scratch/<execution_id>/    private HOME/cache/temp/build paths
  logs/                     baseline and mutant logs
```

Copy the current working tree, including uncommitted source and necessary dotfiles; `git clone` would miss current edits and fail for non-Git subjects. Do not copy VCS metadata or original build caches (`.zig-cache`, `zig-out`, `_build`, `.build`, `.gradle`). Separate copy exclusions from mutation exclusions: tests and vendored dependencies may need copying even though they are never mutated.

Prepare dependencies once in service-owned storage and freeze the resulting inputs. Workers receive physical copies of dependency sources/checkouts as needed, but private compiled outputs. Keep the pristine source manifest separate from dependency preparation changes. Elixir workers may receive copied `deps`; Swift workers need prepared checkout/resolution inputs with automatic resolution disabled. Verify behavior against the installed toolchains. [SwiftPM test command options](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/SwiftTest.md).

Canonicalize paths. Reject service-internal source paths, destination nesting, escaping/cyclic symlinks, and external local path dependencies until deliberately supported. Materialize safe in-tree links as copies. No hardlinks or symlink overlays back to the original, snapshot, or another worker.

The service never runs a tool with cwd in the submitted directory. **Copies alone cannot prevent a test script from writing an absolute path back to the original.** `ProcessRunner` must restrict subprocess filesystem writes to its owned execution tree and propagate that restriction to descendants. The host has `/usr/bin/sandbox-exec`; qualify a narrow native profile in milestone 2. If write containment is unavailable or fails validation, refuse execution. This is an original-repository protection gate, not a claim of public multi-tenant security.

Reclaim worker trees only after their process groups are dead. Preserve logs/DB outcomes; automatically remove bulky completed snapshots after a configurable retention window (start at 24 hours). Bound log size and workspace disk usage, and stop admission when capacity is exhausted.

## 4. Defaults and traps

| Risk | Initial policy and decisive check |
| --- | --- |
| Original repository modification | Baseline and mutants run only on copies under a validated write restriction. Fixture commands attempting writes to the source are denied. HoneyBadger's full original manifest, including VCS/cache entries, is identical before and after qualification. |
| Cache staleness / test graph omissions | Private Zig local/global caches per execution; no original cache imports. A fixture mutation must alter the compiled behavior even with identical byte length. HoneyBadger `test` imports only the modules listed in `src/tests.zig`; framework and Amrita have separate targets. Retain `zig build test`, show that exact scope, and treat an unbuilt/unexercised function as a possible survivor. No coverage claim. |
| Compiler rejection inflating score | Separate invalid outcomes; qualify assertion failure, compiler failure, launch failure, and timeout classification independently. |
| Slow compilation / runaway processes | Preparation deadline 15 minutes; clean baseline deadline 10 minutes. Measure the baseline and a fresh worker control run. Mutant deadline `max(30 seconds, 10 × max(baseline, control))`, initially capped at 10 minutes. Allow an explicit override and reject a profile whose normal control cannot fit. Kill the full process group (TERM, 2-second grace, then KILL), including compiler/test children. |
| CPU/memory/port contention | One active run; two workers maximum; default one until its serial/parallel parity gate passes. Limit build-tool internal jobs too (Zig `-j1`; corresponding qualified Mix/Swift settings). Projects with shared external state remain serial. |
| Swift resolution / Mix rebuild cost | Resolve/download in preparation; use locked inputs, private build outputs, and cached dependency sources. Never use a no-compile option that could skip the mutated source. Initial qualification fixtures have no remote dependencies. |
| Toolchain / PATH / Kotlin absence | Resolve executables explicitly through mise/toolchain settings and record versions. No install/trust prompt in a worker. Kotlin checks its actual project toolchain, including JDK/Gradle needs; report unavailable explicitly. |
| Crash / cancellation / DB contention | Process ownership survives stage failures; coordinator and startup reconcile before reusing capacity. Idempotent outcome writes and synchronous DB tests. Full logs in files, bounded excerpts in SQLite. |
| No-coverage cost | Deterministic file filter/site selection, preview count, optional mutant limit, and an explicit overall run budget (default 30 minutes). Budget exhaustion is incomplete, never completed. Show counts for selected scope versus all scanned candidates. |

## 5. Milestones and acceptance gates

These are roughly half-day to two-day cards for a small pair; compiler/scanner qualification is the main sizing uncertainty. Each gate is independently reproduced by devin before the build lead lands it.

| Milestone | Build work | Acceptance gate / parallel validation |
| --- | --- | --- |
| **1 — Boot and contracts** | ZCode: pinned Phoenix app, SQLite schemas/context, FlowExtra dependency and a two-replica smoke pipeline. Write adapter/input/outcome contracts. | Boots on Elixir 1.20.4/OTP 28; migrations and persisted run history work; FlowExtra overload/completion behavior reproduced on OTP 28. Devin builds the small subject/outcome fixtures against the frozen contracts. |
| **2 — Safe execution** | ZCode: Workspaces and ProcessRunner; native write restriction, argv execution, private environment/caches, process-group shutdown. | Clean fixture baseline only on a copy; source-write attempts blocked; spaces in paths work; escaping link rejected; timeout/cancel kill grandchildren; no leaked workspaces. Devin injects slow/forking/failing commands. |
| **3 — Zig sites and one mutant** | ZCode: Zig adapter, token/expression/function scanner, deterministic patching, classification. | Fixture golden sites cover every enabled operator and negative syntax case; one patch per mutant; known killed/survived/invalid/timeout cases classified correctly; embedded test bodies excluded. Devin independently checks expected spans/diffs and compiler execution. |
| **4 — Durable parallel run and UI** | ZCode: coordinator, preparation/execution pipelines, Writer, LiveViews, cancellation, restart handling. | A known fixture set gives identical serial/two-worker outcomes; no more than two test processes/four admitted inputs; each selected site has one terminal row; repeated terminal delivery does not double-count; baseline failure dispatches none; cancel/restart leaves no running child and visible incomplete state. Devin owns crash/overload/duplicate-completion gates. |
| **5 — HoneyBadger qualification / Zig MVP** | ZCode: submit the specified original path; start with an explicitly selected function/file sample, then a declared bounded wider scope. | Pinned Zig 0.16.0 and `zig build test` baseline pass on a clone; site previews/diffs and outcome evidence are inspectable; score recomputes from SQLite; original manifest unchanged; no orphaned processes; measured time/disk/concurrency limits documented. A failing clone baseline blocks this gate and is reported without changing the original. Devin runs the independent reproduction. |
| **6 — Elixir and Swift extension** | ZCode: Elixir adapter; devin: Swift adapter in parallel. Add Kotlin detection/capability reporting. Reuse all execution/storage/UI contracts. | Each executable language passes its own killed/survived/invalid/timeout/scanner-negative fixture gates, including serial/parallel parity. Swift accepts SwiftPM and clearly declines Xcode-only projects. Kotlin reports unavailable without pretending to execute. Kotlin execution remains a later gate after its runtime/profile exists. |

M1 freezes the interfaces; execution containment (M2) and Zig scanning (M3) can then advance independently. M4 joins them. M5 is the first shipping decision. M6 can start after the interfaces stabilize but must not delay or weaken the Zig safety/behavior gates.

The demo is a submitted local path producing a reproducible report with a survivor diff, durable evidence, bounded execution, and an unchanged original. No target mutation score is an acceptance criterion; killed/survived decisions and accounting correctness are.

## Evidence and open assumptions

Local references inspected: the reference mutator README/runner/workers, FlowExtra pipeline/stage/admission tests, HoneyBadger `.mise.toml`, `build.zig`, and `src/tests.zig`. No HoneyBadger tests were run during this strategy pass and no subject files were modified. The supplied `_ETHOS.md` and `DIRECTORIES.md` paths do not exist on this host; the named contextual document was found in its current Google Drive storage location. This proposal uses the explicit build brief as authority and does not import unrelated project roadmaps.
