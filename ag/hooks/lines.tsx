import type { ClientModule, ClientPointerEvent, ClientKeyEvent } from 'claude-code'

import type { Fork, Line } from '../types'

// One line a message, drawn and pressed here. At rest a message is its line:
//   16:25 <-- Shiitake: Some text of Shiitake to us.
// Clicked in, its buttons stand on a line above it:
//   +- +- [now]         [edit]              [delete] [esc]
// What a press means is posted to ag's hooks, which ask ground.

// The sessions that branched from this one stand above the messages, a row
// each; a click on one gives it this session's name (ground forks give).
export type Lines = { lines: Line[]; forks?: Fork[]; name?: string; here?: boolean }

type State = {
  open?: number // the message clicked in
  armed?: number // the message whose arrow was pressed once: XXXX
  deleting?: boolean // [delete] pressed once on the message clicked in: [DELETE]
  releasing?: boolean // [now] pressed once on the message clicked in: [NOW]
  due?: string // the time it is held to, as moved by +-, before it is asked
  typing?: string // what is typed in place of what is said, while editing
}

// What a press comes to: what to post to ag's hooks, if anything, and the
// state after it.
type Pressed = { post?: Record<string, string>; next: State }

// Which message, and whether this row is its buttons or its line.
type Row = { line: number; buttons: boolean }

// How far the message line stands in under its buttons.
const UNDER = 2
// Where the arrow stands on a message line at rest, and how wide it is.
const ARROW = 6
const ARROW_WIDE = 4

// The time moved by minutes, around the clock.
function moved(due: string, minutes: number): string {
  const [h, m] = due.split(':').map(Number)
  const all = (((h ?? 0) * 60 + (m ?? 0) + minutes) % 1440 + 1440) % 1440
  return `${String(Math.floor(all / 60)).padStart(2, '0')}:${String(all % 60).padStart(2, '0')}`
}

// Each row of the region: the message clicked in has its buttons above it.
function rowsOf(lines: Line[], open?: number): Row[] {
  const rows: Row[] = []
  lines.forEach((_, i) => {
    if (open === i) rows.push({ line: i, buttons: true })
    rows.push({ line: i, buttons: false })
  })
  return rows
}

// A press on a message's own line: on its arrow, or anywhere else on it.
// "the arrow you can also click on, one to see thebutton change into XXXX and again to cancel"
function onLine(state: State, at: number, x: number, line: Line): Pressed {
  const left = state.open === at ? UNDER : 0
  if (x >= left + ARROW && x < left + ARROW + ARROW_WIDE) {
    if (state.armed === at) return { post: { act: 'cancel', to: line.to, id: line.id }, next: {} }
    return { next: { ...state, armed: at } }
  }
  return { next: state.open === at ? state : { open: at } }
}

// Where each button starts on the button line, as drawn:
//   +- +- [now]         [edit]              [delete] [esc]
//     16:25 <-- Shiitake: Some text of Shiitake to us.
// "the word cancel isnt clear"
const AT = { now: 6, edit: 20, delete: 40, esc: 49 }
// "[now], this means to me kind fo same thing as [delete] two stage, press once, you get [NOW] green, and press another time, it actually get's released"
const nowOf = (releasing: boolean) => (releasing ? '[NOW]' : '[now]')
const deleteOf = (deleting: boolean) => (deleting ? '[DELETE]' : '[delete]')

// The +- pairs: hours first, then minutes, each up then down.
const NUDGE: Record<number, number> = { 0: 60, 1: -60, 3: 5, 4: -5 }

// A press on the buttons of the message clicked in.
function onButtons(state: State, x: number, line: Line, lines: Line[]): Pressed {
  const nudge = NUDGE[x]
  if (nudge !== undefined) {
    const until = moved(state.due ?? line.due, nudge)
    return { post: { act: 'hold', to: line.to, until }, next: { ...state, due: until } }
  }
  if (x >= AT.now && x < AT.now + 5) {
    if (state.releasing) return { post: { act: 'release', to: line.to }, next: {} }
    return { next: { ...state, releasing: true, deleting: false } }
  }
  if (x >= AT.edit && x < AT.edit + 6) {
    const whole = lines.filter(l => l.way === line.way && l.to === line.to).map(l => l.says).join('\n')
    return { next: { ...state, typing: whole } }
  }
  // "and there should be a more explicit abort, that is two stage abort"
  if (x >= AT.delete && x < AT.delete + 8) {
    if (state.deleting) return { post: { act: 'cancel', to: line.to, id: line.id }, next: {} }
    return { next: { ...state, deleting: true, releasing: false } }
  }
  // "cancel should get us out of the clicked-in,"
  if (x >= AT.esc && x < AT.esc + 5) return { next: {} }
  return { next: state }
}

// A key while editing what the message clicked in says.
function onKey(state: State, key: string, line: Line): Pressed {
  const typing = state.typing ?? ''
  if (key === 'return') return { post: { act: 'release', to: line.to, says: typing }, next: {} }
  if (key === 'backspace') return { next: { ...state, typing: typing.slice(0, -1) } }
  if (key.length === 1) return { next: { ...state, typing: typing + key } }
  return { next: state }
}

const Ag: ClientModule<Lines, State> = (props, surface) => {
  const { Box, Text } = surface.elements
  const state: State = surface.state ?? {}
  const forks = props.forks ?? []
  const rows = rowsOf(props.lines, state.open)
  // "yes,"
  // ⑂ Mycelia stays with  ● this session   ○ mycelia on k
  // The name is on the filled one; a click on another moves it there.
  const here = props.here !== false
  const lead = `⑂ ${props.name || 'the name'} stays with  `
  const hereLabel = `${here ? '●' : '○'} this session`
  const holder = forks.find(f => f.holds)
  const choices: { session: string; label: string; holds: boolean; from: number; to: number }[] = []
  let x = lead.length + hereLabel.length
  for (const f of forks) {
    const label = `${f.holds ? '●' : '○'} ${f.title || f.name || f.session.slice(0, 8)}`
    choices.push({ session: f.session, label, holds: f.holds, from: x + 3, to: x + 3 + label.length })
    x += 3 + label.length
  }
  const apply = (pressed: Pressed) => {
    if (pressed.post) surface.post(pressed.post)
    surface.setState(pressed.next)
  }

  surface.onPointer((e: ClientPointerEvent) => {
    if (e.type !== 'down') return
    if (forks.length > 0 && e.y === 0) {
      // A hollow one is the choice: a branch, to give the name to, or this
      // session, to take it back from the one holding it.
      if (!here && holder && e.x >= lead.length && e.x < lead.length + hereLabel.length) {
        apply({ post: { act: 'take', to: holder.session }, next: state })
        return
      }
      const at = choices.find(c => !c.holds && here && e.x >= c.from && e.x < c.to)
      // A branch alive in another window cannot become this one: the name
      // stays, and how to open it is said.
      const running = at && forks.find(f => f.session === at.session)?.running
      if (at) apply({ post: { act: running ? 'open' : 'give', to: at.session }, next: state })
      return
    }
    const row = rows[e.y - (forks.length > 0 ? 1 : 0)]
    const line = row ? props.lines[row.line] : undefined
    if (!row || !line) return
    apply(row.buttons ? onButtons(state, e.x, line, props.lines) : onLine(state, row.line, e.x, line))
  })

  surface.onKey((e: ClientKeyEvent) => {
    if (state.open === undefined || state.typing === undefined) return
    const line = props.lines[state.open]
    apply(line ? onKey(state, e.key, line) : { next: {} })
  })

  const buttonsOf = (at: number) => (
    <Box key={`b${at}`} flexDirection="row">
      <Text>{'+- +- '}</Text>
      <Text color={state.releasing ? 'green' : undefined} bold={!!state.releasing}>{nowOf(!!state.releasing)}</Text>
      <Text>{' '.repeat(AT.edit - AT.now - 5) + '[edit]' + ' '.repeat(AT.delete - AT.edit - 6)}</Text>
      <Text color={state.deleting ? 'red' : undefined} bold={!!state.deleting}>{deleteOf(!!state.deleting)}</Text>
      <Text>{' [esc]'}</Text>
    </Box>
  )

  const lineOf = (at: number, line: Line) => {
    const open = state.open === at
    const editing = open && state.typing !== undefined
    const armed = state.armed === at
    return (
      <Box key={`l${at}`} flexDirection="row">
        <Box flexShrink={0} flexDirection="row">
          {open ? <Text>{' '.repeat(UNDER)}</Text> : null}
          <Text>{open && state.due ? state.due : line.due}</Text>
          <Text> </Text>
          <Text color={armed ? 'red' : undefined}>{armed ? 'XXXX' : line.way === 'in' ? '<-- ' : '--> '}</Text>
          <Text bold>{line.who}</Text>
          <Text>: </Text>
        </Box>
        <Text dimColor={!editing} wrap="truncate">{editing ? `${state.typing}_` : line.says}</Text>
      </Box>
    )
  }

  return (
    <Box flexDirection="column">
      {forks.length > 0 ? (
        <Box key="forks" flexDirection="row">
          <Text>{lead}</Text>
          <Text bold={here} dimColor={!here}>{hereLabel}</Text>
          {choices.map(c => (
            <Text key={c.session} bold={c.holds} dimColor={!c.holds}>{'   ' + c.label}</Text>
          ))}
        </Box>
      ) : null}
      {rows.map(row => (row.buttons ? buttonsOf(row.line) : lineOf(row.line, props.lines[row.line] as Line)))}
    </Box>
  )
}

export default Ag
