import assert from "node:assert/strict";
import { test } from "node:test";

import { register } from "../hooks/register.mjs";

// Contract-control simulation for the bounded async codemutator Mod. The mock
// $ mirrors the engine surface used by register.mjs; receipts record a
// synthetic run, never a real service.

function makeHost({
  session = "sess-1",
  fs = {},
  cwd = "/proj",
  service = {},
  env = {},
} = {}) {
  const listeners = [];
  const fetchCalls = [];

  const virtualFs = { ...fs };
  const host = {
    on: (name, opts, fn) => listeners.push({ name, opts, fn: fn || opts }),
    $: {
      env: {
        get: async (k) =>
          ({ CODEMUTATOR_API: "http://127.0.0.1:4300", CODEMUTATOR_MOD_STATE: "/state", PWD: cwd, HOME: "/home", ...env })[k] ?? null,
      },
      session: { id: async () => session },
      command: { register: async () => {} },
      http: {
        fetch: async (url, init) => {
          fetchCalls.push(`${init?.method || "GET"} ${url}`);
          const u = new URL(url);
          const m = init?.method || "GET";
          if (u.pathname === "/api/runs" && m === "POST") {
            if (service.hangSubmit && !host._hangUsed) { host._hangUsed = true; return service.hangSubmit.then(svc); }
            return svc(service.submit || { status: 201, body: { id: 1, state: "queued", terminal: false } });
          }
          const mo = u.pathname.match(/^\/api\/runs\/(\d+)$/);
          if (mo && m === "GET") return svc(service.status || { status: 200, body: { id: 1, state: "running", terminal: false } });
          const oc = u.pathname.match(/^\/api\/runs\/(\d+)\/outcomes$/);
          if (oc) return svc(service.outcomes || { status: 200, body: { run_id: 1, state: "completed", score: 0.75, outcomes: [] } });
          const ca = u.pathname.match(/^\/api\/runs\/(\d+)\/cancel$/);
          if (ca) return svc(service.cancel || { status: 200, body: { id: 1, state: "cancelled", terminal: true } });
          return svc({ status: 404, body: { error: "not_found" } });
        },
      },
      fs: {
        stat: async (p) => ({ kind: p === cwd || p.endsWith("src") ? "dir" : "file", realPath: p, isLink: false, size: 1, mtimeMs: 0 }),
        list: async (p) => {
          const prefix = `${p}/`;
          const seen = new Map();
          for (const k of Object.keys(virtualFs)) {
            if (!k.startsWith(prefix)) continue;
            const rest = k.slice(prefix.length);
            const head = rest.split("/")[0];
            if (!seen.has(head)) seen.set(head, { name: head, kind: rest.includes("/") ? "dir" : "file", size: 4, mtimeMs: 0, isLink: false });
          }
          return [...seen.values()];
        },
        read: async (p) => {
          if (p in virtualFs) return virtualFs[p];
          throw new Error(`ENOENT ${p}`);
        },
        write: async (p, text) => { virtualFs[p] = text; },
        exists: async (p) => p in virtualFs,
      },
      ui: { log: async () => {} },
    },
    run: (name, e) => {
      const L = listeners.filter((l) => l.name === name && (!l.opts?.command || l.opts.command === e?.command));
      let next = async (ev) => ({ ...ev });
      for (let i = L.length - 1; i >= 0; i--) {
        const fn = L[i].fn; const nx = next;
        next = async (ev) => fn(host.$, ev, nx);
      }
      return next(e);
    },
    fsDump: () => virtualFs,
    fetchCalls,
  };
  return host;
}

function svc(res) {
  return { status: res.status, ok: res.status >= 200 && res.status < 300, headers: {}, text: JSON.stringify(res.body ?? {}) };
}

const SRC = { "/proj/src/lib.rs": "pub fn add(a:i32,b:i32)->i32{a+b}\n", "/proj/Cargo.toml": "[package]\nname='x'\n" };

test("submit → running poll → completed terminal with score", async () => {
  const terminal = { id: 1, state: "completed", terminal: true };
  let polls = 0;
  const host = makeHost({
    fs: SRC,
    service: {
      submit: { status: 201, body: { id: 42, state: "queued", terminal: false } },
      outcomes: { status: 200, body: { run_id: 42, state: "completed", score: 0.75, outcomes: [
        { site_id: 1, file: "src/lib.rs", line: 1, function: "add", operator: "ArithmeticSwap", original: "+", replacement: "-", status: "killed", reason: "assertion" },
        { site_id: 2, file: "src/lib.rs", line: 1, function: "add", operator: "LiteralFlip", original: "0", replacement: "1", status: "survived", reason: "all_tests_passed" },
        { site_id: 3, file: "src/lib.rs", line: 1, function: "add", operator: "UnaryRemove", original: "!", replacement: "", status: "invalid", reason: "compile_error" },
        { site_id: 4, file: "src/lib.rs", line: 1, function: "add", operator: "LiteralFlip", original: "1", replacement: "0", status: "killed", reason: "assertion" },
      ] } },
    },
  });
  register(host.on);
  await host.run("session.start", {});

  // Submit
  let calls = 0;
  const sub = await host.run("command.run", { command: "codemutator-run", args: "src 4" });
  assert.match(sub.text, /run #42 submitted/);
  assert.match(sub.text, /mutant limit 4/);

  // Boundary while running → running notice, one GET only.
  const svcModule = host.$.http;
  const origFetch = svcModule.fetch;
  svcModule.fetch = async (url, init) => {
    calls++;
    if (/\/api\/runs\/42$/.test(url)) return svc({ status: 200, body: calls === 1 ? { id: 42, state: "running", terminal: false } : terminal });
    return origFetch(url, init);
  };
  const stop1 = await host.run("classic.Stop", { cwd: "/proj", hook_event_name: "Stop", stop_hook_active: false });
  assert.match((stop1.additionalContext || []).join(""), /still running/);

  // Next boundary → terminal with score + evidence envelope.
  const stop2 = await host.run("classic.Stop", { cwd: "/proj", hook_event_name: "Stop", stop_hook_active: false });
  const notice = (stop2.additionalContext || []).join("");
  assert.match(notice, /completed/);
  assert.match(notice, /score 2\/3/);          // killed 2 / (killed 2 + survived 1)
  assert.match(notice, /invalid 1/);            // excluded from denominator
  const envKey = Object.keys(host.fsDump()).find((k) => k.endsWith("/run-42.json"));
  assert.ok(envKey, "run-42 evidence envelope written");
  const env = JSON.parse(host.fsDump()[envKey]);
  assert.equal(env.schema, "codemutator-mod/1");
  assert.equal(env.state, "completed");
  assert.equal(env.counts.killed, 2);
  assert.equal(env.counts.survived, 1);
  assert.equal(env.stale, false);
});

test("stale source → refusal, not promotion", async () => {
  const fs = { ...SRC };
  const host = makeHost({
    fs,
    service: {
      submit: { status: 201, body: { id: 7, state: "queued", terminal: false } },
      status: { status: 200, body: { id: 7, state: "completed", terminal: true } },
      outcomes: { status: 200, body: { run_id: 7, state: "completed", outcomes: [{ site_id: 1, status: "killed", reason: "assertion" }] } },
    },
  });
  register(host.on);
  await host.run("session.start", {});
  await host.run("command.run", { command: "codemutator-run", args: "src" });
  host.fsDump()["/proj/src/lib.rs"] += "// edited after submit\n";
  const stop = await host.run("classic.Stop", { cwd: "/proj", hook_event_name: "Stop", stop_hook_active: false });
  const notice = (stop.additionalContext || []).join("");
  assert.match(notice, /stale/);
  assert.match(notice, /refusing to promote/);
});

test("one active run: second submit refused while pending", async () => {
  const host = makeHost({ fs: SRC, service: { submit: { status: 201, body: { id: 9, state: "queued", terminal: false } } } });
  register(host.on);
  await host.run("session.start", {});
  await host.run("command.run", { command: "codemutator-run", args: "src" });
  const again = await host.run("command.run", { command: "codemutator-run", args: "src" });
  assert.match(again.text, /already active/);
  assert.match(again.text, /one active run/);
});

test("cancel verifies terminal and clears the run", async () => {
  const host = makeHost({
    fs: SRC,
    service: {
      submit: { status: 201, body: { id: 11, state: "queued", terminal: false } },
      cancel: { status: 200, body: { id: 11, state: "cancelled", terminal: true } },
      status: { status: 200, body: { id: 11, state: "cancelled", terminal: true } },
    },
  });
  register(host.on);
  await host.run("session.start", {});
  await host.run("command.run", { command: "codemutator-run", args: "src" });
  const res = await host.run("command.run", { command: "codemutator-cancel", args: "11" });
  assert.match(res.text, /terminal confirmed/);
  // Subsequent boundary has nothing pending → no additionalContext.
  const stop = await host.run("classic.Stop", { cwd: "/proj", hook_event_name: "Stop", stop_hook_active: false });
  assert.deepEqual(stop.additionalContext || [], []);
});

test("unreadable outcomes (http 500) refuses the suite verdict", async () => {
  const host = makeHost({
    fs: SRC,
    service: {
      submit: { status: 201, body: { id: 21, state: "queued", terminal: false } },
      status: { status: 200, body: { id: 21, state: "completed", terminal: true } },
      // A 500 body that still carries outcome-shaped JSON — the Mod must
      // check ok, not just the body's shape.
      outcomes: { status: 500, body: { run_id: 21, state: "completed", outcomes: [{ site_id: 1, status: "killed", reason: "assertion" }] } },
    },
  });
  register(host.on);
  await host.run("session.start", {});
  await host.run("command.run", { command: "codemutator-run", args: "src" });
  const stop = await host.run("classic.Stop", { cwd: "/proj", hook_event_name: "Stop", stop_hook_active: false });
  const notice = (stop.additionalContext || []).join("");
  assert.match(notice, /unreadable/);
  assert.doesNotMatch(notice, /score/);
});

test("budget_exhausted and interrupted keep their real state — never 'completed'", async () => {
  for (const term of ["budget_exhausted", "interrupted", "failed"]) {
    const host = makeHost({
      fs: SRC,
      service: {
        submit: { status: 201, body: { id: 30, state: "queued", terminal: false } },
        status: { status: 200, body: { id: 30, state: term, terminal: true } },
        outcomes: { status: 200, body: { run_id: 30, state: term, outcomes: [{ site_id: 1, status: "killed", reason: "assertion" }] } },
      },
    });
    register(host.on);
    await host.run("session.start", {});
    await host.run("command.run", { command: "codemutator-run", args: "src" });
    const stop = await host.run("classic.Stop", { cwd: "/proj", hook_event_name: "Stop", stop_hook_active: false });
    const notice = (stop.additionalContext || []).join("");
    assert.match(notice, new RegExp(`ended ${term}`), term);
    assert.doesNotMatch(notice, /completed/);
    assert.match(notice, /not a suite verdict/);
  }
});

test("cancel race: the Mod reports the fresh state, not the cancel POST's claim", async () => {
  // The service accepted the cancel, then the run crashed — the verify read
  // reports the truth (failed), and that is what the user sees.
  const host = makeHost({
    fs: SRC,
    service: {
      submit: { status: 201, body: { id: 40, state: "queued", terminal: false } },
      cancel: { status: 200, body: { id: 40, state: "cancelled", terminal: true } },
      status: { status: 200, body: { id: 40, state: "failed", terminal: true, failure_reason: "{:crash, lane}" } },
    },
  });
  register(host.on);
  await host.run("session.start", {});
  await host.run("command.run", { command: "codemutator-run", args: "src" });
  const res = await host.run("command.run", { command: "codemutator-cancel", args: "40" });
  assert.match(res.text, /run #40 failed/);
  assert.doesNotMatch(res.text, /cancelled/);
  assert.match(res.text, /not cleanup proof|not verified by this Mod/);
});

test("notice stays under 2000 UTF-8 bytes on every path", async () => {
  const mod = await import("data:text/javascript;base64," + Buffer.from(
    (await import("node:fs")).readFileSync(new URL("../hooks/register.mjs", import.meta.url), "utf8") +
    "\nexport {fit};"
  ).toString("base64"));
  const over = mod.fit("x".repeat(2400));
  assert.ok(Buffer.byteLength(over) <= 2000, `fit -> ${Buffer.byteLength(over)}B`);
  const unicode = mod.fit("🦀".repeat(1200));
  assert.ok(Buffer.byteLength(unicode) <= 2000, `unicode fit -> ${Buffer.byteLength(unicode)}B`);
});

test("service down: submit answers unknown; a pending run fails open at the boundary", async () => {
  const host = makeHost({ fs: SRC, service: { submit: { status: 201, body: { id: 5, state: "queued", terminal: false } } } });
  register(host.on);
  await host.run("session.start", {});
  // Service down at submit → unknown, nothing submitted.
  const origFetch = host.$.http.fetch;
  host.$.http.fetch = async () => { throw new Error("connection refused"); };
  const res = await host.run("command.run", { command: "codemutator-run", args: "src" });
  assert.match(res.text, /unknown/);
  // Submit with service up → pending run; then the service dies → the
  // boundary poll throws → fail-open "unknown", stop result preserved.
  host.$.http.fetch = origFetch;
  await host.run("command.run", { command: "codemutator-run", args: "src" });
  host.$.http.fetch = async () => { throw new Error("connection refused"); };
  const stop = await host.run("classic.Stop", { cwd: "/proj", hook_event_name: "Stop", stop_hook_active: false });
  const notice = (stop.additionalContext || []).join("");
  assert.match(notice, /unknown/);
  assert.match(notice, /never blocks/);
});

test("uncertain submission retains reservation; late response reconciles and adopts the run", async () => {
  let resolvePost;
  const gate = new Promise((r) => (resolvePost = r));
  const host = makeHost({
    env: { CODEMUTATOR_SUBMIT_MS: "20" },
    fs: SRC,
    service: {
      hangSubmit: gate.then(() => ({ status: 201, body: { id: 77, state: "queued", terminal: false } })),
      status: { status: 200, body: { id: 77, state: "completed", terminal: true } },
      outcomes: { status: 200, body: { run_id: 77, state: "completed", score: 1, outcomes: [] } },
    },
  });
  register(host.on);
  const r1 = await host.run("command.run", { command: "codemutator-run", args: "src 4 120000" });
  assert.match(r1.text, /timed out|outcome unknown|reservation retained/);
  // Reservation retained: a second submit is refused without a second POST.
  const r2 = await host.run("command.run", { command: "codemutator-run", args: "src 4 120000" });
  assert.match(r2.text, /outcome is still unknown|reservation/);
  assert.equal(host.fetchCalls.filter((c) => c.startsWith("POST")).length, 1);
  // The late POST resolves with a landed run — the next boundary adopts it.
  resolvePost();
  const stop = await host.run("classic.Stop", { cwd: "/proj", hook_event_name: "Stop", stop_hook_active: false });
  const notice = (stop.additionalContext || []).join("");
  assert.match(notice, /#77/);
});

test("uncertain submission that failed server-side clears the reservation", async () => {
  let resolvePost;
  const gate = new Promise((r) => (resolvePost = r));
  const host = makeHost({
    env: { CODEMUTATOR_SUBMIT_MS: "20" },
    fs: SRC,
    service: {
      hangSubmit: gate.then(() => ({ status: 500, body: { error: "boom" } })),
      submit: { status: 201, body: { id: 88, state: "queued", terminal: false } },
    },
  });
  register(host.on);
  await host.run("command.run", { command: "codemutator-run", args: "src 4 120000" });
  resolvePost();
  await new Promise((r) => setTimeout(r, 5));
  // Reservation cleared by the failed late response — a new submit succeeds.
  const r = await host.run("command.run", { command: "codemutator-run", args: "src 4 120000" });
  assert.match(r.text, /run #88 submitted/);
});

test("a response over 256KiB bytes is over-cap, never a suite verdict", async () => {
  const host = makeHost({
    fs: SRC,
    service: {
      submit: { status: 201, body: { id: 90, state: "queued", terminal: false } },
      status: { status: 200, body: { id: 90, state: "completed", terminal: true } },
      outcomes: { status: 200, body: { run_id: 90, state: "completed", pad: "é".repeat(140_000) } },
    },
  });
  register(host.on);
  await host.run("command.run", { command: "codemutator-run", args: "src" });
  const stop = await host.run("classic.Stop", { cwd: "/proj", hook_event_name: "Stop", stop_hook_active: false });
  const notice = (stop.additionalContext || []).join("");
  assert.match(notice, /unreadable|over-cap/);
  assert.doesNotMatch(notice, /score/);
});

test("restart with unresolvable uncertain submission: stays unknown, refuses resubmit, operator resolve clears", async () => {
  const crypto = await import("node:crypto");
  const rootKey = crypto.createHash("sha256").update("/proj").digest("hex");
  const host = makeHost({
    fs: {
      ...SRC,
      "/state/x": "seed",
    },
    service: {
      status: { status: 200, body: { id: 55, state: "completed", terminal: true } },
      submit: { status: 201, body: { id: 99, state: "queued", terminal: false } },
    },
  });
  // Seed the persisted flag as a prior process left it — no in-flight promise.
  host.$.fs.write(`/state/${rootKey}/state.json`, JSON.stringify({
    schema: "codemutator-mod/1",
    runs: {},
    uncertain_submit: {
      at: Date.now() - 60_000, client_ref: "ref-old", root: "/proj", scope: "src",
      source_digest: "d", config_digest: "c", mutant_limit: 4, budget_ms: 120_000,
    },
  }));
  register(host.on);
  const r1 = await host.run("command.run", { command: "codemutator-run", args: "src 4 120000" });
  assert.match(r1.text, /outcome is still unknown|reservation/);
  assert.equal(host.fetchCalls.filter((c) => c.startsWith("POST")).length, 0);
  const st = await host.run("command.run", { command: "codemutator-status", args: "" });
  assert.match(st.text, /unresolvable|operator|unknown/);
  // Operator verifies the run actually landed and adopts it.
  const r2 = await host.run("command.run", { command: "codemutator-resolve", args: "55" });
  assert.match(r2.text, /adopted|run #55/);
  const st2 = await host.run("command.run", { command: "codemutator-status", args: "" });
  assert.match(st2.text, /run #55/);
});

test("restart uncertain + operator resolves none: slot frees, next submit proceeds", async () => {
  const crypto = await import("node:crypto");
  const rootKey = crypto.createHash("sha256").update("/proj").digest("hex");
  const host = makeHost({
    fs: SRC,
    service: { submit: { status: 201, body: { id: 66, state: "queued", terminal: false } } },
  });
  host.$.fs.write(`/state/${rootKey}/state.json`, JSON.stringify({
    schema: "codemutator-mod/1", runs: {},
    uncertain_submit: {
      at: Date.now() - 60_000, client_ref: "ref-old2", root: "/proj", scope: "src",
      source_digest: "d", config_digest: "c", mutant_limit: 4, budget_ms: 120_000,
    },
  }));
  register(host.on);
  const r = await host.run("command.run", { command: "codemutator-resolve", args: "none" });
  assert.match(r.text, /cleared by operator/);
  const r2 = await host.run("command.run", { command: "codemutator-run", args: "src 4 120000" });
  assert.match(r2.text, /run #66 submitted/);
});
