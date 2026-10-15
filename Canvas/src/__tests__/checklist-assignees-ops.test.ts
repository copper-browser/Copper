import { beforeEach, describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { CanvasStore } from '../canvas/doc'
import { applyOps, readCanvas, type Assigned, type OpsContext } from '../ops'

let store: CanvasStore
let ctx: OpsContext
let told: Assigned[]
const scout = { id: 'agent:s', name: 'Scout', color: '#123456' }
const people = [
  { id: 'u-collin', name: 'Collin Rijock', email: 'collin@example.com' },
  { id: 'u-grace', name: 'Grace Hopper', email: 'grace@example.com' },
]
const run = (ops: unknown) => applyOps(ctx, { ops, as: scout })
const readAll = (opts: unknown = {}) => readCanvas({ store, canvas: { id: 'c', name: 'B', kind: 'shared' }, viewport: null, selection: [], now: 0 }, opts).shapes
const read = (id: string) => readAll().find(s => s.id === id)!
const text = (id: string) => store.get(id)!.text

beforeEach(() => {
  store = new CanvasStore(new Y.Doc())
  told = []
  ctx = { store, viewportCenter: () => ({ x: 0, y: 0 }), people: () => people, onAssigned: e => told.push(e) }
})

describe('checklist ops: assignees', () => {
  it('adds a card with assignees: names in the text, people resolved by name or email, a name of its own otherwise', () => {
    const r = run([
      {
        op: 'add',
        shape: {
          type: 'checklist',
          id: 'sprint',
          x: 0,
          y: 0,
          title: 'Sprint',
          columns: ['To do', 'Done'],
          rows: ['Fix login', 'Notes', 'Ship'],
          picks: { 'Fix login': 'To do' },
          notes: { 'Fix login': 'Blocked' },
          assignees: { 'Fix login': ['collin@example.com', 'grace'], notes: 'Design team', Ship: [] },
        },
      },
    ])
    expect(r.errors).toEqual([])
    expect(text('sprint')).toBe('### Sprint\n- [x] Fix login · To do\n  > Blocked\n  @Collin Rijock\n  @Grace Hopper\n- [ ] Notes\n  @Design team\n- [ ] Ship')
    expect(read('sprint').rows).toEqual([
      expect.objectContaining({
        label: 'Fix login',
        pick: 'To do',
        note: 'Blocked',
        assignees: [
          { name: 'Collin Rijock', id: 'u-collin', email: 'collin@example.com' },
          { name: 'Grace Hopper', id: 'u-grace', email: 'grace@example.com' },
        ],
      }),
      { label: 'Notes', pick: null, assignees: [{ name: 'Design team' }] },
      { label: 'Ship', pick: null },
    ])
    expect(store.shapes.get('sprint')!.get('assignees:fix login')).toEqual([
      expect.objectContaining({ name: 'Collin Rijock', id: 'u-collin', by: 'Scout', byId: 'agent:s' }),
      expect.objectContaining({ name: 'Grace Hopper', id: 'u-grace' }),
    ])
    // Assignees take no room of their own: the card is as tall as without them.
    expect(store.get('sprint')!.h).toBe(49 + 28 + 34 * 3 + 22 + 14)
    expect(told.map(e => [e.shapeId, e.title, e.row, e.people.map(p => p.name)])).toEqual([
      ['sprint', 'Sprint', 'Fix login', ['Collin Rijock', 'Grace Hopper']],
      ['sprint', 'Sprint', 'Notes', ['Design team']],
    ])
  })

  it('updates by label (null clears), tells only who is new, keeps them through rows and columns rewrites, and fails cleanly', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', x: 0, y: 0, title: 'T', columns: ['Done'], rows: ['Ann', 'Bob', 'Cy'], assignees: { Bob: ['Collin Rijock'] } } }])
    told = []
    expect(run([{ op: 'update', id: 'c', patch: { assignees: { Ann: ['grace@example.com'], Bob: ['u-collin', 'Grace Hopper'] } } }]).errors).toEqual([])
    expect(text('c')).toBe('### T\n- [ ] Ann\n  @Grace Hopper\n- [ ] Bob\n  @Collin Rijock\n  @Grace Hopper\n- [ ] Cy')
    expect(told.map(e => [e.row, e.people.map(p => p.name)])).toEqual([
      ['Bob', ['Grace Hopper']],
      ['Ann', ['Grace Hopper']],
    ])
    // Collin keeps who assigned him first.
    expect(store.shapes.get('c')!.get('assignees:bob')).toEqual([expect.objectContaining({ name: 'Collin Rijock', by: 'Scout' }), expect.objectContaining({ name: 'Grace Hopper' })])
    run([{ op: 'update', id: 'c', patch: { assignees: { Ann: null } } }])
    expect(text('c')).toBe('### T\n- [ ] Ann\n- [ ] Bob\n  @Collin Rijock\n  @Grace Hopper\n- [ ] Cy')
    expect(store.shapes.get('c')!.has('assignees:ann')).toBe(false)
    // Rows replaced: each keeps its people by label, ids and all; a row that goes takes them.
    run([{ op: 'update', id: 'c', patch: { rows: ['Cy', 'bob', 'Dee'], columns: ['To do', 'Done'], title: 'New' } }])
    expect(text('c')).toBe('### New\n- [ ] Cy\n- [ ] bob\n  @Collin Rijock\n  @Grace Hopper\n- [ ] Dee')
    expect(read('c').rows![1]!.assignees).toEqual([
      { name: 'Collin Rijock', id: 'u-collin', email: 'collin@example.com' },
      { name: 'Grace Hopper', id: 'u-grace', email: 'grace@example.com' },
    ])
    // A bad assignee fails the whole update, writing nothing.
    const before = text('c')
    const bad = run([
      { op: 'update', id: 'c', patch: { title: 'X', assignees: { Zed: ['Ann'] } } },
      { op: 'update', id: 'c', patch: { assignees: { Cy: [4] } } },
      { op: 'update', id: 'c', patch: { assignees: ['Cy'] } },
      { op: 'update', id: 'c', patch: { assignees: { Cy: 'x'.split('').concat(Array(13).fill('y')) } } },
    ])
    expect(bad.errors.map(e => e.error)).toEqual([
      '`assignees`: no row "Zed"',
      '`assignees` names must be strings like "Ann" or "ann@example.com"',
      '`assignees` must be an object like {"Ann": ["Grace Hopper"]}',
      '`assignees`: at most 12 people on a row',
    ])
    expect(text('c')).toBe(before)
    // A plain note takes none.
    run([{ op: 'add', shape: { type: 'sticky', id: 'p', text: 'hi' } }])
    expect(run([{ op: 'update', id: 'p', patch: { assignees: { a: ['x'] } } }]).errors[0]!.error).toMatch(/unknown prop `assignees` for sticky/)
  })

  it('a note turned into a card keeps the @ lines it already had', () => {
    run([{ op: 'add', shape: { type: 'sticky', id: 'n', text: '### Plan\n- [ ] Ann\n  @Grace Hopper\n- [ ] Bob' } }])
    run([{ op: 'update', id: 'n', patch: { view: 'checklist' } }])
    expect(read('n').rows).toEqual([
      { label: 'Ann', pick: null, assignees: [{ name: 'Grace Hopper' }] },
      { label: 'Bob', pick: null },
    ])
  })

  it('a legacy checklist takes and reads assignees under its own key', () => {
    const id = store.create({ type: 'checklist', id: 'l', title: 'Old', columns: ['Yes', 'No'], rows: [{ id: 'r1', label: 'Ann' }] })
    expect(run([{ op: 'update', id, patch: { assignees: { Ann: ['grace'] } } }]).errors).toEqual([])
    expect(read('l').rows).toEqual([{ id: 'r1', label: 'Ann', pick: null, assignees: [{ name: 'Grace Hopper', id: 'u-grace', email: 'grace@example.com' }] }])
    expect(told.map(e => [e.shapeId, e.title, e.row])).toEqual([['l', 'Old', 'Ann']])
    run([{ op: 'update', id, patch: { assignees: { Ann: null } } }])
    expect(store.shapes.get('l')!.has('assignees:r1')).toBe(false)
  })

  it('without people (a canvas on this Mac) every name is its own', () => {
    ctx = { store, viewportCenter: () => ({ x: 0, y: 0 }) }
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', rows: ['Ann'], assignees: { Ann: ['Grace Hopper', 'me@example.com'] } } }])
    expect(read('c').rows![0]!.assignees).toEqual([{ name: 'Grace Hopper' }, { name: 'me@example.com', email: 'me@example.com' }])
  })
})
