import { beforeEach, describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { pickKey } from '../canvas/checklist'
import { CanvasStore } from '../canvas/doc'
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

describe('checklist ops (a note in the checklist view)', () => {
  it('adds a note whose text is the list, with defaults, picks and a fitted size', () => {
    const r = run([{ op: 'add', shape: { type: 'checklist', id: 'tue', x: 0, y: 0, title: 'Tue', rows: ['Ann', 'Bob', { label: 'Cy', id: 'cy' }], picks: { Ann: 'yes', Cy: 'No' } } }])
    expect(r.errors).toEqual([])
    const s = store.get('tue')!
    expect(s).toMatchObject({ type: 'sticky', view: 'checklist', title: 'Tue', columns: ['Yes', 'No'], color: 'green', w: 324, by: 'Scout' })
    expect(s.h).toBe(49 + 28 + 34 * 3 + 14)
    expect(text('tue')).toBe('### Tue\n- [x] Ann · Yes\n- [ ] Bob\n- [x] Cy · No')
    expect(store.shapes.get('tue')!.get('text')).toBeInstanceOf(Y.Text)
    // Only `columns`, `view` and who picked are props: title and rows are the text.
    const m = store.shapes.get('tue')!
    expect(m.has('title') || m.has('rows')).toBe(false)
    expect(m.get('who:cy')).toMatchObject({ col: 'No', by: 'Scout', byId: 'agent:s' })
    expect(read('tue')).toMatchObject({
      type: 'sticky',
      view: 'checklist',
      title: 'Tue',
      text: '### Tue\n- [x] Ann · Yes\n- [ ] Bob\n- [x] Cy · No',
      rows: [
        { label: 'Ann', pick: 'Yes', by: 'Scout' },
        { label: 'Bob', pick: null },
        { label: 'Cy', pick: 'No', by: 'Scout' },
      ],
      tally: { Yes: 1, No: 1 },
    })
  })

  it('takes one column as a to-do / RSVP list: plain task lines, sized narrower', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'go', title: 'Going', columns: ['Going'], rows: ['Ann', 'Ada Lovelace'], picks: { 'ada lovelace': true } } }])
    expect(text('go')).toBe('### Going\n- [ ] Ann\n- [x] Ada Lovelace')
    expect(store.get('go')).toMatchObject({ w: 280, h: 49 + 34 * 2 + 14, columns: ['Going'] })
    expect(read('go')).toMatchObject({ rows: [{ label: 'Ann', pick: null }, { label: 'Ada Lovelace', pick: 'Going', by: 'Scout' }], tally: { Going: 1 } })
  })

  it('fails the whole add on a bad pick, column or row, writing nothing', () => {
    const r = run([
      { op: 'add', shape: { type: 'checklist', rows: ['Ann'], picks: { Ann: 'Maybe' } } },
      { op: 'add', shape: { type: 'checklist', columns: ['A', 'B', 'C', 'D', 'E'] } },
      { op: 'add', shape: { type: 'checklist', rows: 'Ann' } },
      { op: 'add', shape: { type: 'checklist', rows: ['Ann'], fontSize: 20 } },
      { op: 'add', shape: { type: 'sticky', view: 'grid', text: 'x' } },
    ])
    expect(r.applied).toBe(0)
    expect(r.errors.map(e => e.index)).toEqual([0, 1, 2, 3, 4])
    expect(r.errors[0]!.error).toMatch(/no column "Maybe"/)
    expect(r.errors[3]!.error).toMatch(/unknown prop `fontSize`/)
    expect(r.errors[4]!.error).toMatch(/`view` must be "checklist" or null/)
    expect(store.shapes.size).toBe(0)
  })

  it('updates picks one line at a time without touching the others', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', title: 'T', rows: ['Ann', 'Bob', 'Cy'], picks: { Ann: 'Yes', Bob: 'No' } } }])
    const r = run([{ op: 'update', id: 'c', patch: { picks: { Ann: null, Cy: 'yes' } } }])
    expect(r.errors).toEqual([])
    expect(text('c')).toBe('### T\n- [ ] Ann\n- [x] Bob · No\n- [x] Cy · Yes')
    expect(read('c').rows!.map(r => r.pick)).toEqual([null, 'No', 'Yes'])
    expect(read('c').tally).toEqual({ Yes: 1, No: 1 })
    expect(store.shapes.get('c')!.has('who:ann')).toBe(false)
  })

  it('replaces rows keeping picks by label; columns carry picks by name and drop the rest', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', title: 'T', rows: ['Ann', 'Bob'], picks: { Ann: 'Yes', Bob: 'No' } } }])
    run([{ op: 'update', id: 'c', patch: { rows: ['Bob', 'Dee', 'Ann'], columns: ['Yes', 'No', 'Maybe'], picks: { Dee: 'maybe' } } }])
    expect(text('c')).toBe('### T\n- [x] Bob · No\n- [x] Dee · Maybe\n- [x] Ann · Yes')
    expect(store.get('c')!.columns).toEqual(['Yes', 'No', 'Maybe'])
    expect(store.get('c')!.w).toBe(14 * 2 + 168 + 64 * 3)
    run([{ op: 'update', id: 'c', patch: { columns: ['yes', 'Maybe'], rows: ['Bob', 'Dee', 'Ann'] } }])
    expect(text('c')).toBe('### T\n- [ ] Bob\n- [x] Dee · Maybe\n- [x] Ann · yes')
    expect(read('c').rows!.map(r => r.pick)).toEqual([null, 'Maybe', 'yes'])
    expect([...store.shapes.get('c')!.keys()].filter(k => k.startsWith('who:')).sort()).toEqual(['who:ann', 'who:dee'])
  })

  it('edits the title in the heading, keeping the rest of the text', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', title: 'Tue', rows: ['Ann'] } }])
    run([{ op: 'update', id: 'c', patch: { title: 'Tue dinner' } }])
    expect(text('c')).toBe('### Tue dinner\n- [ ] Ann')
    run([{ op: 'add', shape: { type: 'checklist', id: 'd', rows: ['Ann'] } }])
    expect(text('d')).toBe('- [ ] Ann')
    run([{ op: 'update', id: 'd', patch: { title: 'Wed' } }])
    expect(text('d')).toBe('### Wed\n- [ ] Ann')
  })

  it('reports update errors and leaves the note as it was', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', title: 'T', rows: ['Ann'] } }])
    const r = run([{ op: 'update', id: 'c', patch: { title: 'New', picks: { Zed: 'Yes' } } }])
    expect(r.errors[0]!.error).toMatch(/no row "Zed"/)
    expect(text('c')).toBe('### T\n- [ ] Ann')
  })

  it('caps titles at 500 and reads rows without ids (their place is their id)', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', title: 'x'.repeat(600), rows: ['Ann', 'Bob'], picks: { Bob: 'Yes' } } }])
    const s = read('c')
    expect(s.title).toHaveLength(500)
    expect(s.columns).toEqual(['Yes', 'No'])
    expect(s.rows![0]).toEqual({ label: 'Ann', pick: null })
    expect(s.rows![1]).toMatchObject({ label: 'Bob', pick: 'Yes', by: 'Scout', at: expect.any(Number) })
    expect(s).not.toHaveProperty('picks')
  })

  it('moves, resizes (with a checklist floor) and deletes like any box', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', x: 0, y: 0, rows: ['Ann'] } }])
    run([
      { op: 'move', id: 'c', dx: 10, dy: 20 },
      { op: 'resize', id: 'c', w: 50, h: 50 },
    ])
    expect(store.get('c')).toMatchObject({ x: 10, y: 20, w: 200, h: 72 })
    run([{ op: 'delete', id: 'c' }])
    expect(store.shapes.has('c')).toBe(false)
  })

  it('takes text/label as a checklist title', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', text: 'Wed dinner' } }])
    expect(store.get('c')).toMatchObject({ title: 'Wed dinner', text: '### Wed dinner' })
  })

  it('is found by types:["checklist"]', () => {
    run([
      { op: 'add', shape: { type: 'checklist', id: 'c', rows: ['Ann'] } },
      { op: 'add', shape: { type: 'sticky', id: 'n', text: 'plain' } },
    ])
    expect(readAll({ types: ['checklist'] }).map(s => s.id)).toEqual(['c'])
  })
})

describe('turning a note into a card and back', () => {
  const NOTE = '### Going\n- [ ] Ann\n- [x] Ada Lovelace\n- [x] Bob'

  it('view:"checklist" keeps the text, and its ticks, as they are', () => {
    run([{ op: 'add', shape: { type: 'sticky', id: 'n', text: NOTE, w: 200, h: 200 } }])
    const r = run([{ op: 'update', id: 'n', patch: { view: 'checklist' } }])
    expect(r.errors).toEqual([])
    expect(text('n')).toBe(NOTE)
    expect(store.get('n')).toMatchObject({ view: 'checklist', title: 'Going', columns: ['Done'], w: 280 })
    expect(read('n')).toMatchObject({
      view: 'checklist',
      rows: [
        { label: 'Ann', pick: null },
        { label: 'Ada Lovelace', pick: 'Done' },
        { label: 'Bob', pick: 'Done' },
      ],
      tally: { Done: 2 },
    })
    // An older client's tick has no who: none is made up.
    expect(read('n').rows![1]).not.toHaveProperty('by')
  })

  it('with columns, a tick without a suffix is the first column', () => {
    run([{ op: 'add', shape: { type: 'sticky', id: 'n', text: NOTE } }])
    run([{ op: 'update', id: 'n', patch: { view: 'checklist', columns: ['Yes', 'No'] } }])
    expect(text('n')).toBe(NOTE)
    expect(read('n').rows!.map(r => r.pick)).toEqual([null, 'Yes', 'Yes'])
    run([{ op: 'update', id: 'n', patch: { picks: { Bob: 'No' } } }])
    expect(text('n')).toBe('### Going\n- [ ] Ann\n- [x] Ada Lovelace\n- [x] Bob · No')
    expect(read('n').rows![2]).toMatchObject({ pick: 'No', by: 'Scout' })
  })

  it('view:null makes it a plain note again, text unchanged', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', title: 'T', rows: ['Ann'], picks: { Ann: 'No' } } }])
    run([{ op: 'update', id: 'c', patch: { view: null } }])
    expect(store.get('c')).toMatchObject({ type: 'sticky', text: '### T\n- [x] Ann · No' })
    expect(store.get('c')!.view).toBeUndefined()
    expect(read('c')).not.toHaveProperty('rows')
    const r = run([{ op: 'update', id: 'c', patch: { rows: ['Bob'] } }])
    expect(r.errors[0]!.error).toMatch(/unknown prop `rows`/)
  })
})

describe('legacy checklist shapes (type "checklist")', () => {
  const legacy = () =>
    store.create({ type: 'checklist', id: 'old', title: 'Tue', columns: ['Yes', 'No'], rows: [{ id: 'r0', label: 'Ann' }, { id: 'r1', label: 'Bob' }] })

  it('still read with ids and still take picks one row at a time', () => {
    legacy()
    const r = run([{ op: 'update', id: 'old', patch: { picks: { Ann: 'Yes' } } }])
    expect(r.errors).toEqual([])
    expect(read('old')).toMatchObject({ type: 'checklist', title: 'Tue', rows: [{ id: 'r0', label: 'Ann', pick: 'Yes', by: 'Scout' }, { id: 'r1', label: 'Bob', pick: null }] })
    expect(store.shapes.get('old')!.get(pickKey('r0'))).toMatchObject({ col: 'Yes' })
  })
})

describe('checklist ops: row comments (`notes`)', () => {
  it('adds a card with comments under their rows, attributed, and reads them back', () => {
    const r = run([
      {
        op: 'add',
        shape: {
          type: 'checklist',
          id: 'land',
          x: 0,
          y: 0,
          title: 'Where we land',
          columns: ['Yes', 'Later', 'Talk', 'No'],
          rows: ['1. Source of truth', '2. Scope'],
          picks: { '1. Source of truth': 'No' },
          notes: { '1. source of truth': "We already have InvenTree; pull, don't own.\nSecond line.", '2. Scope': '' },
        },
      },
    ])
    expect(r.errors).toEqual([])
    expect(text('land')).toBe("### Where we land\n- [x] 1. Source of truth · No\n  > We already have InvenTree; pull, don't own.\n  > Second line.\n- [ ] 2. Scope")
    expect(store.get('land')!.h).toBe(49 + 28 + 34 * 2 + 22 + 14)
    expect(store.shapes.get('land')!.get('noteBy:1. source of truth')).toMatchObject({ by: 'Scout', byId: 'agent:s' })
    expect(read('land').rows).toEqual([
      { label: '1. Source of truth', pick: 'No', by: 'Scout', at: expect.any(Number), note: "We already have InvenTree; pull, don't own.\nSecond line.", noteBy: 'Scout', noteAt: expect.any(Number) },
      { label: '2. Scope', pick: null },
    ])
  })

  it('updates comments by label (null clears), keeps them through a rows rewrite, and fails cleanly', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', x: 0, y: 0, title: 'T', rows: ['Ann', 'Bob', 'Cy'], notes: { Bob: 'b' } } }])
    const h0 = store.get('c')!.h
    expect(run([{ op: 'update', id: 'c', patch: { notes: { Ann: 'a\nmore', Bob: null } } }]).errors).toEqual([])
    expect(text('c')).toBe('### T\n- [ ] Ann\n  > a\n  > more\n- [ ] Bob\n- [ ] Cy')
    expect(store.shapes.get('c')!.has('noteBy:bob')).toBe(false)
    expect(store.get('c')!.h).toBe(h0)
    run([{ op: 'update', id: 'c', patch: { notes: { Cy: 'c' } } }])
    expect(store.get('c')!.h).toBe(h0 + 22)
    // Rows replaced: each keeps its comment by label; a row that goes takes its comment.
    run([{ op: 'update', id: 'c', patch: { rows: ['Cy', 'Dee', 'ann'], picks: { Dee: 'No' } } }])
    expect(text('c')).toBe('### T\n- [ ] Cy\n  > c\n- [x] Dee · No\n- [ ] ann\n  > a\n  > more')
    expect(store.shapes.get('c')!.has('noteBy:cy')).toBe(true)
    // A bad comment fails the whole update, writing nothing.
    const before = text('c')
    const bad = run([
      { op: 'update', id: 'c', patch: { title: 'New', notes: { Zed: 'x' } } },
      { op: 'update', id: 'c', patch: { notes: { Cy: 4 } } },
      { op: 'update', id: 'c', patch: { notes: 'Cy' } },
    ])
    expect(bad.errors.map(e => e.error)).toEqual(['`notes`: no row "Zed"', '`notes` values must be text or null', '`notes` must be an object like {"Ann": "Back at 6"}'])
    expect(text('c')).toBe(before)
    // A plain note takes no comments; `text` and `notes` on an add is one too many.
    run([{ op: 'add', shape: { type: 'sticky', id: 'p', text: 'hi' } }])
    const plain = run([
      { op: 'update', id: 'p', patch: { notes: { a: 'x' } } },
      { op: 'add', shape: { type: 'sticky', view: 'checklist', text: '- [ ] a', notes: { a: 'x' } } },
    ])
    expect(plain.errors.map(e => e.error)).toEqual([expect.stringMatching(/unknown prop `notes` for sticky/), 'give the note `text`, or `title`/`rows`/`picks`/`notes`, not both'])
  })

  it('clips a long comment in a read unless full', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', rows: ['Ann'], notes: { Ann: 'x'.repeat(900) } } }])
    expect(read('c').rows![0]!.note).toHaveLength(501)
    expect(readAll({ full: true }).find(s => s.id === 'c')!.rows![0]!.note).toHaveLength(900)
  })

  it('a legacy checklist takes comments too, under note:<rowId>', () => {
    store.create({ type: 'checklist', id: 'old', title: 'Old', columns: ['Yes', 'No'], rows: [{ id: 'a', label: 'Ann' }, { id: 'b', label: 'Bob' }] })
    expect(run([{ op: 'update', id: 'old', patch: { notes: { Ann: 'hi', b: 'yo' } } }]).errors).toEqual([])
    expect(store.shapes.get('old')!.get('note:a')).toMatchObject({ text: 'hi', by: 'Scout' })
    expect(read('old').rows).toMatchObject([
      { id: 'a', label: 'Ann', pick: null, note: 'hi', noteBy: 'Scout' },
      { id: 'b', label: 'Bob', pick: null, note: 'yo' },
    ])
    run([{ op: 'update', id: 'old', patch: { rows: [{ id: 'a', label: 'Ann' }], notes: { Ann: null } } }])
    expect(store.shapes.get('old')!.has('note:a') || store.shapes.get('old')!.has('note:b')).toBe(false)
  })
})
