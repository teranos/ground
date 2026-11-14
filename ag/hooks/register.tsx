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
  let branched: Forks = { name: '', forks: [] }
  try {
    const r = await $.process.run(['ground', 'forks', 'json'], { env: { CLAUDE_CODE_SESSION_ID: sessionId }, timeoutMs: 10000 })
    if (r.exitCode === 0) {
      const f = JSON.parse(r.stdout || '{}') as Partial<Forks>
      branched = { name: f.name ?? '', forks: f.forks ?? [] }
    }
  } catch {
    branched = { name: '', forks: [] }
  }
  await update($, forks, () => branched)
}

// What a press posted, as the press it is.
type Press = { act: string; to: string; id?: string; until?: string; says?: string }

// The ground command a press is: what is pressed, on whom, and what it carries.
function argvOf(d: Press): string[] {
  if (d.act === 'give') return ['ground', 'forks', 'give', d.to]
  const argv = ['ground', 'collected', d.act, d.to]
  if (d.act === 'cancel' && d.id) argv.push(d.id)
  if (d.act === 'hold' && d.until) argv.push(d.until)
  if (d.act === 'release' && d.says !== undefined) argv.push(d.says)
  return argv
}

// A press, asked of the node by ground as the person: what the node refused
// is kept for the band, and every press is written down.
async function press($: EngineInterface, d: Press, sessionId: string) {
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
    const gave = await press($, d as Press, sessionId)
    // "and it gets the name and is the active session at the same time"
    // The branch given the name is the session the person is in from now on:
    // /resume, as if they typed it. What refuses it is said under the rows.
    if (d.act === 'give' && gave) {
      try {
        await $.command.run({ command: 'resume', args: d.to })
      } catch (err) {
        await update($, refused, () => `/resume ${d.to} was not run: ${String(err)}`)
      }
    }
    await ask($, sessionId)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const now = await read($, said)
    const why = await read($, refused)
    const branched = (await read($, forks)) ?? { name: '', forks: [] }
    if (now === null || (now.ok && now.lines.length === 0 && branched.forks.length === 0 && why === null)) return next(e)
    const { Box, Text, Client } = $.ui.resolve(e)
    if (!now.ok) return <Box><Text color="red">{now.text}</Text></Box>
    return (
      <Box flexDirection="column">
        <Client key="lines" module="./lines.tsx" props={{ lines: now.lines, forks: branched.forks, name: branched.name }} />
        {why === null ? null : <Text color="red">{why}</Text>}
      </Box>
    )
  })
}
