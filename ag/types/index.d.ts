// 「[Opus 5.5] One message, as ag draws it on a line: which way it goes, the DID of the」
// 「[Opus 5.5] agent it waits for, when it is due on this clock, who said it or is to hear」
// 「[Opus 5.5] it, what it says, and the id the node names it by.」
export type Line = {
  way: 'in' | 'out'
  to: string
  due: string
  who: string
  says: string
  id: string
}

// 「[Opus 5.5] What `ground collected json` last said for this session: the lines it」
// 「[Opus 5.5] holds, or, when it is no answer of the node's, what went wrong (ok false).」
export type Said = { ok: boolean; text: string; lines: Line[] }

declare module 'claude-code' {
  interface PluginState {
    ag: { said: Said | null; refused: string | null }
  }
}
