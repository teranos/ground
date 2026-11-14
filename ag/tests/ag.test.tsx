import { expect, test } from 'claude-code/testing'

// What `ground collected json` answers for a session with one message in and
// one out, as ground draws it on this clock.
const ANSWER = JSON.stringify({
  incoming: [{ to: 'Mycelia', did: 'did:key:z6MkMe', due: '15:40', items: [
    { id: '871588189c2ca9c4', from: 'Shiitake', says: 'hello', at: '09:40' },
  ] }],
  outbound: [{ to: 'Shiitake', did: 'did:key:z6MkOther', due: '16:00', id: 'a2adff460cd772b0', says: 'Mycelia here', at: '10:00' }],
})

const BAND = {
  plugin: 'ag',
  component: 'AbovePrompt',
  requestId: 'above-prompt',
  props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 20, bodyColumns: 80, scroll: { offset: 0, bodyRows: 20 }, view: {} },
} as const

function engine(on: Parameters<Parameters<typeof test>[1]>[1], ran: string[][], answer = ANSWER) {
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sid' }))
  on('clock.every', () => ({ value: {} }))
  on('process.run', (_, e) => {
    ran.push([...e.argv])
    return { value: { exitCode: 0, stdout: e.argv[2] === 'json' ? answer : '', stderr: '' } }
  })
}

test('each message goes to the Client as a line: when, which way, who, what is said', async ($, on) => {
  const ran: string[][] = []
  engine(on, ran)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  const lines = await ui.find({ type: 'Client', key: 'lines' })
  expect(lines?.props.props).toEqual({ lines: [
    { way: 'in', to: 'did:key:z6MkMe', due: '15:40', who: 'Shiitake', says: 'hello', id: '871588189c2ca9c4' },
    { way: 'out', to: 'did:key:z6MkOther', due: '16:00', who: 'Shiitake', says: 'Mycelia here', id: 'a2adff460cd772b0' },
  ] })
  expect(ran[0]).toEqual(['ground', 'collected', 'json'])
  await ui.unmount()
})

test('what a press posts, ground asks the node', async ($, on) => {
  const ran: string[][] = []
  engine(on, ran)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  await ui.post({ act: 'cancel', to: 'did:key:z6MkMe', id: '871588189c2ca9c4' }, { in: 'lines' })
  await ui.post({ act: 'release', to: 'did:key:z6MkMe' }, { in: 'lines' })
  await ui.post({ act: 'hold', to: 'did:key:z6MkMe', until: '17:40' }, { in: 'lines' })
  await ui.post({ act: 'release', to: 'did:key:z6MkMe', says: 'hello, edited' }, { in: 'lines' })
  expect(ran).toContainEqual(['ground', 'collected', 'cancel', 'did:key:z6MkMe', '871588189c2ca9c4'])
  expect(ran).toContainEqual(['ground', 'collected', 'release', 'did:key:z6MkMe'])
  expect(ran).toContainEqual(['ground', 'collected', 'hold', 'did:key:z6MkMe', '17:40'])
  expect(ran).toContainEqual(['ground', 'collected', 'release', 'did:key:z6MkMe', 'hello, edited'])
  await ui.unmount()
})

// "+- +- [now]         [edit]              [cancel]"
// "  16:25 <-- Shiitake: Some text of Shiitake to us."
test('a message clicked in shows its buttons, and its cancel cancels that one', async ($, on) => {
  const ran: string[][] = []
  engine(on, ran)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  expect((await ui.find({ in: 'lines', type: 'Text', text: /^15:40$/ }))?.text).toBe('15:40')
  expect((await ui.find({ in: 'lines', type: 'Text', text: /^Shiitake$/ }))?.props.bold).toBe(true)
  expect((await ui.find({ in: 'lines', type: 'Text', text: /^hello$/ }))?.props.dimColor).toBe(true)
  expect(await ui.find({ in: 'lines', type: 'Text', text: /\[cancel\]/ })).toBeUndefined()

  await ui.pointer({ type: 'down', x: 10, y: 0, button: 'left' })
  expect((await ui.find({ in: 'lines', type: 'Text', text: /\[cancel\]/ }))?.text).toBe('+- +- [now]         [edit]              [cancel]')
  await ui.pointer({ type: 'down', x: 41, y: 0, button: 'left' })
  expect(ran).toContainEqual(['ground', 'collected', 'cancel', 'did:key:z6MkMe', '871588189c2ca9c4'])
  await ui.unmount()
})

test('nothing waiting draws nothing', async ($, on) => {
  const ran: string[][] = []
  engine(on, ran, '{"incoming":[],"outbound":[]}')
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /engine/ }))?.text).toBe('engine')
  await ui.unmount()
})
