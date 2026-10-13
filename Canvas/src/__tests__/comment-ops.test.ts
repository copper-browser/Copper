import { beforeEach, describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { CanvasStore, LOCAL } from '../canvas/doc'
import { applyOps, readCanvas, READ_TEXT_LIMIT, type OpsContext } from '../ops'

let store: CanvasStore
let ctx: OpsContext
const scout = { id: 'agent:s', name: 'Scout', color: '#123456' }
const run = (ops: unknown) => applyOps(ctx, { ops, as: scout })
const read = (opts: unknown = {}) =>
  readCanvas({ store, canvas: { id: 'c', name: 'B', kind: 'shared' }, viewport: { x: 0, y: 0, w: 1000, h: 800, zoom: 1 }, selection: [], now: 0 }, opts)

beforeEach(() => {
  store = new CanvasStore(new Y.Doc())
  ctx = { store, viewportCenter: () => ({ x: 0, y: 0 }) }
  run([
    { op: 'add', shape: { type: 'frame', id: 'orb', x: 0, y: 0, w: 1600, h: 900, title: 'The Orb — slide 3' } },
    { op: 'add', shape: { type: 'sticky', id: 'far', x: 5000, y: 5000, text: 'far away' } },
  ])
})

describe('comment ops', () => {
  it('starts a thread on a shape, attributed to the agent, and returns its id', () => {
    const r = run([{ op: 'comment', on: 'orb', text: 'The numbers on this slide are from Q2.' }])
    expect(r.errors).toEqual([])
    expect(r.applied).toBe(1)
    const id = r.ids[0]!
    expect(typeof id).toBe('string')
    const t = store.comments.get(id)!
    expect(t).toMatchObject({ anchor: 'orb', anchorName: 'The Orb — slide 3', by: 'Scout', byId: 'agent:s', resolved: false })
    expect(t.messages[0]).toMatchObject({ by: 'Scout', byId: 'agent:s', text: 'The numbers on this slide are from Q2.' })
    // Comments are never on the undo stack.
    expect(store.undo.undoStack.length).toBeGreaterThan(0)
    const before = store.undo.undoStack.length
    run([{ op: 'reply', thread: id, text: 'More' }])
    expect(store.undo.undoStack.length).toBe(before)
  })

  it('replies and resolves by thread id, and reopens', () => {
    const id = run([{ op: 'comment', on: 'orb', text: 'Check this', id: 'th1' }]).ids[0]!
    expect(id).toBe('th1')
    const r = run([
      { op: 'reply', thread: 'th1', text: 'Checked: fine.' },
      { op: 'resolve', thread: 'th1' },
    ])
    expect(r.errors).toEqual([])
    expect(r.ids).toEqual(['th1', 'th1'])
    expect(store.comments.get('th1')).toMatchObject({ resolved: true, resolvedBy: 'Scout' })
    expect(store.comments.get('th1')!.messages.map(m => m.text)).toEqual(['Check this', 'Checked: fine.'])
    run([{ op: 'resolve', thread: 'th1', resolved: false }])
    expect(store.comments.get('th1')!.resolved).toBe(false)
  })

  it('a comment and the shape it is on can be made in one call', () => {
    const r = run([
      { op: 'add', shape: { type: 'frame', id: 'new', x: 0, y: 1200, w: 1600, h: 900, title: 'Slide 4' } },
      { op: 'comment', on: 'new', text: 'Draft — fill in' },
    ])
    expect(r.errors).toEqual([])
    expect(store.comments.get(r.ids[1]!)!.anchor).toBe('new')
  })

  it('a thread can be started, replied to and resolved in one call', () => {
    const r = run([
      { op: 'comment', on: 'orb', text: 'Start', id: 'one-go' },
      { op: 'reply', thread: 'one-go', text: 'Then' },
      { op: 'resolve', thread: 'comment:one-go' },
    ])
    expect(r.errors).toEqual([])
    expect(store.comments.get('one-go')).toMatchObject({ resolved: true })
    expect(store.comments.get('one-go')!.messages.map(m => m.text)).toEqual(['Start', 'Then'])
    expect(read().comments.find(c => c.id === 'one-go')!.messages).toHaveLength(2)
  })

  it('reports bad comment ops and still applies the rest', () => {
    const r = run([
      { op: 'comment', on: 'nope', text: 'x' },
      { op: 'comment', text: 'x' },
      { op: 'comment', on: 'orb', text: '   ' },
      { op: 'reply', thread: 'missing', text: 'x' },
      { op: 'resolve', thread: 'missing' },
      { op: 'comment', on: 'orb', text: 'fine' },
    ])
    expect(r.applied).toBe(1)
    expect(r.errors.map(e => e.index)).toEqual([0, 1, 2, 3, 4])
    expect(r.errors[0]!.error).toMatch(/no shape nope/)
    expect(r.errors[1]!.error).toMatch(/needs `on`/)
    expect(r.errors[2]!.error).toMatch(/empty/)
    expect(r.errors[3]!.error).toMatch(/no comment thread missing/)
    const bad = run([{ op: 'resolve', thread: r.ids[5], resolved: 'yes' }])
    expect(bad.errors[0]!.error).toMatch(/true or false/)
  })

  it('an id already taken is refused', () => {
    run([{ op: 'comment', on: 'orb', text: 'one', id: 'dup' }])
    const r = run([{ op: 'comment', on: 'orb', text: 'two', id: 'dup' }])
    expect(r.errors[0]!.error).toMatch(/already exists/)
  })
})

describe('canvas_read comments', () => {
  it('lists threads with their messages, deleted ones left out, texts clipped unless full', () => {
    const id = run([{ op: 'comment', on: 'orb', text: 'y'.repeat(800) }]).ids[0]!
    const human = { id: 'u-1', name: 'Felipe' }
    const mine = store.comments.reply(id, 'gone soon', human)
    store.comments.reply(id, 'stays', human)
    store.comments.remove(id, mine, human)
    const r = read()
    expect(r.comments).toHaveLength(1)
    const c = r.comments[0]!
    expect(c).toMatchObject({ id, anchor: 'orb', resolved: false })
    expect(c.messages.map(m => m.by)).toEqual(['Scout', 'Felipe'])
    expect(c.messages[0]!.text).toHaveLength(READ_TEXT_LIMIT + 1)
    expect(c.messages[1]).toMatchObject({ text: 'stays' })
    expect(read({ full: true }).comments[0]!.messages[0]!.text).toHaveLength(800)
  })

  it('keeps threads whose shape was deleted, marked as such', () => {
    const id = run([{ op: 'comment', on: 'far', text: 'Why is this here?' }]).ids[0]!
    store.remove(['far'], LOCAL)
    const c = read().comments.find(x => x.id === id)!
    expect(c).toMatchObject({ anchor: 'far', anchorDeleted: true })
  })

  it('with a filter, only threads on the shapes returned', () => {
    const a = run([{ op: 'comment', on: 'orb', text: 'near' }]).ids[0]!
    run([{ op: 'comment', on: 'far', text: 'far' }])
    expect(read({ ids: ['orb'] }).comments.map(c => c.id)).toEqual([a])
    expect(read({ inView: true }).comments.map(c => c.id)).toEqual([a])
    expect(read().comments).toHaveLength(2)
  })

  it('says who resolved a thread', () => {
    const id = run([{ op: 'comment', on: 'orb', text: 'x' }]).ids[0]!
    store.comments.setResolved(id, true, { id: 'u-2', name: 'Collin' })
    expect(read().comments[0]).toMatchObject({ resolved: true, resolvedBy: 'Collin' })
  })

  it('an empty board reads no comments', () => {
    expect(read().comments).toEqual([])
  })
})
