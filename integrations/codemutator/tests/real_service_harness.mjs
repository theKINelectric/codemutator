// Real-service receipt driver — NOT a test suite. Binds the actual
// register.mjs to real fetch/fs/process surfaces and drives the Mod's own
// command + boundary hooks against a running codeMUTATOR service.
//
// Usage: node tests/real_service_harness.mjs <fixture_abs_path> [scope] [limit] [budget_ms]
// Env:   CODEMUTATOR_API (default http://127.0.0.1:4300), CODEMUTATOR_MOD_STATE.
//
// Prints a transcript; writes the Mod's evidence envelopes under
// CODEMUTATOR_MOD_STATE (default /tmp/codemutator-mod-state) and verifies the
// fixture tree is byte-identical afterwards.

import { register } from "../hooks/register.mjs";
import { createHash } from "node:crypto";
import { readdir, readFile, realpath, stat, writeFile, mkdir } from "node:fs/promises";

const ROOT = process.argv[2];
const SCOPE = process.argv[3] || "src";
const LIMIT = process.argv[4] || "4";
const BUDGET = process.argv[5] || "60000";
if (!ROOT) { console.error("usage: real_service_harness.mjs <fixture> [scope] [limit] [budget]"); process.exit(2); }

const listeners = [];
const transcript = [];
const say = (m) => { transcript.push(m); console.log(m); };

const kindOf = async (p) => { const s = await stat(p); return s.isDirectory() ? "dir" : s.isFile() ? "file" : "other"; };

const $ = {
  env: { get: async (k) => process.env[k] ?? null },
  session: { id: async () => process.env.CODEMUTATOR_SESSION || "real-receipt" },
  command: { register: async (c) => say(`[command.register] ${c.name}`) },
  ui: { log: async (m) => say(`[ui.log] ${m}`) },
  http: {
    fetch: async (url, init) => {
      const res = await fetch(url, init);
      return { status: res.status, ok: res.ok, headers: Object.fromEntries(res.headers), text: await res.text() };
    },
  },
  fs: {
    stat: async (p) => { const s = await stat(p); const k = await kindOf(p); return { kind: k, realPath: await realpath(p), isLink: s.isSymbolicLink(), size: s.size, mtimeMs: s.mtimeMs }; },
    list: async (p) => {
      const ents = await readdir(p, { withFileTypes: true });
      const out = [];
      for (const d of ents) {
        const fp = `${p}/${d.name}`;
        const s = await stat(fp);
        out.push({ name: d.name, kind: d.isDirectory() ? "dir" : d.isFile() ? "file" : "other", size: s.size, mtimeMs: s.mtimeMs, isLink: d.isSymbolicLink() });
      }
      return out;
    },
    read: async (p) => readFile(p, "utf8"),
    write: async (p, text) => { await mkdir(p.split("/").slice(0, -1).join("/"), { recursive: true }); await writeFile(p, text); },
    exists: async (p) => !!(await stat(p).catch(() => null)),
  },
};

const run = async (name, e) => {
  const L = listeners.filter((l) => l.name === name && (!l.opts?.command || l.opts.command === e?.command));
  let next = async (ev) => ({ ...ev });
  for (let i = L.length - 1; i >= 0; i--) { const fn = L[i].fn; const nx = next; next = async (ev) => fn($, ev, nx); }
  return next(e);
};

const treeDigest = async (dir) => {
  const h = createHash("sha256");
  const walk = async (d) => {
    for (const e of (await readdir(d, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const p = `${d}/${e.name}`;
      if (e.isDirectory()) await walk(p);
      else if (e.isFile()) h.update(`${p}\n${await readFile(p, "utf8")}\n`);
    }
  };
  await walk(dir);
  return h.digest("hex");
};

register((n, o, f) => listeners.push({ name: n, opts: o, fn: f || o }));

say(`== codemutator real-service receipt ==`);
say(`fixture: ${ROOT}  scope: ${SCOPE}  limit: ${LIMIT}  budget: ${BUDGET}ms`);
const before = await treeDigest(ROOT);
say(`source digest before: ${before.slice(0, 16)}…`);

const sub = await run("command.run", { command: "codemutator-run", args: `${SCOPE} ${LIMIT} ${BUDGET}` });
say(`[submit] ${sub.text}`);

let done = false;
for (let i = 0; i < 60 && !done; i++) {
  await new Promise((r) => setTimeout(r, 5000));
  const stop = await run("classic.Stop", { cwd: ROOT, hook_event_name: "Stop", stop_hook_active: false });
  const notice = (stop.additionalContext || []).join("\n");
  if (notice) say(`[boundary ${i + 1}] ${notice}`);
  if (notice && !/still running/.test(notice)) done = true;
}

const after = await treeDigest(ROOT);
say(`source digest after:  ${after.slice(0, 16)}…  ${before === after ? "UNCHANGED" : "CHANGED — STALE PATH"}`);
say(`== ${done ? "terminal" : "TIMEOUT waiting"} ==`);
process.exit(done ? 0 : 1);
