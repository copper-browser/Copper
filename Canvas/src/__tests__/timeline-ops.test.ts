import { beforeEach, describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { CanvasStore } from '../canvas/doc'
import { addItem, editItem, neededHeight, refOf, removeItem, setRange, setTimelineTitle } from '../canvas/timeline'
import { boardSearchItems } from '../canvas/search'
import { applyOps, readCanvas, type OpsContext } from '../ops'

let store: CanvasStore
let ctx: OpsContext
const scout = { id: 'agent:s', name: 'Scout', color: '#123456' }
const run = (ops: unknown) => applyOps(ctx, { ops, as: scout })
const readAll = (opts: unknown = {}) => readCanvas({ store, canvas: { id: 'c', name: 'B', kind: 'shared' }, viewport: null, selection: [], now: 0 }, opts).shapes
const read = (id: string) => readAll().find(s => s.id === id)!
const text = (id: string) => store.get(id)!.text

beforeEach(() => {
  store = new CanvasStore(new Y.Doc())
  ctx = { store, viewportCenter: () => ({ x: 0, y: 0 }) }
})

const Q4 = {
  op: 'add',
  shape: {
    type: 'timeline',
    id: 'q4',
    x: 0,
    y: 0,
    title: 'Q4 launch',
    start: '2026-10-01',
    end: '2026-12-31',
    step: 'week',
    items: [
      { date: '2026-11-18', label: 'Launch review', text: 'Bring the **numbers**', color: 'Purple' },
      { date: '2026-10-14', label: 'Kickoff' },
      { date: '2026-10-20', end: '2026-11-03', label: 'Build sprint', color: 'blue' },
    ],
  },
}

describe('timeline ops (a note in the timeline view)', () => {
  it('adds a note whose text is the timeline, in date order', () => {
    const r = run([Q4])
    expect(r.errors).toEqual([])
    const s = store.get('q4')!
    expect(s).toMatchObject({ type: 'sticky', view: 'timeline', title: 'Q4 launch', color: 'white', w: 880, by: 'Scout' })
    expect(s.h).toBeGreaterThanOrEqual(300)
    expect(text('q4')).toBe(
      [
        '### Q4 launch',
        '2026-10-01 → 2026-12-31 · weekly',
        '',
        '- 2026-10-14 · Kickoff',
        '- 2026-10-20 → 2026-11-03 · Build sprint · blue',
        '- 2026-11-18 · Launch review · purple',
        '  > Bring the **numbers**',
      ].join('\n')
    )
    // Only `view` is a prop: the title, range and items are the text.
    const m = store.shapes.get('q4')!
    expect(m.get('text')).toBeInstanceOf(Y.Text)
    expect(m.has('title') || m.has('timeline') || m.has('items')).toBe(false)
    expect(read('q4')).toMatchObject({
      type: 'sticky',
      view: 'timeline',
      title: 'Q4 launch',
      start: '2026-10-01',
      end: '2026-12-31',
      step: 'week',
      items: [
        { date: '2026-10-14', label: 'Kickoff', kind: 'note' },
        { date: '2026-10-20', end: '2026-11-03', label: 'Build sprint', color: 'blue', kind: 'section' },
        { date: '2026-11-18', label: 'Launch review', text: 'Bring the **numbers**', color: 'purple', kind: 'bubble' },
      ],
    })
    expect(read('q4').items![0]).not.toHaveProperty('text')
    expect(readAll({ types: ['timeline'] }).map(s => s.id)).toEqual(['q4'])
  })

  it('fills in the range and a step from the items, and a title', () => {
    run([{ op: 'add', shape: { type: 'timeline', id: 't', items: [{ date: '2027-01-05', label: 'A' }, { date: '2027-01-20', label: 'B' }] } }])
    expect(text('t').split('\n').slice(0, 2)).toEqual(['### Timeline', '2027-01-05 → 2027-01-20 · daily'])
    run([{ op: 'add', shape: { type: 'sticky', view: 'timeline', id: 'u', title: 'Year', start: '2026-01-01', end: '2027-12-31' } }])
    expect(text('u')).toBe('### Year\n2026-01-01 → 2027-12-31 · monthly')
    run([{ op: 'add', shape: { type: 'timeline', id: 'v', text: '### Raw\n2026-01-01 → 2026-02-01 · daily' } }])
    expect(store.get('v')).toMatchObject({ view: 'timeline', title: 'Raw' })
  })

  it('refuses bad dates, steps, colours and items, writing nothing', () => {
    const bad = [
      { start: '2026-13-01' },
      { step: 'fortnight' },
      { items: [{ label: 'no date' }] },
      { items: [{ date: '2026-01-01', color: 'teal' }] },
      { items: 'x' },
      { text: '### T', title: 'T' },
      { editItems: { a: null } },
    ]
    for (const extra of bad) {
      const r = run([{ op: 'add', shape: { type: 'timeline', ...extra } }])
      expect(r.errors, JSON.stringify(extra)).toHaveLength(1)
    }
    expect(store.getShapes().size).toBe(0)
  })

  it('updates the title, range, step and whole list, each in its own lines', () => {
    run([Q4])
    const r = run([
      { op: 'update', id: 'q4', patch: { title: 'Q4', end: '2027-01-31', step: 'month' } },
      { op: 'update', id: 'q4', patch: { items: [{ date: '2026-12-01', label: 'Only' }] } },
    ])
    expect(r.errors).toEqual([])
    expect(text('q4')).toBe('### Q4\n2026-10-01 → 2027-01-31 · monthly\n\n- 2026-12-01 · Only')
  })

  it('adds, changes and removes single items by name', () => {
    run([Q4])
    const r = run([
      {
        op: 'update',
        id: 'q4',
        patch: {
          addItems: [{ date: '2026-10-25', label: 'Demo', kind: 'bubble' }],
          editItems: {
            kickoff: { label: 'Kick-off', color: 'green' },
            '2026-10-20 · Build sprint': { end: '2026-11-10' },
            'Launch review': { text: null },
          },
        },
      },
    ])
    expect(r.errors).toEqual([])
    expect(read('q4').items).toEqual([
      { date: '2026-10-14', label: 'Kick-off', color: 'green', kind: 'note' },
      { date: '2026-10-20', end: '2026-11-10', label: 'Build sprint', color: 'blue', kind: 'section' },
      { date: '2026-10-25', label: 'Demo', text: '', kind: 'bubble' },
      { date: '2026-11-18', label: 'Launch review', color: 'purple', kind: 'note' },
    ])
    // A date names its first item; an index works too; null removes.
    run([{ op: 'update', id: 'q4', patch: { editItems: { '2026-10-25': { date: '2026-12-20' }, '0': null } } }])
    expect(read('q4').items!.map(i => i.label)).toEqual(['Build sprint', 'Launch review', 'Demo'])
  })

  it('writes none of an update whose item names miss', () => {
    run([Q4])
    const before = text('q4')
    const r = run([{ op: 'update', id: 'q4', patch: { title: 'Changed', editItems: { Kickoff: null, Nope: { label: 'x' } } } }])
    expect(r.errors[0]!.error).toMatch(/no item "Nope"/)
    expect(text('q4')).toBe(before)
  })

  it('turns a note into a timeline and back, its text untouched', () => {
    run([{ op: 'add', shape: { type: 'sticky', id: 'n', text: '### Plan\n2026-01-01 → 2026-03-31 · weekly\n\n- 2026-02-01 · Mid' } }])
    expect(run([{ op: 'update', id: 'n', patch: { view: 'timeline' } }]).errors).toEqual([])
    expect(store.get('n')).toMatchObject({ view: 'timeline', title: 'Plan', w: 880 })
    expect(store.get('n')!.timeline!.items.map(i => i.label)).toEqual(['Mid'])
    run([{ op: 'update', id: 'n', patch: { view: null } }])
    const s = store.get('n')!
    expect(s.view).toBeUndefined()
    expect(s.text).toBe('### Plan\n2026-01-01 → 2026-03-31 · weekly\n\n- 2026-02-01 · Mid')
    expect(run([{ op: 'update', id: 'n', patch: { start: '2026-01-01' } }]).errors[0]!.error).toMatch(/view:"timeline"/)
    // A timeline can become a checklist card, and the other way round.
    run([{ op: 'update', id: 'n', patch: { view: 'timeline' } }])
    run([{ op: 'update', id: 'n', patch: { view: 'checklist' } }])
    expect(store.get('n')!.view).toBe('checklist')
    run([{ op: 'update', id: 'n', patch: { view: 'timeline' } }])
    expect(store.get('n')!.view).toBe('timeline')
  })

  it('keeps a resize above the least the content needs', () => {
    run([Q4])
    run([{ op: 'resize', id: 'q4', w: 100, h: 50 }])
    expect(store.get('q4')).toMatchObject({ w: 360 })
    expect(store.get('q4')!.h).toBe(Math.ceil(neededHeight(text('q4'), 360)))
    expect(store.get('q4')!.h).toBeGreaterThan(160)
  })

  it('is found by its title and items, not its markup', () => {
    run([Q4])
    const items = boardSearchItems(store.getShapes().values())
    expect(items).toHaveLength(1)
    expect(items[0]).toMatchObject({ kind: 'timeline' })
    expect(items[0]!.text).toBe('Q4 launch\nKickoff\nBuild sprint\nLaunch review\nBring the **numbers**')
  })
})

describe('timeline edits from the card', () => {
  it('each edit is one undo step, and finds its item again after a peer moved it', () => {
    run([Q4])
    store.undo.clear()
    const s = () => store.get('q4')!.timeline!
    const kickoff = refOf(s().items[0]!)
    addItem(store, 'q4', { date: '2026-10-01', label: 'Prep' })
    store.undo.stopCapturing()
    // The item is now at index 1: the stale ref still finds it by what it was.
    expect(editItem(store, 'q4', kickoff, { label: 'Kick-off', body: 'Agenda' })).toBe(1)
    store.undo.stopCapturing()
    expect(s().items[1]).toMatchObject({ label: 'Kick-off', kind: 'bubble', body: 'Agenda' })
    setTimelineTitle(store, 'q4', 'Renamed')
    store.undo.stopCapturing()
    setRange(store, 'q4', { start: '2027-01-01', end: '2026-09-01', step: 'day' })
    store.undo.stopCapturing()
    expect(s()).toMatchObject({ start: '2026-09-01', end: '2027-01-01', step: 'day' })
    expect(removeItem(store, 'q4', refOf(s().items[0]!))).toBe(true)
    expect(removeItem(store, 'q4', { index: 0, date: '2020-01-01', end: null, label: 'gone' })).toBe(false)
    store.undo.undo()
    expect(s().items[0]!.label).toBe('Prep')
    store.undo.undo()
    expect(store.get('q4')!.title).toBe('Renamed')
    store.undo.undo()
    store.undo.undo()
    expect(s().items[1]).toMatchObject({ label: 'Kickoff', kind: 'note' })
  })
})
