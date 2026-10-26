// Bounded async codeMUTATOR Mod. Native form (hooks.mjs register(on)), same
// shape as licorice's being-memory and the poopbags advisory Mod. No Node
// imports, provider calls or permission changes.
//
// Contract (licorice/docs/portfolio-plan.md, Mod contract):
//   - ASYNC ONLY. Runs are submitted explicitly via /codemutator-run (scoped,
//     bounded: <= 9 mutants, <= 120 s dispatch budget, one active run per
//     session+project). Stop boundaries poll once — never a minutes-long wait.
//   - Cancel via /codemutator-cancel verifies a terminal state; the service
//     drains in-flight work, the workspace removal is the cleanup receipt.
//   - Source is fingerprinted at submission (scoped contents + manifest bytes
//     + tool identity). A working tree that changed since submission produces
//     a STALE refusal — never promoted to current.
//   - Score = killed/(killed+survived); invalid/error/cancelled stay out of
//     the denominator and are shown as counts. Denominator 0 -> no score.
//   - Fail-open and bounded: <= 2000-byte notices, versioned evidence
//     envelopes on disk (schema: codemutator-mod/1).

const NOTICE_MAX = 2000;
const FILE_CAP = 512;
const TOTAL_CAP = 8 * 1024 * 1024;
const RESP_CAP = 256 * 1024;
const MAX_MUTANTS = 9;
const MAX_BUDGET_MS = 120_000;
const SCHEMA = "codemutator-mod/1";
const TOOL = "codemutator-mod@0.2.0";

const SRC_EXTS = /\.(ex|exs|zig|kt|kts|swift|rs)$/;
const MANIFESTS = new Set([
  "Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "rust-toolchain",
  "build.rs", ".cargo/config", ".cargo/config.toml",
  "build.zig", "build.zig.zon", "mix.exs", "mix.lock", "Package.swift",
  "Package.resolved", "settings.gradle", "settings.gradle.kts",
  "build.gradle", "build.gradle.kts", "gradle.properties", ".mise.toml",
]);
const SKIP_DIRS = new Set([
  ".git", "deps", "_build", "target", "node_modules", "vendor", "dist",
  "build", ".build", ".zig-cache", "zig-out", ".elixir_ls",
]);
const TERMINAL = new Set(["completed", "failed", "cancelled", "interrupted", "budget_exhausted"]);

async function config($) {
  const api = (await $.env.get("CODEMUTATOR_API")) || "http://127.0.0.1:4300";
  if (!/^https?:\/\/[^\s/]+[^\s]*$/.test(api)) throw new Error("CODEMUTATOR_API must be an http(s) URL");
  const home = await $.env.get("HOME");
  const state =
    (await $.env.get("CODEMUTATOR_MOD_STATE")) ||
    (home ? `${home}/.local/state/codemutator-mod` : null);
  if (!state || !state.startsWith("/")) throw new Error("no state dir: set CODEMUTATOR_MOD_STATE or HOME");
  const submitMs = Math.min(60_000, Math.max(250, Number(await $.env.get("CODEMUTATOR_SUBMIT_MS")) || 10_000));
  return { api: api.replace(/\/+$/, ""), state, submitMs };
}

async function canonicalRoot($, cwd) {
  try {
    const st = await $.fs.stat(cwd, { resolve: true });
    return st.realPath || cwd;
  } catch {
    return cwd;
  }
}

async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

// Snapshot identity: the scoped tree's contents plus the root manifest bytes —
// the things that change what a run would do.
async function fingerprint($, root, scope) {
  const base = scope ? `${root}/${scope.replace(/\/+$/, "")}` : root;
  const files = [];
  const stack = [""];
  let truncated = false;

  while (stack.length && files.length <= FILE_CAP) {
    const rel = stack.pop();
    let entries;
    try {
      entries = await $.fs.list(rel ? `${base}/${rel}` : base);
    } catch {
      return { error: `scope ${rel || "."} unreadable` };
    }
    for (const ent of entries) {
      const child = rel ? `${rel}/${ent.name}` : ent.name;
      if (ent.isLink) continue;
      if (ent.kind === "dir") {
        if (!SKIP_DIRS.has(ent.name)) stack.push(child);
      } else if (SRC_EXTS.test(ent.name)) {
        files.push(child);
      }
    }
  }
  files.sort();
  if (files.length > FILE_CAP) truncated = true;

  const parts = [`tool:${TOOL}`, `scope:${scope || "."}`];
  const errors = [];
  let bytes = 0;
  for (const rel of files.slice(0, FILE_CAP)) {
    let text;
    try {
      text = await $.fs.read(`${base}/${rel}`);
    } catch {
      parts.push(`${rel}:unreadable`);
      errors.push(`${rel} unreadable`);
      continue;
    }
    bytes += new TextEncoder().encode(text).length;
    if (bytes > TOTAL_CAP) { truncated = true; break; }
    parts.push(`${rel}:${await sha256(text)}`);
  }

  // Manifest bytes ride in the fingerprint (config digest) — including
  // .cargo/ config and build.rs, which the scoped workspace copy now carries.
  const manifestParts = [];
  for (const name of MANIFESTS) {
    try {
      manifestParts.push(`${name}:${await sha256(await $.fs.read(`${root}/${name}`))}`);
    } catch { /* absent */ }
  }

  return {
    digest: await sha256(parts.concat(manifestParts.sort()).join("\n")),
    files: files.length,
    bytes,
    truncated,
    errors,
    manifests: manifestParts.length,
  };
}

async function loadState($, cfg, rootKey) {
  try {
    return JSON.parse(await $.fs.read(`${cfg.state}/${rootKey}/state.json`));
  } catch {
    return { schema: SCHEMA, runs: {} };
  }
}

async function saveState($, cfg, rootKey, state) {
  await $.fs.write(`${cfg.state}/${rootKey}/state.json`, JSON.stringify(state, null, 2));
}

async function evidence($, cfg, rootKey, name, payload) {
  const path = `${cfg.state}/${rootKey}/${name}`;
  await $.fs.write(path, JSON.stringify({ schema: SCHEMA, ...payload }, null, 2));
  return path;
}

// The qualified SDK's $.http.fetch has no timeout option — each request races
// a bounded timer; a late response is abandoned, never awaited. Response text
// is capped before parse; an over-cap body is malformed, not trusted.
async function call($, cfg, method, path, body, timeoutMs = 10_000) {
  const request = $.http.fetch(`${cfg.api}${path}`, {
    method,
    headers: body ? { "content-type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  // The SDK has no abort: a timed-out request still completes server-side.
  // `late` resolves to the same normalized shape so a submission caller can
  // keep its one-run reservation and reconcile the late response later.
  const wrap = (r) => {
    const rawText = (r && r.text) || "";
    const over_cap = new TextEncoder().encode(rawText).length > RESP_CAP;
    let parsed = null;
    try { parsed = JSON.parse(over_cap ? "" : rawText); } catch { /* malformed */ }
    return { status: r.status, ok: r.ok && !over_cap, body: parsed, over_cap };
  };
  const late = request.then(wrap, (e) => ({ status: 0, ok: false, body: null, error: String(e) }));
  let timer;
  const res = await Promise.race([
    late.then((w) => ({ kind: "response", w })),
    new Promise((resolve) => { timer = setTimeout(() => resolve({ kind: "timeout" }), Math.max(1, timeoutMs)); }),
  ]);
  clearTimeout(timer);
  if (res.kind === "timeout") return { status: 0, ok: false, body: null, timed_out: true, late };
  if (res.w.error) throw new Error(res.w.error);
  return res.w;
}

// In-flight submission promises, keyed per session+project. Not persisted:
// on restart the reservation flag survives and releases after orphan_by.
const LATE = new Map();
const lateKey = (rootKey, session) => `${rootKey}${session}`;

// A POST whose outcome is unknown may have completed server-side. The run
// reservation holds until the late response reconciles (adopt or clear) or
// orphan_by passes — by then any landing run is terminal by budget bounds.
async function reconcileUncertain($, cfg, rootKey, state, session) {
  const u = state.uncertain_submit;
  if (!u) return null;
  const late = LATE.get(lateKey(rootKey, session));
  const settled = late ? await Promise.race([late, Promise.resolve("pending")]) : "lost";
  if (settled !== "pending" && settled !== "lost") {
    LATE.delete(lateKey(rootKey, session));
    delete state.uncertain_submit;
    if (settled.ok && settled.body && Number.isInteger(settled.body.id)) {
      const runId = String(settled.body.id);
      state.runs[runId] = {
        session, root: u.root, scope: u.scope,
        source_digest: u.source_digest, config_digest: u.config_digest,
        submitted_at: u.at, mutant_limit: u.mutant_limit, budget_ms: u.budget_ms,
      };
      await saveState($, cfg, rootKey, state);
      return { adopted: runId };
    }
    await saveState($, cfg, rootKey, state);
    return { lost: `submission failed server-side (http ${settled.status}${settled.error ? `, ${settled.error.slice(0, 120)}` : ""})` };
  }
  // The promise is still in flight or was lost at restart. No list endpoint
  // exists to read back by client_ref, so without the live promise the
  // outcome is unverifiable — stay unknown, hold the slot, operator resolves.
  if (settled === "lost" && !u.unresolvable) {
    u.unresolvable = Date.now();
    await evidence($, cfg, rootKey, "submit-unresolvable.json", { ts: Date.now(), session, client_ref: u.client_ref, note: "in-flight promise lost (restart); cannot verify whether the POST landed" });
    await saveState($, cfg, rootKey, state);
  }
  return { waiting: true, unresolvable: settled === "lost" };
}

// Cut at a UTF-8 codepoint boundary with the suffix reserved inside the cap —
// every notice path stays <= NOTICE_MAX bytes total.
function fit(text) {
  const bytes = new TextEncoder().encode(text);
  if (bytes.length <= NOTICE_MAX) return text;
  const suffix = new TextEncoder().encode("…");
  let end = NOTICE_MAX - suffix.length;
  while (end > 0 && (bytes[end] & 0xC0) === 0x80) end--;
  return new TextDecoder().decode(bytes.slice(0, end)) + "…";
}

function scoreLine(run, outcomeCounts) {
  const k = outcomeCounts.killed || 0;
  const s = outcomeCounts.survived || 0;
  const denom = k + s;
  const score = denom === 0 ? "no score (0 scored mutants)" : `score ${k}/${denom} = ${(k / denom).toFixed(3)}`;
  const rest = ["invalid", "error", "cancelled"].map((k2) => `${k2} ${outcomeCounts[k2] || 0}`).join(", ");
  return `${score}; excluded: ${rest}`;
}

function countOutcomes(outcomes) {
  const counts = {};
  for (const o of outcomes || []) {
    const st = o.status === "killed" ? "killed" : o.status;
    counts[st] = (counts[st] || 0) + 1;
  }
  return counts;
}

async function reportRun($, cfg, rootKey, state, session, runId) {
  const rec = state.runs[runId];
  const show = await call($, cfg, "GET", `/api/runs/${runId}`);
  if (!show.ok || !show.body) return { notice: `codemutator: unknown — run #${runId} status unreadable (http ${show.status}).` };

  const run = show.body;
  if (!run.terminal) {
    return { notice: `codemutator: run #${runId} ${run.state} — still running; reports at the next boundary. Never blocks.` };
  }

  // Terminal: the outcome response must be a real, readable outcome list —
  // an HTTP error, timeout or malformed body means there is no suite verdict
  // to promote, whatever the run state says.
  const out = await call($, cfg, "GET", `/api/runs/${runId}/outcomes`);
  const outcomes = out.ok && out.body && Array.isArray(out.body.outcomes) ? out.body.outcomes : null;
  const fpNow = await fingerprint($, rec.root, rec.scope);
  const stale = fpNow.digest !== rec.source_digest;
  const kind =
    run.state === "completed" ? "completed"
    : run.state === "cancelled" ? "cancelled"
    : "aborted"; // failed / interrupted / budget_exhausted — infrastructure, not a suite verdict

  const counts = outcomes ? countOutcomes(outcomes) : null;
  const score = counts && (counts.killed || 0) + (counts.survived || 0) > 0 ? (counts.killed || 0) / ((counts.killed || 0) + (counts.survived || 0)) : null;
  const envelope = {
    ts: Date.now(),
    root: rec.root,
    scope: rec.scope,
    session,
    run_id: runId,
    state: run.state,
    submitted_at: rec.submitted_at,
    terminal_at: run.finished_at || null,
    source_digest: rec.source_digest,
    digest_at_report: fpNow.digest,
    stale,
    config_digest: rec.config_digest,
    tool: TOOL,
    api: cfg.api,
    counts,
    score,
    mutant_limit: rec.mutant_limit,
  };
  const path = await evidence($, cfg, rootKey, `run-${runId}.json`, envelope);
  delete state.runs[runId];
  await saveState($, cfg, rootKey, state);

  if (stale) {
    return { notice: fit(`codemutator: stale — run #${runId} ended ${run.state}, but the working tree changed since submission; refusing to promote it.\nevidence: ${path}\nsource unchanged by the service itself; resubmit for a current verdict.`) };
  }

  if (outcomes === null) {
    return { notice: fit(`codemutator: unreadable — run #${runId} ended ${run.state}, but its outcome list was unreadable (http ${out.status}${out.timed_out ? " timed out" : ""}${out.over_cap ? " over-cap" : ""}); no suite verdict promoted.\nevidence: ${path}`) };
  }

  const scoreText = scoreLine(run, counts);
  const head =
    kind === "completed"
      ? `codemutator: run #${runId} completed — ${scoreText}.`
      : kind === "cancelled"
        ? `codemutator: run #${runId} cancelled — terminal confirmed on a fresh read; workspace cleanup is service-side and not verified by this Mod. ${scoreText}.`
        : `codemutator: run #${runId} ended ${run.state} — infrastructure, not a suite verdict. ${scoreText}.`;
  return { notice: fit(`${head}\ninvalid/error/cancelled never enter the denominator.\nevidence: ${path}`) };
}

async function cmdRun($, cfg, args, session) {
  const root = await canonicalRoot($, (await $.env.get("PWD")) || ".");
  const rootKey = await sha256(root);
  const scope = (args[0] || "src").replace(/^\/+|\/+$/g, "");
  const mutantLimit = Math.min(MAX_MUTANTS, Math.max(1, Number(args[1]) || MAX_MUTANTS));
  const budget = Math.min(MAX_BUDGET_MS, Math.max(1_000, Number(args[2]) || MAX_BUDGET_MS));

  const state = await loadState($, cfg, rootKey);
  const recon = await reconcileUncertain($, cfg, rootKey, state, session);
  if (recon && recon.waiting) {
    return { text: `codemutator: a previous submission's outcome is still unknown — the request may have completed server-side. Reservation retained; refusing to submit a second run. Rechecks at the next boundary or /codemutator-status.` };
  }
  const active = Object.keys(state.runs).find((id) => state.runs[id].session === session);
  if (active) {
    return { text: `codemutator: run #${active} is already active for this session+project — one active run. /codemutator-status or /codemutator-cancel ${active} first.` };
  }

  const fp = await fingerprint($, root, scope);
  if (fp.error) return { text: `codemutator: unknown — ${fp.error}; nothing submitted.` };
  if (fp.truncated) return { text: `codemutator: unknown — scope exceeds fingerprint bounds (${fp.files} files/${fp.bytes}B); nothing submitted.` };

  // Reserve the one-run slot BEFORE the POST: a restart or repeat command
  // during the flight window cannot create a second submission.
  const configDigest = await sha256(`${fp.manifests}`);
  const uncertain = {
    at: Date.now(), client_ref: `codemutator-mod:${session}:${Date.now()}`,
    root, scope, source_digest: fp.digest, config_digest: configDigest,
    mutant_limit: mutantLimit, budget_ms: budget,
  };
  state.uncertain_submit = uncertain;
  await saveState($, cfg, rootKey, state);
  const res = await call($, cfg, "POST", "/api/runs", {
    source_path: root,
    scope_filter: `${scope}/`,
    mutant_limit: mutantLimit,
    run_budget_ms: budget,
  }, cfg.submitMs).catch((e) => ({ transport_error: true, error: String(e) }));
  if (res.timed_out) {
    // Unknown delivery: keep the reservation and the late promise; reconcile
    // at later boundaries, never resubmit, never infer cancellation.
    LATE.set(lateKey(rootKey, session), res.late);
    await saveState($, cfg, rootKey, state);
    const path = await evidence($, cfg, rootKey, "submit-uncertain.json", { ts: Date.now(), root, scope, session, client_ref: uncertain.client_ref, source_digest: fp.digest });
    return { text: `codemutator: submission timed out — outcome unknown; the request may still complete server-side. Reservation retained; reconciles at the next boundary. Do not resubmit.\nevidence: ${path}` };
  }
  if (res.transport_error || !res.ok || !res.body || !Number.isInteger(res.body.id)) {
    // A transport error before a response is safe: nothing was accepted.
    // An HTTP rejection means the server refused — either way the slot frees.
    delete state.uncertain_submit;
    await saveState($, cfg, rootKey, state);
    const path = await evidence($, cfg, rootKey, "last-submit-failure.json", { ts: Date.now(), root, scope, session, http: res.status, error: res.error || null });
    if (res.transport_error) throw new Error(res.error);
    return { text: `codemutator: submit rejected (http ${res.status}); evidence: ${path}` };
  }
  delete state.uncertain_submit;

  const runId = res.body.id;
  state.runs[String(runId)] = {
    session,
    root,
    scope,
    source_digest: fp.digest,
    config_digest: await sha256(`${fp.manifests}`),
    submitted_at: Date.now(),
    mutant_limit: mutantLimit,
    budget_ms: budget,
  };
  await saveState($, cfg, rootKey, state);
  const path = await evidence($, cfg, rootKey, `submit-${runId}.json`, { ts: Date.now(), root, scope, session, run_id: runId, source_digest: fp.digest, files: fp.files, bytes: fp.bytes, mutant_limit: mutantLimit, budget_ms: budget });
  return { text: `codemutator: run #${runId} submitted — ${scope}/ scope, ${fp.files} files fingerprinted, mutant limit ${mutantLimit}, budget ${budget}ms. Async: reports at the next boundary; /codemutator-status, /codemutator-cancel ${runId}.\nevidence: ${path}` };
}

async function cmdCancel($, cfg, args, session) {
  const root = await canonicalRoot($, (await $.env.get("PWD")) || ".");
  const rootKey = await sha256(root);
  const state = await loadState($, cfg, rootKey);
  const id = args[0];
  if (!id || !state.runs[id]) return { text: `codemutator: no such pending run ${id || "(none)"} for this project.` };

  const res = await call($, cfg, "POST", `/api/runs/${id}/cancel`);
  if (!res.ok && res.status !== 200) {
    return { text: `codemutator: cancel of run #${id} rejected (http ${res.status}).` };
  }
  // Verify a terminal state rather than trusting the cancel POST.
  const show = await call($, cfg, "GET", `/api/runs/${id}`);
  const terminal = show.ok && show.body && (show.body.terminal === true || TERMINAL.has(show.body.state));
  const path = await evidence($, cfg, rootKey, `cancel-${id}.json`, { ts: Date.now(), root, session, run_id: Number(id), terminal, state: show.body && show.body.state });
  if (!terminal) {
    return { text: `codemutator: cancel sent for run #${id} but terminal state not yet confirmed (${show.body && show.body.state}); it resolves at the next boundary.\nevidence: ${path}` };
  }
  delete state.runs[id];
  await saveState($, cfg, rootKey, state);
  return { text: `codemutator: run #${id} ${show.body.state} — terminal confirmed on a fresh read. Workspace cleanup is service-side and not verified by this Mod; a terminal flag is not cleanup proof.\nevidence: ${path}` };
}

async function cmdStatus($, cfg, session) {
  const root = await canonicalRoot($, (await $.env.get("PWD")) || ".");
  const rootKey = await sha256(root);
  const state = await loadState($, cfg, rootKey);
  await reconcileUncertain($, cfg, rootKey, state, session);
  const mine = Object.entries(state.runs).filter(([, r]) => r.session === session);
  const lines = [];
  if (state.uncertain_submit) {
    const u = state.uncertain_submit;
    lines.push(`a submission's outcome is unknown (submitted ${new Date(u.at).toISOString()}, ref ${u.client_ref}) — reservation retained${u.unresolvable ? "; unresolvable without the in-flight promise: verify on the service, then /codemutator-resolve <run_id> or /codemutator-resolve none" : "; reconciles when the response lands"}`);
  }
  if (!mine.length) {
    return { text: lines.length ? `codemutator:\n${lines.join("\n")}` : "codemutator: no pending runs for this session+project." };
  }
  for (const [id, rec] of mine) {
    const show = await call($, cfg, "GET", `/api/runs/${id}`);
    const st = show.ok && show.body ? `${show.body.state}${show.body.terminal ? " (terminal)" : ""}` : `unreadable (http ${show.status})`;
    lines.push(`run #${id} — ${st}; scope ${rec.scope}/; limit ${rec.mutant_limit}; submitted ${new Date(rec.submitted_at).toISOString()}`);
  }
  return { text: `codemutator:\n${lines.join("\n")}` };
}

export function register(on) {
  on("session.start", async ($, e, next) => {
    await $.command.register({ name: "codemutator-run", description: "Submit a bounded scoped mutation run (async): /codemutator-run [scope] [mutants<=9] [budget<=120000ms]" });
    await $.command.register({ name: "codemutator-status", description: "Show pending mutation runs for this session+project" });
    await $.command.register({ name: "codemutator-resolve", description: "Resolve an uncertain submission after checking the service: /codemutator-resolve <run_id> to adopt, or 'none'" });
    await $.command.register({ name: "codemutator-cancel", description: "Cancel a pending run and verify its terminal state: /codemutator-cancel <id>" });
    await $.command.register({ name: "codemutator", description: "codeMUTATOR async status summary" });
    return next(e);
  });

  on("command.run", { command: "codemutator-run" }, async ($, e) => {
    try {
      const cfg = await config($);
      const session = await $.session.id();
      const args = String((e && e.args) || "").split(/\s+/).filter(Boolean);
      return await cmdRun($, cfg, args, session);
    } catch (err) {
      return { text: `codemutator: unknown — ${String((err && err.message) || err).slice(0, 300)}. Nothing submitted; never blocks.` };
    }
  });

  // Operator resolution for an unverifiable uncertain submission: adopt a
  // run id found on the service, or clear after verifying nothing landed.
  on("command.run", { command: "codemutator-resolve" }, async ($, e) => {
    try {
      const cfg = await config($);
      const session = await $.session.id();
      const root = await canonicalRoot($, (await $.env.get("PWD")) || ".");
      const rootKey = await sha256(root);
      const state = await loadState($, cfg, rootKey);
      const u = state.uncertain_submit;
      if (!u) return { text: "codemutator: no uncertain submission for this session+project." };
      const arg = String((e && e.args) || "").trim();
      if (arg === "none") {
        delete state.uncertain_submit;
        await saveState($, cfg, rootKey, state);
        const path = await evidence($, cfg, rootKey, "resolve-none.json", { ts: Date.now(), session, client_ref: u.client_ref, note: "operator verified no run landed" });
        return { text: `codemutator: reservation cleared by operator (ref ${u.client_ref}).\nevidence: ${path}` };
      }
      if (!/^\d+$/.test(arg)) return { text: "codemutator: usage — /codemutator-resolve <run_id> or /codemutator-resolve none" };
      const show = await call($, cfg, "GET", `/api/runs/${arg}`);
      if (!show.ok || !show.body || show.body.id !== Number(arg)) {
        return { text: `codemutator: run #${arg} not readable on the service (http ${show.status}); reservation kept.` };
      }
      state.runs[arg] = {
        session, root: u.root, scope: u.scope,
        source_digest: u.source_digest, config_digest: u.config_digest,
        submitted_at: u.at, mutant_limit: u.mutant_limit, budget_ms: u.budget_ms,
        operator_adopted: true,
      };
      delete state.uncertain_submit;
      await saveState($, cfg, rootKey, state);
      const path = await evidence($, cfg, rootKey, `resolve-adopt-${arg}.json`, { ts: Date.now(), session, run_id: Number(arg), client_ref: u.client_ref, run_state: show.body.state });
      return { text: `codemutator: run #${arg} adopted by operator (ref ${u.client_ref}); reports at the next boundary.\nevidence: ${path}` };
    } catch (err) {
      return { text: `codemutator: unknown — ${String((err && err.message) || err).slice(0, 300)}.` };
    }
  });

  on("command.run", { command: "codemutator-cancel" }, async ($, e) => {
    try {
      const cfg = await config($);
      const session = await $.session.id();
      const args = String((e && e.args) || "").split(/\s+/).filter(Boolean);
      return await cmdCancel($, cfg, args, session);
    } catch (err) {
      return { text: `codemutator: unknown — ${String((err && err.message) || err).slice(0, 300)}.` };
    }
  });

  on("command.run", { command: "codemutator-status" }, async ($) => {
    try {
      const cfg = await config($);
      return await cmdStatus($, cfg, await $.session.id());
    } catch (err) {
      return { text: `codemutator: unknown — ${String((err && err.message) || err).slice(0, 300)}.` };
    }
  });

  on("command.run", { command: "codemutator" }, async ($) => {
    try {
      const cfg = await config($);
      return await cmdStatus($, cfg, await $.session.id());
    } catch (err) {
      return { text: `codemutator: unknown — ${String((err && err.message) || err).slice(0, 300)}.` };
    }
  });

  // Async boundary: one status read per pending run — never a wait.
  on("classic.Stop", async ($, e, next) => {
    const result = await next(e);
    let notice = null;
    try {
      const cfg = await config($);
      const session = await $.session.id();
      const root = await canonicalRoot($, e.cwd);
      const rootKey = await sha256(root);
      const state = await loadState($, cfg, rootKey);
      const recon = await reconcileUncertain($, cfg, rootKey, state, session);
      if (recon && recon.waiting) {
        notice = fit(`codemutator: unknown — a previous submission's outcome is still unresolved; reservation retained; no second run can be submitted.`);
      } else {
        if (recon && recon.adopted) {
          const path = await evidence($, cfg, rootKey, `adopted-${recon.adopted}.json`, { ts: Date.now(), session, run_id: recon.adopted, note: "late POST response reconciled; run adopted as this session's reservation" });
          notice = fit(`codemutator: late response reconciled — run #${recon.adopted} landed server-side and is now tracked.\nevidence: ${path}`);
        }
        const mine = Object.keys(state.runs).filter((id) => state.runs[id].session === session);
        if (mine.length) {
          const rep = await reportRun($, cfg, rootKey, state, session, mine[0]);
          notice = rep.notice;
        }
      }
    } catch (err) {
      notice = fit(`codemutator: unknown — ${String((err && err.message) || err).slice(0, 300)}. never blocks.`);
    }
    if (notice) {
      const ctx = (result && result.additionalContext) || [];
      return { ...(result || {}), additionalContext: [...ctx, notice] };
    }
    return result;
  });
}
