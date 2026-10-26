import { expect, mock, test } from 'claude-code/testing'

// PF-04 native-surface controls: the engine's own calls drive the Mod —
// $.command.run submits bounded runs, $.classic.Stop polls once per boundary
// (never blocking), http.fetch/fs.* are mocked at the engine boundary.
// Simulation receipt, not a real-service run.

const SRC = 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n'
const EDIT_CWD = '/proj'

function project() {
  const files: Record<string, string> = { '/proj/src/lib.rs': SRC, '/proj/Cargo.toml': '[package]\nname="x"\n' }
  const onFs = (on: any) => {
    on('fs.stat', (_$: any, e: any) => ({ value: { kind: 'dir', size: 0, mtimeMs: 0, isLink: false, realPath: e.path } }))
    on('fs.exists', (_$: any, e: any) => ({ value: e.path in files }))
    on('fs.list', (_$: any, e: any) => {
      const prefix = `${e.path}/`
      const seen = new Map<string, any>()
      for (const k of Object.keys(files)) {
        if (!k.startsWith(prefix)) continue
        const rest = k.slice(prefix.length)
        const head = rest.split('/')[0]
        if (!seen.has(head)) seen.set(head, { name: head, kind: rest.includes('/') ? 'dir' : 'file', size: 4, mtimeMs: 0, isLink: false })
      }
      return { value: [...seen.values()] }
    })
    on('fs.read', (_$: any, e: any) => {
      if (e.path in files) return { value: files[e.path] }
      throw new Error(`ENOENT ${e.path}`)
    })
    on('fs.write', (_$: any, e: any) => { files[e.path] = e.text; return { value: undefined } })
  }
  return { files, onFs }
}

function service(on: any, svc: { runId: number; state: string; terminal: boolean; outcomes?: any[] }) {
  const calls: string[] = []
  on('http.fetch', (_$: any, e: any) => {
    const url = e.url as string
    const method = e.init?.method || 'GET'
    calls.push(`${method} ${url}`)
    if (url.endsWith('/api/runs') && method === 'POST')
      return { value: { status: 201, ok: true, headers: {}, text: JSON.stringify({ id: svc.runId, state: 'queued', terminal: false }) } }
    if (/\/api\/runs\/\d+\/outcomes$/.test(url))
      return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ run_id: svc.runId, state: svc.state, outcomes: svc.outcomes || [] }) } }
    if (/\/api\/runs\/\d+\/cancel$/.test(url)) {
      svc.state = 'cancelled'
      svc.terminal = true
      return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ id: svc.runId, state: 'cancelled', terminal: true }) } }
    }
    if (/\/api\/runs\/\d+$/.test(url))
      return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ id: svc.runId, state: svc.state, terminal: svc.terminal }) } }
    return { value: { status: 404, ok: false, headers: {}, text: '{}' } }
  })
  return calls
}

function sessionStart(on: any, sessionId: string) {
  on('classic.Stop', () => ({}))
  on('session.start', (_$: any, e: any) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: sessionId }))
  on('command.register', () => ({ value: undefined }))
  mock.env(on, { CODEMUTATOR_MOD_STATE: '/cm-state', PWD: EDIT_CWD })
}

test('submit bounded run → boundary polls once while running → terminal score surfaced', async ($, on) => {
  sessionStart(on, 'cm-1')
  const { onFs } = project()
  onFs(on)
  const svc = { runId: 42, state: 'running', terminal: false, outcomes: [] as any[] }
  const calls = service(on, svc)

  // session.start registers the four commands.
  await $.session.start({ cwd: EDIT_CWD, surface: null, isInteractive: false })

  const sub: any = await $.command.run({ command: 'codemutator-run', args: 'src 4' })
  expect(sub.text).toContain('run #42 submitted')
  expect(sub.text).toContain('mutant limit 4')
  expect(calls.filter((c) => c.startsWith('POST'))).toHaveLength(1)

  // Boundary while running: one GET, no resubmission, never blocks.
  const r1: any = await $.classic.Stop({ cwd: EDIT_CWD })
  expect((r1.additionalContext || []).join('\n')).toContain('still running')
  expect(calls.filter((c) => c.startsWith('POST '))).toHaveLength(1)
  expect(r1.block ?? undefined).toBeUndefined()

  // Service reports terminal; next boundary surfaces score + counts.
  svc.state = 'completed'
  svc.terminal = true
  svc.outcomes = [
    { site_id: 1, file: 'src/lib.rs', line: 1, function: 'add', status: 'killed', reason: 'assertion' },
    { site_id: 2, file: 'src/lib.rs', line: 1, function: 'add', status: 'killed', reason: 'assertion' },
    { site_id: 3, file: 'src/lib.rs', line: 1, function: 'add', status: 'survived', reason: 'all_tests_passed' },
    { site_id: 4, file: 'src/lib.rs', line: 1, function: 'add', status: 'invalid', reason: 'compile_error' },
  ]
  const r2: any = await $.classic.Stop({ cwd: EDIT_CWD })
  const notice = (r2.additionalContext || []).join('\n')
  expect(notice).toContain('completed')
  expect(notice).toContain('score 2/3')
  expect(notice).toContain('invalid 1')
})

test('a changed working tree after submit is stale — refused, not promoted', async ($, on) => {
  sessionStart(on, 'cm-2')
  const { files, onFs } = project()
  onFs(on)
  service(on, { runId: 7, state: 'completed', terminal: true, outcomes: [{ site_id: 1, status: 'killed', reason: 'assertion' }] })
  await $.session.start({ cwd: EDIT_CWD, surface: null, isInteractive: false })
  await $.command.run({ command: 'codemutator-run', args: 'src' })
  files['/proj/src/lib.rs'] += '// edited after submit\n'
  const res: any = await $.classic.Stop({ cwd: EDIT_CWD })
  const notice = (res.additionalContext || []).join('\n')
  expect(notice).toContain('stale')
  expect(notice).toContain('refusing to promote')
})

test('one active run per session+project; cancel verifies terminal', async ($, on) => {
  sessionStart(on, 'cm-3')
  project().onFs(on)
  service(on, { runId: 11, state: 'running', terminal: false })
  await $.session.start({ cwd: EDIT_CWD, surface: null, isInteractive: false })
  await $.command.run({ command: 'codemutator-run', args: 'src' })
  const again: any = await $.command.run({ command: 'codemutator-run', args: 'src' })
  expect(again.text).toContain('already active')
  const cancel: any = await $.command.run({ command: 'codemutator-cancel', args: '11' })
  expect(cancel.text).toContain('terminal confirmed')
})

test('quiet boundary with no pending runs adds nothing', async ($, on) => {
  sessionStart(on, 'cm-4')
  project().onFs(on)
  const calls = service(on, { runId: 1, state: 'completed', terminal: true })
  const res: any = await $.classic.Stop({ cwd: EDIT_CWD })
  expect(res.additionalContext ?? []).toEqual([])
  expect(calls.length).toBe(0)
})
