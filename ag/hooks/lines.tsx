import type { ClientModule, ClientPointerEvent, ClientKeyEvent } from 'claude-code'

import type { Line } from '../types'

// One line a message, drawn and pressed here: the time, the arrow, who, and
// what is said. What a press means is posted to ag's hooks, which ask ground.

export type Lines = { lines: Line[] }

type Part = 'time' | 'arrow' | 'says'
type Typing = { line: number; part: 'time' | 'says'; text: string }
type State = {
  armed?: { line: number; part: Part }
  hover?: { line: number; part: Part }
  typing?: Typing
}

const TIME = 5 // HH:MM
const ARROW = 4 // "<-- ", "--> ", "XXXX"

function partAt(line: Line, x: number): Part | null {
  if (x < TIME) return 'time'
  if (x > TIME && x <= TIME + ARROW) return 'arrow'
  if (x > TIME + ARROW + line.who.length + 1) return 'says'
  return null
}

const Ag: ClientModule<Lines, State> = (props, surface) => {
  const { Box, Text } = surface.elements
  const state: State = surface.state ?? {}
  const set = (next: State) => surface.setState(next)

  surface.onPointer((e: ClientPointerEvent) => {
    const line = props.lines[e.y]
    const part = line ? partAt(line, e.x) : null
    if (e.type === 'move' || e.type === 'enter') {
      const was = state.hover
      if (was?.line !== e.y || was?.part !== part) set({ ...state, hover: part && line ? { line: e.y, part } : undefined })
      return
    }
    if (e.type === 'leave') {
      if (state.hover) set({ ...state, hover: undefined })
      return
    }
    if (e.type !== 'down' || !line || !part) return
    if (part === 'time' && e.button === 'right') {
      set({ typing: { line: e.y, part: 'time', text: '' } })
      return
    }
    if (part === 'says') {
      set({ typing: { line: e.y, part: 'says', text: props.lines.filter(l => l.way === line.way && l.to === line.to).map(l => l.says).join('\n') } })
      return
    }
    const armed = state.armed
    if (armed && armed.line === e.y && armed.part === part) {
      if (part === 'time') surface.post({ act: 'release', to: line.to })
      if (part === 'arrow') surface.post({ act: 'cancel', to: line.to, id: line.id })
      set({})
      return
    }
    set({ armed: { line: e.y, part } })
  })

  surface.onKey((e: ClientKeyEvent) => {
    const typing = state.typing
    if (!typing) return
    const line = props.lines[typing.line]
    if (!line) return set({})
    if (e.key === 'return') {
      if (typing.part === 'time') surface.post({ act: 'hold', to: line.to, until: typing.text })
      else surface.post({ act: 'release', to: line.to, says: typing.text })
      return set({})
    }
    if (e.key === 'backspace') return set({ typing: { ...typing, text: typing.text.slice(0, -1) } })
    if (e.key.length === 1) return set({ typing: { ...typing, text: typing.text + e.key } })
  })

  const lit = (i: number, part: Part) => state.hover?.line === i && state.hover.part === part

  return (
    <Box flexDirection="column">
      {props.lines.map((line, i) => {
        const typing = state.typing?.line === i ? state.typing : undefined
        const armedHere = state.armed?.line === i ? state.armed.part : undefined
        const time = typing?.part === 'time' ? (typing.text + '_').padEnd(TIME).slice(0, TIME) : armedHere === 'time' ? 'now  ' : line.due
        const arrow = armedHere === 'arrow' ? 'XXXX' : line.way === 'in' ? '<-- ' : '--> '
        const says = typing?.part === 'says' ? typing.text + '_' : `"${line.says}"`
        return (
          <Box key={`l${i}`} flexDirection="row">
            <Text inverse={lit(i, 'time') || typing?.part === 'time'} color={armedHere === 'time' ? 'yellow' : undefined}>{time}</Text>
            <Text> </Text>
            <Text inverse={lit(i, 'arrow')} color={armedHere === 'arrow' ? 'red' : undefined}>{arrow}</Text>
            <Text bold>{line.who}</Text>
            <Text>: </Text>
            <Text dimColor={typing?.part !== 'says'} inverse={lit(i, 'says')} wrap="truncate">{says}</Text>
          </Box>
        )
      })}
    </Box>
  )
}

export default Ag
