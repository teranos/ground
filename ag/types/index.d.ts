// One message, as ag draws it on a line: which way it goes, the DID of the
// agent it waits for, when it is due on this clock, who said it or is to hear
// it, what it says, and the id the node names it by.
export type Line = {
  way: 'in' | 'out'
  to: string
  due: string
  who: string
  says: string
  id: string
}

// What `ground collected json` last said for this session: the lines it
// holds, or, when it is no answer of the node's, what went wrong (ok false).
export type Said = { ok: boolean; text: string; lines: Line[] }

declare module 'claude-code' {
  interface PluginState {
    ag: { said: Said | null; refused: string | null }
  }
}
