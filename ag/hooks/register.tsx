import { atom, read, update } from 'claude-code'
import type { Register, EngineInterface } from 'claude-code'

import type { Line, Said } from '../types'

// ag: above ground. What comes in for this session and what it said that goes
// out, as mycelia kept them; `ground collected json` reads them by the DID of
// the session's own key. Each message is one line, drawn and pressed by the
// Client in ./lines.tsx; what a press means, ground asks the node as the person.
// Nothing waiting draws nothing; what went wrong is drawn as it was said.
const said = atom({ plugin: 'ag', key: 'said' } as const, null)

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

  // What a press on a line means, asked of the node by ground as the person.
  on('ui.message', async ($, e, next) => {
    const d = e.data as { act?: string; to?: string; id?: string; until?: string; says?: string }
    if (!d.act || !d.to) return next(e)
    const argv = ['ground', 'collected', d.act, d.to]
    if (d.act === 'cancel' && d.id) argv.push(d.id)
    if (d.act === 'hold' && d.until) argv.push(d.until)
    if (d.act === 'release' && d.says !== undefined) argv.push(d.says)
    const r = await $.process.run(argv, { timeoutMs: 60000 })
    if (r.exitCode !== 0) $.ui.toast((r.stderr || r.stdout).trim() || `${argv.join(' ')} exited ${r.exitCode}`)
    await ask($, sessionId)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const now = await read($, said)
    if (now === null || (now.ok && now.lines.length === 0)) return next(e)
    const { Box, Text, Client } = $.ui.resolve(e)
    if (!now.ok) return <Box><Text color="red">{now.text}</Text></Box>
    return (
      <Box flexDirection="column">
        <Client key="lines" module="./lines.tsx" props={{ lines: now.lines }} />
      </Box>
    )
  })
}
