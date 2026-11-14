import { atom, read, update } from 'claude-code'
import type { Register, EngineInterface } from 'claude-code'

import type { Forks, Line, Said } from '../types'

// ag: above ground. What comes in for this session and what it said that goes
// out, as mycelia kept them; `ground collected json` reads them by the DID of
// the session's own key. Each message is one line, drawn and pressed by the
// Client in ./lines.tsx; what a press means, ground asks the node as the person.
// Nothing waiting draws nothing; what went wrong is drawn as it was said.
const said = atom({ plugin: 'ag', key: 'said' } as const, null)
// What the last press came to when the node did not do it: drawn red under
// the lines until the next press.
const refused = atom({ plugin: 'ag', key: 'refused' } as const, null)
// "maybe i want that session to inherit the name and not you"
// The sessions that branched from this one, as ground recorded them at the
// fork: each stands as a row, and a click on it gives it this session's name.
const forks = atom({ plugin: 'ag', key: 'forks' } as const, null)

// Every press and what it came to, written where it can be read from outside.
const PRESSES = '/Users/s.b.vanhouten/.local/state/ug/ag-presses'

const EVERY_MS = 5000

type Answer = {
  error?: string
  incoming?: { to: string; did: string; due: string; items: { id: string; from: string; says: string }[] }[]
  outbound?: { to: string; did: string; due: string; id: string; says: string }[]
}

function linesOf(a: Answer): Line[] {
  const lines: Line[] = []
  for (const one of a.incoming ?? [])
    for (const item of one.items) lines.push({ way: 'in', to: one.did, due: one.due, who: item.from, says: item.says, id: item.id })
  for (const one of a.outbound ?? [])
    lines.push({ way: 'out', to: one.did, due: one.due, who: one.to, says: one.says, id: one.id })
  return lines
}

// What `ground collected json` says for the session now, kept for the band.
async function ask($: EngineInterface, sessionId: string) {
  let now: Said
  try {
    const r = await $.process.run(['ground', 'collected', 'json'], {
      env: { CLAUDE_CODE_SESSION_ID: sessionId },
      timeoutMs: 10000,
    })
    const a = JSON.parse(r.stdout || '{}') as Answer
    now = a.error !== undefined
      ? { ok: false, text: a.error, lines: [] }
      : r.exitCode !== 0
        ? { ok: false, text: (r.stderr || r.stdout).trim() || `ground collected json exited ${r.exitCode}`, lines: [] }
        : { ok: true, text: '', lines: linesOf(a) }
  } catch (err) {
    now = { ok: false, text: `ground collected json did not run: ${String(err)}`, lines: [] }
  }
  await update($, said, () => now)
  let branched: Forks = { name: '', here: true, forks: [] }
  try {
    const r = await $.process.run(['ground', 'forks', 'json'], { env: { CLAUDE_CODE_SESSION_ID: sessionId }, timeoutMs: 10000 })
    if (r.exitCode === 0) {
      const f = JSON.parse(r.stdout || '{}') as Partial<Forks>
      branched = { name: f.name ?? '', here: f.here ?? true, forks: f.forks ?? [] }
    }
  } catch {
    branched = { name: '', here: true, forks: [] }
  }
  await update($, forks, () => branched)
}

// "BUT AG WOULD KNOW, RIGHT ?"
// A press on what is collected is the person's click, and only ag sees it:
// ag asks mycelia directly over its socket, carrying the secret it was given
// when the person paired it with a finger. That secret lives here, in memory,
// and nowhere an agent reads.
const SOCKET = '/Users/s.b.vanhouten/.local/state/ug/mycelia.sock'
let secret = ''

// The person's finger, once: mycelia asks for it and gives ag its secret.
// Null when paired, else why not.
async function pair($: EngineInterface): Promise<string | null> {
  const r = await $.http.fetch('http://mycelia/pair', { method: 'POST', socketPath: SOCKET, body: '' })
  const [status, ...rest] = r.text.split('\n')
  if (status === '200') {
    secret = rest.join('\n').trim()
    return null
  }
  return rest.join('\n') || r.text
}

// The next time this clock reads HH:MM, as the node takes it: RFC3339 in UTC.
function untilOf(hhmm: string): string {
  const [h, m] = hhmm.split(':').map(Number)
  const at = new Date()
  at.setHours(h ?? 0, m ?? 0, 0, 0)
  if (at.getTime() <= Date.now()) at.setDate(at.getDate() + 1)
  return at.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

// The node's path and body for a press, as ground collected asked them.
function askOf(d: Press): [string, Record<string, string>] {
  const body: Record<string, string> = { to: d.to }
  if (d.act === 'cancel' && d.id) body.id = d.id
  if (d.act === 'hold' && d.until) body.until = untilOf(d.until)
  if (d.act === 'release' && d.says !== undefined) body.says = d.says
  return [`/api/collected/${d.act}`, body]
}

// A press at mycelia: null when the node did it, else why not. A secret
// mycelia no longer holds (it restarted) is paired again, once.
async function atMycelia($: EngineInterface, d: Press): Promise<string | null> {
  const [path, body] = askOf(d)
  for (let tries = 0; tries < 2; tries++) {
    if (!secret) {
      const why = await pair($)
      if (why) return why
    }
    const r = await $.http.fetch(`http://mycelia${path}`, {
      method: 'POST',
      socketPath: SOCKET,
      headers: { 'X-Ag-Secret': secret, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    const [status, ...rest] = r.text.split('\n')
    if (status === '401') { secret = ''; continue }
    if (status === '200') return null
    return `${path} ${status === '0' ? 'was not asked' : `answered ${status}`}: ${rest.join('\n')}`
  }
  return `${path}: ag was not paired with your finger`
}

// What a press posted, as the press it is.
type Press = { act: string; to: string; id?: string; until?: string; says?: string }

// The ground command a press is: what is pressed, on whom, and what it carries.
function argvOf(d: Press): string[] {
  return ['ground', 'forks', 'give', d.to]
}

// A press, asked of the node by ground as the person: what the node refused
// is kept for the band, and every press is written down.
async function press($: EngineInterface, d: Press, sessionId: string) {
  if (d.act !== 'give') {
    let why: string | null
    try {
      why = await atMycelia($, d)
    } catch (err) {
      why = `mycelia was not reached at ${SOCKET}: ${String(err)}`
    }
    await update($, refused, () => why)
    await $.fs.write(PRESSES, JSON.stringify({ at: await $.clock.now(), press: d, refused: why }) + '\n')
    return why === null
  }
  const argv = argvOf(d)
  const r = await $.process.run(argv, { env: { CLAUDE_CODE_SESSION_ID: sessionId }, timeoutMs: 60000 })
  const why = r.exitCode === 0 ? null : (r.stderr || r.stdout).trim() || `${argv.join(' ')} exited ${r.exitCode}`
  await update($, refused, () => why)
  await $.fs.write(PRESSES, JSON.stringify({ at: await $.clock.now(), argv, exitCode: r.exitCode, stderr: r.stderr }) + '\n')
  return r.exitCode === 0
}

export const register: Register = on => {
  let sessionId = ''

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    sessionId = await $.session.id()
    await ask($, sessionId)
    $.clock.every(EVERY_MS, () => ask($, sessionId))
    return started
  })

  on('ui.message', async ($, e, next) => {
    const d = e.data as Partial<Press>
    if (!d.act || !d.to) return next(e)
    // "and it gets the name and is the active session at the same time"
    // The switch goes first, and the name follows only a session the person
    // can be in: one running in the background is opened elsewhere, and what
    // Claude Code said of it stands under the rows. Taking the name back to
    // this session switches nothing.
    if (d.act === 'open') {
      await update($, refused, () => `the name stays here: that session is open in another window; \`claude attach ${d.to.slice(0, 8)}\` opens it`)
    } else if (d.act === 'give') {
      let said = ''
      try {
        said = (await $.command.run({ command: 'resume', args: d.to })).text ?? ''
      } catch (err) {
        said = `/resume ${d.to} was not run: ${String(err)}`
      }
      if (said.includes('running in the background') || said.includes('was not run')) {
        await update($, refused, () => `the name stays here: ${said}`)
      } else {
        await press($, d as Press, sessionId)
      }
    } else if (d.act === 'take') {
      await press($, { ...d, act: 'give' } as Press, sessionId)
    } else {
      await press($, d as Press, sessionId)
    }
    await ask($, sessionId)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const now = await read($, said)
    const why = await read($, refused)
    const branched = (await read($, forks)) ?? { name: '', here: true, forks: [] }
    if (now === null || (now.ok && now.lines.length === 0 && branched.forks.length === 0 && why === null)) return next(e)
    const { Box, Text, Client } = $.ui.resolve(e)
    if (!now.ok) return <Box><Text color="red">{now.text}</Text></Box>
    return (
      <Box flexDirection="column">
        <Client key="lines" module="./lines.tsx" props={{ lines: now.lines, forks: branched.forks, name: branched.name, here: branched.here }} />
        {why === null ? null : <Text color="red">{why}</Text>}
      </Box>
    )
  })
}
