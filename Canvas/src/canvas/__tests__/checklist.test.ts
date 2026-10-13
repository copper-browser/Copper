import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import {
  addColumn,
  addRow,
  ago,
  checklistText,
  cleanColumns,
  cleanNotes,
  cleanPicks,
  cleanRows,
  nextColumnLabel,
  noteKey,
  pickKey,
  readColumns,
  readRows,
  removeColumn,
  removeRow,
  renameColumn,
  setRowLabel,
  setRowNote,
  summarizeChecklist,
  tally,
  togglePick,
} from '../checklist'
import { CanvasStore, HOST, LOCAL } from '../doc'
import { boardSearchItems } from '../search'

const ann = { name: 'Ann', id: 'u-ann' }
const bob = { name: 'Bob', id: 'u-bob' }

function board(rows = ['Ann', 'Bob', 'Cy']) {
  const store = new CanvasStore(new Y.Doc())
  const id = store.create({
    type: 'checklist',
    id: 'c',
    title: 'Dinner Tue',
    columns: ['Yes', 'No'],
    rows: rows.map((label, i) => ({ id: `r${i}`, label })),
  })
  return { store, id }
}

/** Two replicas of one doc that exchange updates only when told to. */
function pair() {
  const a = board()
  const b = new CanvasStore(new Y.Doc())
  Y.applyUpdate(b.doc, Y.encodeStateAsUpdate(a.store.doc), HOST)
  const sync = () => {
    const ua = Y.encodeStateAsUpdate(a.store.doc, Y.encodeStateVector(b.doc))
    const ub = Y.encodeStateAsUpdate(b.doc, Y.encodeStateVector(a.store.doc))
    Y.applyUpdate(b.doc, ua, HOST)
    Y.applyUpdate(a.store.doc, ub, HOST)
  }
  return { a: a.store, b, id: a.id, sync }
}

describe('checklist reads', () => {
  it('reads columns, rows and picks tolerantly', () => {
    expect(readColumns(undefined)).toEqual(['Yes', 'No'])
    expect(readColumns(['Yes', 'yes', '', 3, 'No', 'Maybe', 'Later', 'Never'])).toEqual(['Yes', 'No', 'Maybe', 'Later'])
    expect(readRows([{ id: 'a', label: 'A' }, { id: 'a', label: 'dup' }, { label: 'no id' }, 'str', { id: 'b' }])).toEqual([
      { id: 'a', label: 'A' },
      { id: 'b', label: '' },
    ])
    const { store, id } = board()
    store.shapes.get(id)!.set(pickKey('r0'), { col: 'Yes', by: 'Ann', byId: 'u', at: 5 })
    store.shapes.get(id)!.set(pickKey('r1'), { col: 'Gone', by: 'Ann', byId: 'u', at: 5 })
    store.shapes.get(id)!.set(pickKey('zz'), { col: 'Yes', by: 'Ann', byId: 'u', at: 5 })
    const s = store.get(id)!
    expect(s).toMatchObject({ type: 'checklist', title: 'Dinner Tue', columns: ['Yes', 'No'], color: 'green' })
    expect(Object.keys(s.picks!)).toEqual(['r0'])
    expect(tally(s.columns!, s.rows!, s.picks!)).toEqual({ Yes: 1, No: 0 })
  })
})

describe('checklist writes', () => {
  it('toggles one row: pick, switch, clear, with who and when', () => {
    const { store, id } = board()
    togglePick(store, id, 'r0', 'Yes', ann)
    expect(store.get(id)!.picks!.r0).toMatchObject({ col: 'Yes', by: 'Ann', byId: 'u-ann' })
    togglePick(store, id, 'r0', 'No', bob)
    expect(store.get(id)!.picks!.r0).toMatchObject({ col: 'No', by: 'Bob' })
    togglePick(store, id, 'r0', 'No', bob)
    expect(store.get(id)!.picks!.r0).toBeUndefined()
    expect(store.shapes.get(id)!.has(pickKey('r0'))).toBe(false)
    // Unknown rows and columns change nothing.
    togglePick(store, id, 'nope', 'Yes', ann)
    togglePick(store, id, 'r1', 'Maybe', ann)
    expect(store.get(id)!.picks).toEqual({})
  })

  it('is undoable as one step per click', () => {
    const { store, id } = board()
    store.undo.clear()
    togglePick(store, id, 'r1', 'Yes', ann)
    store.undo.stopCapturing()
    togglePick(store, id, 'r2', 'No', ann)
    store.undo.undo()
    expect(Object.keys(store.get(id)!.picks!)).toEqual(['r1'])
    store.undo.undo()
    expect(store.get(id)!.picks).toEqual({})
  })

  it('two people clicking different rows at once both stick', () => {
    const { a, b, id, sync } = pair()
    togglePick(a, id, 'r0', 'Yes', ann)
    togglePick(b, id, 'r1', 'No', bob)
    sync()
    for (const s of [a, b]) {
      const picks = s.get(id)!.picks!
      expect(picks.r0).toMatchObject({ col: 'Yes', by: 'Ann' })
      expect(picks.r1).toMatchObject({ col: 'No', by: 'Bob' })
    }
  })

  it('a pick racing a label edit on another row both stick', () => {
    const { a, b, id, sync } = pair()
    togglePick(a, id, 'r2', 'Yes', ann)
    setRowLabel(b, id, 'r0', 'Ann (+1)')
    sync()
    for (const s of [a, b]) {
      expect(s.get(id)!.rows![0]!.label).toBe('Ann (+1)')
      expect(s.get(id)!.picks!.r2?.col).toBe('Yes')
    }
  })

  it('adds, labels and removes rows; a removed row takes its pick', () => {
    const { store, id } = board()
    togglePick(store, id, 'r1', 'Yes', ann)
    const fresh = addRow(store, id, 'r0', 'Dee')!
    expect(store.get(id)!.rows!.map(r => r.label)).toEqual(['Ann', 'Dee', 'Bob', 'Cy'])
    setRowLabel(store, id, fresh, 'Dee + 1')
    expect(store.get(id)!.rows![1]).toEqual({ id: fresh, label: 'Dee + 1' })
    removeRow(store, id, 'r1')
    expect(store.get(id)!.rows!.map(r => r.label)).toEqual(['Ann', 'Dee + 1', 'Cy'])
    expect(store.shapes.get(id)!.has(pickKey('r1'))).toBe(false)
  })

  it('renaming a column carries its picks; removing one drops them; four at most', () => {
    const { store, id } = board()
    togglePick(store, id, 'r0', 'Yes', ann)
    togglePick(store, id, 'r1', 'No', ann)
    expect(renameColumn(store, id, 0, 'Going')).toBe(true)
    expect(renameColumn(store, id, 1, 'going')).toBe(false)
    expect(renameColumn(store, id, 1, '  ')).toBe(false)
    expect(store.get(id)!.columns).toEqual(['Going', 'No'])
    expect(store.get(id)!.picks!.r0?.col).toBe('Going')
    expect(addColumn(store, id)).toBe(2)
    expect(store.get(id)!.columns).toEqual(['Going', 'No', 'Option 3'])
    expect(addColumn(store, id, 'Late')).toBe(3)
    expect(addColumn(store, id, 'Too many')).toBe(-1)
    removeColumn(store, id, 1)
    expect(store.get(id)!.columns).toEqual(['Going', 'Option 3', 'Late'])
    expect(store.get(id)!.picks!.r1).toBeUndefined()
    expect(store.shapes.get(id)!.has(pickKey('r1'))).toBe(false)
    expect(store.get(id)!.picks!.r0?.col).toBe('Going')
  })

  it('never removes the last column', () => {
    const store = new CanvasStore(new Y.Doc())
    const id = store.create({ type: 'checklist', columns: ['Done'], rows: [] }, LOCAL)
    removeColumn(store, id, 0)
    expect(store.get(id)!.columns).toEqual(['Done'])
  })

  it('suggests Maybe after Yes / No, else Option N', () => {
    expect(nextColumnLabel(['Yes', 'No'])).toBe('Maybe')
    expect(nextColumnLabel(['Yes', 'No', 'Maybe'])).toBe('Option 4')
    expect(nextColumnLabel(['Done'])).toBe('Option 2')
  })
})

describe('checklist input', () => {
  it('cleans columns', () => {
    expect(cleanColumns([' Yes ', 'No'])).toEqual(['Yes', 'No'])
    expect(cleanColumns(['x'.repeat(60)])[0]).toHaveLength(40)
    expect(() => cleanColumns([])).toThrow(/1 to 4/)
    expect(() => cleanColumns(['a', 'b', 'c', 'd', 'e'])).toThrow(/1 to 4/)
    expect(() => cleanColumns(['Yes', 'yes'])).toThrow(/twice/)
    expect(() => cleanColumns(['Yes', ''])).toThrow(/non-empty/)
  })

  it('cleans rows, keeping ids by id or label', () => {
    const existing = [
      { id: 'a', label: 'Ann' },
      { id: 'b', label: 'Bob' },
    ]
    const rows = cleanRows(['Bob', { label: 'Ann', id: 'a' }, 'Cy', { text: 'Dee' }], existing)
    expect(rows.map(r => r.label)).toEqual(['Bob', 'Ann', 'Cy', 'Dee'])
    expect(rows[0]!.id).toBe('b')
    expect(rows[1]!.id).toBe('a')
    expect(new Set(rows.map(r => r.id)).size).toBe(4)
    expect(() => cleanRows('Ann')).toThrow(/list/)
    expect(() => cleanRows(Array.from({ length: 61 }, (_, i) => `p${i}`))).toThrow(/60/)
    expect(() => cleanRows([{ label: 'x', id: 'bad id!' }])).toThrow(/id/)
    expect(() => cleanRows([{ label: 'x', id: 'a' }, { label: 'y', id: 'a' }])).toThrow(/twice/)
  })

  it('cleans picks by row id or label and column in any case', () => {
    const rows = [
      { id: 'a', label: 'Ann' },
      { id: 'b', label: 'Bob' },
      { id: 'c', label: 'bob' },
    ]
    expect(cleanPicks({ a: 'yes', Bob: 'No', c: null }, rows, ['Yes', 'No'])).toEqual([
      ['a', 'Yes'],
      ['b', 'No'],
      ['c', null],
    ])
    expect(cleanPicks({ ann: true }, rows, ['Done'])).toEqual([['a', 'Done']])
    expect(() => cleanPicks({ BOB: 'Yes' }, rows, ['Yes'])).toThrow(/more than one/)
    expect(() => cleanPicks({ Zed: 'Yes' }, rows, ['Yes'])).toThrow(/no row/)
    expect(() => cleanPicks({ Ann: 'Maybe' }, rows, ['Yes', 'No'])).toThrow(/no column/)
    expect(() => cleanPicks(['Ann'], rows, ['Yes'])).toThrow(/object/)
  })
})

describe('checklist text, search and time', () => {
  it('copies as text: rows with picks, or task boxes for one column', () => {
    const rows = [
      { id: 'a', label: 'Ann' },
      { id: 'b', label: 'Bob' },
    ]
    const picks = { a: { col: 'Yes', by: 'Ann', byId: '', at: 0 } }
    expect(checklistText('Tue', rows, picks, ['Yes', 'No'])).toBe('Tue\n- Ann: Yes\n- Bob')
    expect(checklistText('', rows, { a: { ...picks.a, col: 'Done' } }, ['Done'])).toBe('- [x] Ann\n- [ ] Bob')
  })

  it('is found by its title and its rows', () => {
    const { store, id } = board(['Ada Lovelace', 'Grace Hopper'])
    const items = boardSearchItems([store.get(id)!])
    expect(items).toHaveLength(1)
    expect(items[0]).toMatchObject({ ref: id, kind: 'checklist' })
    expect(JSON.stringify(items[0])).toContain('Grace Hopper')
  })

  it('says when, briefly', () => {
    const now = 1_000_000_000_000
    expect(ago(now - 10_000, now)).toBe('just now')
    expect(ago(now - 4 * 60_000, now)).toBe('4 min ago')
    expect(ago(now - 3 * 3_600_000, now)).toBe('3 h ago')
    expect(ago(now - 26 * 3_600_000, now)).toBe('yesterday')
    expect(ago(0, now)).toBe('')
  })
})

describe("a legacy card's row comments", () => {
  it('sit under note:<rowId>, one per row, with who and when; a removed row takes its comment', () => {
    const { store, id } = board()
    setRowNote(store, id, 'r1', 'vegan\r\nno nuts', ann)
    expect(store.shapes.get(id)!.get(noteKey('r1'))).toMatchObject({ text: 'vegan\nno nuts', by: 'Ann', byId: 'u-ann' })
    expect(store.get(id)!.notes).toEqual({ r1: expect.objectContaining({ text: 'vegan\nno nuts', by: 'Ann' }) })
    setRowNote(store, id, 'r9', 'no such row', ann)
    expect(store.shapes.get(id)!.has(noteKey('r9'))).toBe(false)
    removeRow(store, id, 'r1')
    expect(store.shapes.get(id)!.has(noteKey('r1'))).toBe(false)
    setRowNote(store, id, 'r0', 'x', ann)
    setRowNote(store, id, 'r0', '', ann)
    expect(store.shapes.get(id)!.has(noteKey('r0'))).toBe(false)
  })

  it('two people commenting on different rows at once both stick', () => {
    const { a, b, id, sync } = pair()
    setRowNote(a, id, 'r0', 'from a', ann)
    setRowNote(b, id, 'r2', 'from b', bob)
    sync()
    for (const s of [a, b]) expect(Object.entries(s.get(id)!.notes!).map(([k, n]) => [k, n.text])).toEqual([
      ['r0', 'from a'],
      ['r2', 'from b'],
    ])
  })

  it('reads, copies and searches with them; agents name rows by label', () => {
    const { store, id } = board()
    setRowNote(store, id, 'r0', 'late', ann)
    const s = store.get(id)!
    const sum = summarizeChecklist(s.columns!, s.rows!, s.picks!, s.notes!)
    expect(sum.rows[0]).toMatchObject({ id: 'r0', label: 'Ann', pick: null, note: 'late', noteBy: 'Ann' })
    expect(sum.rows[1]).toEqual({ id: 'r1', label: 'Bob', pick: null })
    expect(checklistText(s.title, s.rows!, s.picks!, s.columns!, s.notes!)).toBe('Dinner Tue\n- Ann\n  > late\n- Bob\n- Cy')
    expect(JSON.stringify(boardSearchItems([s])[0])).toContain('late')
    expect(cleanNotes({ ann: 'x\r\ny', Bob: null, r2: '' }, s.rows!)).toEqual([
      ['r0', 'x\ny'],
      ['r1', ''],
      ['r2', ''],
    ])
    expect(cleanNotes({ Ann: 'z'.repeat(5000) }, s.rows!)[0]![1]).toHaveLength(4000)
    expect(() => cleanNotes({ Zed: 'x' }, s.rows!)).toThrow(/`notes`: no row "Zed"/)
    expect(() => cleanNotes({ Ann: 3 }, s.rows!)).toThrow(/text or null/)
    expect(() => cleanNotes('x', s.rows!)).toThrow(/object/)
  })
})
