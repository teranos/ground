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
  ], forks: [], name: '', here: true })
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
test('a message clicked in shows its buttons; esc closes them, delete twice deletes it, and so does the arrow twice', async ($, on) => {
  const ran: string[][] = []
  engine(on, ran)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  expect((await ui.find({ in: 'lines', type: 'Text', text: /^15:40$/ }))?.text).toBe('15:40')
  expect((await ui.find({ in: 'lines', type: 'Text', text: /^Shiitake$/ }))?.props.bold).toBe(true)
  expect((await ui.find({ in: 'lines', type: 'Text', text: /^hello$/ }))?.props.dimColor).toBe(true)
  expect(await ui.find({ in: 'lines', type: 'Text', text: /\[esc\]/ })).toBeUndefined()

  await ui.pointer({ type: 'down', x: 10, y: 0, button: 'left' })
  expect((await ui.find({ in: 'lines', type: 'Text', text: /^\[delete\]$/ }))?.text).toBe('[delete]')
  expect((await ui.find({ in: 'lines', type: 'Text', text: /\[esc\]/ }))?.text).toBe(' [esc]')
  // "the word cancel isnt clear"
  await ui.pointer({ type: 'down', x: 50, y: 0, button: 'left' })
  expect(await ui.find({ in: 'lines', type: 'Text', text: /\[esc\]/ })).toBeUndefined()
  expect(ran.some(argv => argv[2] === 'cancel')).toBe(false)
  // "and there should be a more explicit abort, that is two stage abort"
  await ui.pointer({ type: 'down', x: 10, y: 0, button: 'left' })
  await ui.pointer({ type: 'down', x: 41, y: 0, button: 'left' })
  expect((await ui.find({ in: 'lines', type: 'Text', text: /^\[DELETE\]$/ }))?.props.color).toBe('red')
  expect(ran.some(argv => argv[2] === 'cancel')).toBe(false)
  await ui.pointer({ type: 'down', x: 41, y: 0, button: 'left' })
  expect(ran).toContainEqual(['ground', 'collected', 'cancel', 'did:key:z6MkMe', '871588189c2ca9c4'])
  ran.length = 0
  // The arrow at rest: once is XXXX, twice dismisses that one message.
  await ui.pointer({ type: 'down', x: 7, y: 0, button: 'left' })
  expect((await ui.find({ in: 'lines', type: 'Text', text: /^XXXX$/ }))?.text).toBe('XXXX')
  await ui.pointer({ type: 'down', x: 7, y: 0, button: 'left' })
  expect(ran).toContainEqual(['ground', 'collected', 'cancel', 'did:key:z6MkMe', '871588189c2ca9c4'])
  await ui.unmount()
})

// "[now], this means to me kind fo same thing as [delete] two stage, press once, you get [NOW] green, and press another time, it actually get's released"
test('now is pressed twice: once it is [NOW] green, and the second releases', async ($, on) => {
  const ran: string[][] = []
  engine(on, ran)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  await ui.pointer({ type: 'down', x: 10, y: 0, button: 'left' })
  await ui.pointer({ type: 'down', x: 7, y: 0, button: 'left' })
  expect((await ui.find({ in: 'lines', type: 'Text', text: /^\[NOW\]$/ }))?.props.color).toBe('green')
  expect(ran.some(argv => argv[2] === 'release')).toBe(false)
  await ui.pointer({ type: 'down', x: 7, y: 0, button: 'left' })
  expect(ran).toContainEqual(['ground', 'collected', 'release', 'did:key:z6MkMe'])
  await ui.unmount()
})

// "while its forking, you see it right there, at that moment, who to let keep the name, if you dont do anything, nothing happens, otherwise you click the other session, and it gets the name and is the active session at the same time."
test('a session that branched from this one stands as a row, and a click gives it the name', async ($, on) => {
  const ran: string[][] = []
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sid' }))
  on('clock.every', () => ({ value: {} }))
  on('process.run', (_, e) => {
    ran.push([...e.argv])
    const stdout = e.argv[1] === 'forks'
      ? '{"name":"Mycelia","here":true,"forks":[{"session":"fa8a1589-576c-4ecb-84c8-f7d0f357b448","name":"","title":"mycelia on k","holds":false}]}'
      : e.argv[2] === 'json' ? '{"incoming":[],"outbound":[]}' : ''
    return { value: { exitCode: 0, stdout, stderr: '' } }
  })
  on('clock.now', () => ({ value: 0 }))
  on('fs.write', () => ({ value: {} }))
  const resumed: string[] = []
  on('command.run', (_, e) => {
    resumed.push(`${e.command} ${e.args}`)
    return { text: '' }
  })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  const lines = await ui.find({ type: 'Client', key: 'lines' })
  expect(lines?.props.props).toEqual({ lines: [], name: 'Mycelia', here: true, forks: [{ session: 'fa8a1589-576c-4ecb-84c8-f7d0f357b448', name: '', title: 'mycelia on k', holds: false }] })
  expect((await ui.find({ in: 'lines', type: 'Text', text: /stays with/ }))?.text).toBe('⑂ Mycelia stays with  ')
  expect((await ui.find({ in: 'lines', type: 'Text', text: /● this session/ }))?.props.bold).toBe(true)
  expect((await ui.find({ in: 'lines', type: 'Text', text: /○ mycelia on k/ }))?.text).toBe('   ○ mycelia on k')
  // On the filled one: nothing moves.
  await ui.pointer({ type: 'down', x: 25, y: 0, button: 'left' })
  expect(ran.some(argv => argv[1] === 'forks' && argv[2] === 'give')).toBe(false)
  await ui.pointer({ type: 'down', x: 42, y: 0, button: 'left' })
  expect(ran).toContainEqual(['ground', 'forks', 'give', 'fa8a1589-576c-4ecb-84c8-f7d0f357b448'])
  // "and it gets the name and is the active session at the same time"
  expect(resumed).toEqual(['resume fa8a1589-576c-4ecb-84c8-f7d0f357b448'])
  await ui.unmount()
})

// "i dont thin that ux is good"
test('a branch running in the background is not given the name; what Claude Code said stands', async ($, on) => {
  const ran: string[][] = []
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sid' }))
  on('clock.every', () => ({ value: {} }))
  on('clock.now', () => ({ value: 0 }))
  on('fs.write', () => ({ value: {} }))
  on('process.run', (_, e) => {
    ran.push([...e.argv])
    const stdout = e.argv[1] === 'forks'
      ? '{"name":"Mycelia","here":true,"forks":[{"session":"fa8a1589-576c-4ecb-84c8-f7d0f357b448","name":"","title":"mycelia on k","holds":false}]}'
      : e.argv[2] === 'json' ? '{"incoming":[],"outbound":[]}' : ''
    return { value: { exitCode: 0, stdout, stderr: '' } }
  })
  on('command.run', () => ({ text: '"Granite name setup ⑂ mycelia on k" is running in the background (fa8a1589). Run `claude attach fa8a1589` to open it.' }))
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await ui.pointer({ type: 'down', x: 42, y: 0, button: 'left' })
  expect(ran.some(argv => argv[1] === 'forks' && argv[2] === 'give')).toBe(false)
  expect((await ui.find({ type: 'Text', text: /the name stays here/ }))?.text).toContain('claude attach fa8a1589')
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
