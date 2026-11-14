import type { ClientModule, ClientPointerEvent, ClientKeyEvent } from 'claude-code'

import type { Line } from '../types'

// One line a message, drawn and pressed here. At rest a message is its line:
//   16:25 <-- Shiitake: Some text of Shiitake to us.
// Clicked in, its buttons stand on a line above it:
//   +- +- [now]         [edit]              [cancel]
// What a press means is posted to ag's hooks, which ask ground.

export type Lines = { lines: Line[] }

type State = {
  open?: number // the message clicked in
  due?: string // the time it is held to, as moved by +-, before it is asked
  typing?: string // what is typed in place of what is said, while editing
}

// Where each button starts on the button line, as drawn:
//   +- +- [now]         [edit]              [cancel]
//     16:25 <-- Shiitake: Some text of Shiitake to us.
const AT = { now: 6, edit: 20, cancel: 40 }
const BUTTONS = '+- +- [now]'.padEnd(AT.edit) + '[edit]'.padEnd(AT.cancel - AT.edit) + '[cancel]'
// How far the message line stands in under its buttons.
const UNDER = 2

// The time moved by minutes, around the clock.
function moved(due: string, minutes: number): string {
  const [h, m] = due.split(':').map(Number)
  const all = (((h ?? 0) * 60 + (m ?? 0) + minutes) % 1440 + 1440) % 1440
  return `${String(Math.floor(all / 60)).padStart(2, '0')}:${String(all % 60).padStart(2, '0')}`
}

const Ag: ClientModule<Lines, State> = (props, surface) => {
  const { Box, Text } = surface.elements
  const state: State = surface.state ?? {}
  const set = (next: State) => surface.setState(next)

  // Which message and which of its lines each row of the region is.
  const rows: { line: number; buttons: boolean }[] = []
  props.lines.forEach((_, i) => {
    if (state.open === i) rows.push({ line: i, buttons: true })
    rows.push({ line: i, buttons: false })
  })

  surface.onPointer((e: ClientPointerEvent) => {
    if (e.type !== 'down') return
    const row = rows[e.y]
    const line = row ? props.lines[row.line] : undefined
    if (!row || !line) return
    if (!row.buttons) {
      if (state.open !== row.line) set({ open: row.line })
      return
    }
    const at = AT
    const due = state.due ?? line.due
    const hold = (next: string) => {
      surface.post({ act: 'hold', to: line.to, until: next })
      set({ ...state, due: next })
    }
    if (e.x === 0) return hold(moved(due, 60))
    if (e.x === 1) return hold(moved(due, -60))
    if (e.x === 3) return hold(moved(due, 5))
    if (e.x === 4) return hold(moved(due, -5))
    if (e.x >= at.now && e.x < at.now + 5) {
      surface.post({ act: 'release', to: line.to })
      return set({})
    }
    if (e.x >= at.edit && e.x < at.edit + 6) {
      const whole = props.lines.filter(l => l.way === line.way && l.to === line.to).map(l => l.says).join('\n')
      return set({ ...state, typing: whole })
    }
    if (e.x >= at.cancel && e.x < at.cancel + 8) {
      surface.post({ act: 'cancel', to: line.to, id: line.id })
      return set({})
    }
  })

  surface.onKey((e: ClientKeyEvent) => {
    if (state.open === undefined || state.typing === undefined) return
    const line = props.lines[state.open]
    if (!line) return set({})
    if (e.key === 'return') {
      surface.post({ act: 'release', to: line.to, says: state.typing })
      return set({})
    }
    if (e.key === 'backspace') return set({ ...state, typing: state.typing.slice(0, -1) })
    if (e.key.length === 1) return set({ ...state, typing: state.typing + e.key })
  })

  return (
    <Box flexDirection="column">
      {rows.map(row => {
        const line = props.lines[row.line] as Line
        if (row.buttons) return <Text key={`b${row.line}`}>{BUTTONS}</Text>
        const open = state.open === row.line
        const due = open && state.due ? state.due : line.due
        const says = open && state.typing !== undefined ? `${state.typing}_` : line.says
        return (
          <Box key={`l${row.line}`} flexDirection="row">
            {open ? <Text>{' '.repeat(UNDER)}</Text> : null}
            <Text>{due}</Text>
            <Text> </Text>
            <Text>{line.way === 'in' ? '<-- ' : '--> '}</Text>
            <Text bold>{line.who}</Text>
            <Text>: </Text>
            <Text dimColor={!(open && state.typing !== undefined)} wrap="truncate">{says}</Text>
          </Box>
        )
      })}
    </Box>
  )
}

export default Ag
