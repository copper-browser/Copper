import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { addColumn, addRow, checklistText, isChecklist, removeColumn, removeRow, renameColumn, setRowLabel, setRowNote, setTitle, togglePick } from '../checklist'
import { checklistMarkdown, noteBlock, noteText, parseChecklistText, replaceRows, rowBlock, writeRowNote } from '../checklist-text'
import { CanvasStore, HOST } from '../doc'
import { toggleTask } from '../markdown-lite'
import { boardSearchItems } from '../search'

const ann = { name: 'Ann', id: 'u-ann' }
const ada = { name: 'Ada Lovelace', id: 'u-ada' }

function note(text: string, columns?: string[]) {
  const store = new CanvasStore(new Y.Doc())
  const id = store.create({ type: 'sticky', id: 'n', view: 'checklist', text, ...(columns ? { columns } : {}) })
  return { store, id }
}

/** Two replicas of one doc that exchange updates only when told to. */
function pair(text: string, columns?: string[]) {
  const a = note(text, columns)
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

/** What a Copper from before the checklist view does on a click on a note's task box. */
const oldTick = (store: CanvasStore, id: string, line: number) => store.setText(id, toggleTask(store.get(id)!.text, line))

const picks = (store: CanvasStore, id: string) => {
  const s = store.get(id)!
  return s.rows!.map(r => [r.label, s.picks![r.id]?.col ?? null])
}

describe('the checklist text', () => {
  it('reads the first heading as the title and each task line as a row', () => {
    const p = parseChecklistText('Intro\n## Going ##\n- [ ] Ann\n* [x] Ada Lovelace\n1. [X] Bob\nnot a row\n- plain bullet\n- [ ] \n### Second', ['Going'])
    expect(p.title).toBe('Going')
    expect(p.rows.map(r => [r.label, r.pick])).toEqual([
      ['Ann', null],
      ['Ada Lovelace', 'Going'],
      ['Bob', 'Going'],
      ['', null],
    ])
  })

  it('reads a suffix naming a column as the pick; any other suffix is part of the label', () => {
    const p = parseChecklistText('- [x] Ann · No\n- [x] Bob\n- [ ] Cy · no\n- [x] Dee · team lead\n- [xx] Eve · Yes', ['Yes', 'No'])
    expect(p.rows.map(r => [r.label, r.pick])).toEqual([
      ['Ann', 'No'],
      ['Bob', 'Yes'],
      ['Cy', null],
      ['Dee · team lead', 'Yes'],
      ['Eve', 'Yes'],
    ])
  })

  it('writes what it reads', () => {
    const text = checklistMarkdown('Going', [{ label: 'Ann', pick: null }, { label: 'Ada', pick: 'No' }], ['Yes', 'No'])
    expect(text).toBe('### Going\n- [ ] Ann\n- [x] Ada · No')
    expect(checklistMarkdown('', [{ label: 'Ann', pick: 'Done' }], ['Done'])).toBe('- [x] Ann')
  })
})

describe('a note in the checklist view', () => {
  it('reads as a checklist card; who picked only when it agrees with the text', () => {
    const { store, id } = note('### Going\n- [ ] Ann\n- [x] Ada Lovelace')
    const s = store.get(id)!
    expect(isChecklist(s)).toBe(true)
    expect(s).toMatchObject({ type: 'sticky', view: 'checklist', title: 'Going', columns: ['Done'] })
    expect(picks(store, id)).toEqual([
      ['Ann', null],
      ['Ada Lovelace', 'Done'],
    ])
    expect(s.picks!.t1).toMatchObject({ by: '', at: 0 })
    store.shapes.get(id)!.set('who:ada lovelace', { col: 'Done', by: 'Ada Lovelace', byId: 'u-ada', at: 5 })
    store.shapes.get(id)!.set('who:ann', { col: 'Done', by: 'Ann', byId: 'u-ann', at: 5 })
    expect(store.get(id)!.picks!.t1).toMatchObject({ by: 'Ada Lovelace', at: 5 })
    // Ann's line is unticked (an older Copper cleared it): her who is not shown.
    expect(store.get(id)!.picks!.t0).toBeUndefined()
  })

  it('a click edits only its own line: box and suffix', () => {
    const { store, id } = note('### Dinner\n- [ ] Ann\n- [ ] Bob', ['Yes', 'No'])
    togglePick(store, id, 't1', 'No', ann)
    expect(store.get(id)!.text).toBe('### Dinner\n- [ ] Ann\n- [x] Bob · No')
    expect(store.shapes.get(id)!.get('who:bob')).toMatchObject({ col: 'No', by: 'Ann' })
    togglePick(store, id, 't1', 'Yes', ann)
    expect(store.get(id)!.text).toBe('### Dinner\n- [ ] Ann\n- [x] Bob · Yes')
    togglePick(store, id, 't1', 'Yes', ann)
    expect(store.get(id)!.text).toBe('### Dinner\n- [ ] Ann\n- [ ] Bob')
    expect(store.shapes.get(id)!.has('who:bob')).toBe(false)
  })

  it('one column: a tick, no suffix; an old tick with no suffix is the first column', () => {
    const { store, id } = note('### Going\n- [ ] Ann\n- [ ] Ada')
    togglePick(store, id, 't0', 'Done', ann)
    expect(store.get(id)!.text).toBe('### Going\n- [x] Ann\n- [ ] Ada')
    oldTick(store, id, 2)
    expect(picks(store, id)).toEqual([
      ['Ann', 'Done'],
      ['Ada', 'Done'],
    ])
  })

  it('a click finds its row by label when the text moved under it', () => {
    const { store, id } = note('- [ ] Ann\n- [ ] Bob')
    store.setText(id, '- [ ] Zed\n- [ ] Ann\n- [ ] Bob')
    togglePick(store, id, 't0', 'Done', ann, 'local', 'Ann')
    expect(store.get(id)!.text).toBe('- [ ] Zed\n- [x] Ann\n- [ ] Bob')
  })

  it('a new click and an older Copper tick on different rows at the same moment both stick', () => {
    const { a, b, id, sync } = pair('### Wed\n- [ ] Ann\n- [ ] Bob\n- [ ] Cy\n- [ ] Dee', ['Yes', 'No'])
    togglePick(a, id, 't0', 'No', ada)
    togglePick(a, id, 't3', 'Yes', ada)
    oldTick(b, id, 2) // Bob, ticked in a note by an older Copper
    oldTick(b, id, 3) // Cy
    sync()
    for (const s of [a, b]) {
      expect(s.get(id)!.text).toBe('### Wed\n- [x] Ann · No\n- [x] Bob\n- [x] Cy\n- [x] Dee · Yes')
      expect(picks(s, id)).toEqual([
        ['Ann', 'No'],
        ['Bob', 'Yes'],
        ['Cy', 'Yes'],
        ['Dee', 'Yes'],
      ])
      expect(s.get(id)!.picks!.t0).toMatchObject({ by: 'Ada Lovelace' })
    }
  })

  it('an older Copper unticking a picked line clears the pick (its suffix is left, read as no pick)', () => {
    const { store, id } = note('- [x] Ann · No', ['Yes', 'No'])
    oldTick(store, id, 0)
    expect(store.get(id)!.text).toBe('- [ ] Ann · No')
    expect(picks(store, id)).toEqual([['Ann', null]])
    togglePick(store, id, 't0', 'Yes', ann)
    expect(store.get(id)!.text).toBe('- [x] Ann · Yes')
  })

  it('two new clicks on different rows merge', () => {
    const { a, b, id, sync } = pair('- [ ] Ann\n- [ ] Bob', ['Yes', 'No'])
    togglePick(a, id, 't0', 'Yes', ann)
    togglePick(b, id, 't1', 'No', ada)
    sync()
    for (const s of [a, b]) expect(s.get(id)!.text).toBe('- [x] Ann · Yes\n- [x] Bob · No')
  })

  it('adds, renames and removes rows in the text; who follows a rename', () => {
    const { store, id } = note('### Going\n- [ ] Ann')
    const fresh = addRow(store, id, 't0', '')!
    expect(fresh).toBe('t1')
    setRowLabel(store, id, fresh, 'Ada')
    expect(store.get(id)!.text).toBe('### Going\n- [ ] Ann\n- [ ] Ada')
    togglePick(store, id, 't1', 'Done', ann)
    setRowLabel(store, id, 't1', 'Ada Lovelace')
    expect(store.get(id)!.text).toBe('### Going\n- [ ] Ann\n- [x] Ada Lovelace')
    expect(store.get(id)!.picks!.t1).toMatchObject({ by: 'Ann' })
    removeRow(store, id, 't0')
    expect(store.get(id)!.text).toBe('### Going\n- [x] Ada Lovelace')
    removeRow(store, id, 't0')
    expect(store.get(id)!.text).toBe('### Going')
    expect(store.shapes.get(id)!.has('who:ada lovelace')).toBe(false)
    addRow(store, id, null, 'Bob')
    expect(store.get(id)!.text).toBe('### Going\n- [ ] Bob')
  })

  it('a new card: title then rows from an empty text', () => {
    const { store, id } = note('', ['Yes', 'No'])
    setTitle(store, id, 'G')
    setTitle(store, id, 'Going')
    expect(store.get(id)!.text).toBe('### Going')
    addRow(store, id, null, 'Ann')
    expect(store.get(id)!.text).toBe('### Going\n- [ ] Ann')
  })

  it('columns: rename carries the suffix, removing one clears its picks, one left drops suffixes', () => {
    const { store, id } = note('- [x] Ann · No\n- [x] Bob\n- [x] Cy · Yes', ['Yes', 'No'])
    expect(addColumn(store, id)).toBe(2)
    expect(store.get(id)!.columns).toEqual(['Yes', 'No', 'Maybe'])
    renameColumn(store, id, 1, 'Nope')
    expect(store.get(id)!.text).toBe('- [x] Ann · Nope\n- [x] Bob\n- [x] Cy · Yes')
    removeColumn(store, id, 0)
    expect(store.get(id)!.text).toBe('- [x] Ann · Nope\n- [ ] Bob\n- [ ] Cy')
    removeColumn(store, id, 1)
    expect(store.get(id)!.columns).toEqual(['Nope'])
    expect(store.get(id)!.text).toBe('- [x] Ann\n- [ ] Bob\n- [ ] Cy')
  })

  it('a click is one undo step', () => {
    const { store, id } = note('- [ ] Ann\n- [ ] Bob', ['Yes', 'No'])
    togglePick(store, id, 't0', 'No', ann)
    store.undo.stopCapturing()
    togglePick(store, id, 't1', 'Yes', ann)
    store.undo.undo()
    expect(store.get(id)!.text).toBe('- [x] Ann · No\n- [ ] Bob')
  })

  it('is found by its text, as a checklist', () => {
    const { store } = note('### Going\n- [ ] Ann')
    expect(boardSearchItems(store.getShapes().values())).toMatchObject([{ ref: 'n', kind: 'checklist', text: '### Going\n- [ ] Ann' }])
  })
})

describe("a row's comment", () => {
  const COLS = ['Yes', 'Later', 'Talk', 'No']
  const LAND = [
    '### Where we land',
    '- [x] 1. Source of truth · No',
    "  > We already have InvenTree; pull, don't own.",
    '  > Second line.',
    '- [ ] 2. Scope',
    '- [x] 3. Owner · Yes',
    '  > Ops.',
  ].join('\n')
  const notes = (store: CanvasStore, id: string) => {
    const s = store.get(id)!
    return s.rows!.map(r => [r.label, s.notes?.[r.id]?.text ?? null])
  }

  it('reads indented quote lines under a task line as its comment, never as a row or a title', () => {
    const p = parseChecklistText(LAND, COLS)
    expect(p.title).toBe('Where we land')
    expect(p.rows.map(r => [r.label, r.pick, r.note])).toEqual([
      ['1. Source of truth', 'No', "We already have InvenTree; pull, don't own.\nSecond line."],
      ['2. Scope', null, ''],
      ['3. Owner', 'Yes', 'Ops.'],
    ])
    expect(LAND.slice(p.rows[0]!.lineEnd, p.rows[0]!.blockEnd)).toBe("\n  > We already have InvenTree; pull, don't own.\n  > Second line.")
    expect(p.rows[1]!.blockEnd).toBe(p.rows[1]!.lineEnd)
  })

  it('a comment that looks like a row or a heading is still a comment; quotes not under a row are no one’s', () => {
    const p = parseChecklistText(['  > ### Not the title', '### Real', '> loose quote', '- [ ] Ann', '  > - [x] not a row', '  > ### nor a title', '', '  > after a blank line'].join('\n'), ['Done'])
    expect(p.title).toBe('Real')
    expect(p.rows.map(r => [r.label, r.note])).toEqual([['Ann', '- [x] not a row\n### nor a title']])
  })

  it('writes what it reads, whatever the words', () => {
    for (const note of ['one', ' leading space', 'trailing space ', 'two\nlines', 'a\n\nparagraph', 'ends in a break\n', '\n\nstarts blank', '> a quote', '   ']) {
      const text = rowBlock('Ann', 'No', COLS, note)
      const row = parseChecklistText(text, COLS).rows[0]!
      expect(row.note).toBe(note)
      expect(row.label).toBe('Ann')
      expect(row.pick).toBe('No')
    }
    expect(noteBlock('')).toBe('')
    expect(noteBlock('a\r\n\r\nb')).toBe('\n  > a\n  >\n  > b')
    expect(checklistMarkdown('G', [{ label: 'Ann', pick: 'Yes', note: 'hi' }, { label: 'Bob', pick: null }], ['Yes', 'No'])).toBe('### G\n- [x] Ann · Yes\n  > hi\n- [ ] Bob')
  })

  it('an edit changes only the characters it means to', () => {
    const doc = new Y.Doc()
    const t = doc.getText('t')
    t.insert(0, LAND)
    const deltas: unknown[] = []
    t.observe(e => deltas.push(e.delta))
    writeRowNote(t, parseChecklistText(t.toString(), COLS).rows[0]!, "We already have InvenTree; pull, don't own.\nSecond line, longer.")
    expect(deltas).toEqual([[{ retain: LAND.indexOf('Second line.') + 'Second line'.length }, { insert: ', longer' }]])
    writeRowNote(t, parseChecklistText(t.toString(), COLS).rows[1]!, 'New')
    writeRowNote(t, parseChecklistText(t.toString(), COLS).rows[2]!, '')
    expect(t.toString()).toBe(
      [
        '### Where we land',
        '- [x] 1. Source of truth · No',
        "  > We already have InvenTree; pull, don't own.",
        '  > Second line, longer.',
        '- [ ] 2. Scope',
        '  > New',
        '- [x] 3. Owner · Yes',
      ].join('\n')
    )
  })

  it('travels with its row: picks, renames, new rows, columns and reordering keep it; removing the row takes it', () => {
    const { store, id } = note(LAND, COLS)
    togglePick(store, id, 't0', 'Later', ann)
    togglePick(store, id, 't1', 'Talk', ann)
    setRowLabel(store, id, 't0', '1. Source of record')
    expect(addRow(store, id, 't0', 'New')).toBe('t1')
    renameColumn(store, id, 0, 'Sure')
    expect(store.get(id)!.text).toBe(
      [
        '### Where we land',
        '- [x] 1. Source of record · Later',
        "  > We already have InvenTree; pull, don't own.",
        '  > Second line.',
        '- [ ] New',
        '- [x] 2. Scope · Talk',
        '- [x] 3. Owner · Sure',
        '  > Ops.',
      ].join('\n')
    )
    // Reordering (as an agent's `rows` does) moves each comment with its row.
    store.transact(() => {
      const m = store.shapes.get(id)!
      const t = noteText(m)
      const p = parseChecklistText(t.toString(), store.get(id)!.columns!)
      replaceRows(t, p, [2, 0, 3, 1].map(i => rowBlock(p.rows[i]!.label, p.rows[i]!.pick, store.get(id)!.columns!, p.rows[i]!.note)))
    })
    expect(notes(store, id)).toEqual([
      ['2. Scope', null],
      ['1. Source of record', "We already have InvenTree; pull, don't own.\nSecond line."],
      ['3. Owner', 'Ops.'],
      ['New', null],
    ])
    removeRow(store, id, 't1')
    expect(store.get(id)!.text).toBe('### Where we land\n- [x] 2. Scope · Talk\n- [x] 3. Owner · Sure\n  > Ops.\n- [ ] New')
    removeRow(store, id, 't1')
    expect(store.get(id)!.text).toBe('### Where we land\n- [x] 2. Scope · Talk\n- [ ] New')
  })

  it('the board writes it with who and when; who follows a rename and goes with the row; empty is no lines', () => {
    const { store, id } = note('### Going\n- [ ] Ann\n- [ ] Bob')
    setRowNote(store, id, 't0', 'Back at 6\r\nmaybe', ada)
    expect(store.get(id)!.text).toBe('### Going\n- [ ] Ann\n  > Back at 6\n  > maybe\n- [ ] Bob')
    expect(store.get(id)!.notes!.t0).toMatchObject({ text: 'Back at 6\nmaybe', by: 'Ada Lovelace', byId: 'u-ada' })
    expect(store.get(id)!.notes!.t0!.at).toBeGreaterThan(0)
    expect(store.get(id)!.notes!.t1).toBeUndefined()
    setRowLabel(store, id, 't0', 'Ann B')
    expect(store.shapes.get(id)!.get('noteBy:ann b')).toMatchObject({ by: 'Ada Lovelace' })
    expect(store.shapes.get(id)!.has('noteBy:ann')).toBe(false)
    setRowNote(store, id, 't0', '', ann)
    expect(store.get(id)!.text).toBe('### Going\n- [ ] Ann B\n- [ ] Bob')
    expect(store.shapes.get(id)!.has('noteBy:ann b')).toBe(false)
    setRowNote(store, id, 't1', 'x', ann)
    removeRow(store, id, 't1')
    expect(store.get(id)!.text).toBe('### Going\n- [ ] Ann B')
    expect(store.shapes.get(id)!.has('noteBy:bob')).toBe(false)
    // A comment found by its label when the text moved under the editor.
    store.setText(id, '- [ ] Zed\n- [ ] Ann B')
    setRowNote(store, id, 't0', 'hi', ann, 'local', 'Ann B')
    expect(store.get(id)!.text).toBe('- [ ] Zed\n- [ ] Ann B\n  > hi')
  })

  it('copies and searches with the comments', () => {
    const { store, id } = note(LAND, COLS)
    const s = store.get(id)!
    expect(checklistText(s.title, s.rows!, s.picks!, s.columns!, s.notes!)).toBe(
      "Where we land\n- 1. Source of truth: No\n  > We already have InvenTree; pull, don't own.\n  > Second line.\n- 2. Scope\n- 3. Owner: Yes\n  > Ops."
    )
    expect(boardSearchItems(store.getShapes().values())[0]!.text).toContain('InvenTree')
  })

  it('an older Copper ticks the right row around comment lines, and shows them as a quote', () => {
    const { store, id } = note(LAND, COLS)
    oldTick(store, id, 4) // "- [ ] 2. Scope", the fifth line
    expect(picks(store, id)).toEqual([
      ['1. Source of truth', 'No'],
      ['2. Scope', 'Yes'],
      ['3. Owner', 'Yes'],
    ])
    expect(notes(store, id)[0]![1]).toContain('InvenTree')
  })

  describe('from two Coppers at the same moment', () => {
    it('comments on different rows both stick', () => {
      const { a, b, id, sync } = pair('### W\n- [ ] Ann\n- [ ] Bob\n- [ ] Cy', ['Yes', 'No'])
      setRowNote(a, id, 't0', 'Ann says hi', ada)
      setRowNote(b, id, 't2', 'Cy\ntoo', ann)
      setRowNote(a, id, 't1', 'Bob', ada)
      sync()
      for (const s of [a, b]) {
        expect(s.get(id)!.text).toBe('### W\n- [ ] Ann\n  > Ann says hi\n- [ ] Bob\n  > Bob\n- [ ] Cy\n  > Cy\n  > too')
        expect(notes(s, id)).toEqual([
          ['Ann', 'Ann says hi'],
          ['Bob', 'Bob'],
          ['Cy', 'Cy\ntoo'],
        ])
      }
    })

    it('typing in different lines of one comment merges', () => {
      const { a, b, id, sync } = pair('- [ ] Ann\n  > one\n  > two', ['Yes', 'No'])
      setRowNote(a, id, 't0', 'one, and more\ntwo', ada)
      setRowNote(b, id, 't0', 'one\ntwo, and less', ann)
      sync()
      for (const s of [a, b]) expect(notes(s, id)).toEqual([['Ann', 'one, and more\ntwo, and less']])
    })

    it('a pick, a rename and a first comment on the same row all stick', () => {
      const { a, b, id, sync } = pair('- [ ] Ann\n- [ ] Bob\n- [ ] Cy', ['Yes', 'No'])
      togglePick(a, id, 't0', 'No', ada)
      setRowLabel(a, id, 't1', 'Bobby')
      setRowNote(b, id, 't0', 'running late', ann)
      setRowNote(b, id, 't1', 'vegan', ann)
      sync()
      for (const s of [a, b]) {
        expect(s.get(id)!.text).toBe('- [x] Ann · No\n  > running late\n- [ ] Bobby\n  > vegan\n- [ ] Cy')
        expect(picks(s, id)).toEqual([
          ['Ann', 'No'],
          ['Bobby', null],
          ['Cy', null],
        ])
      }
    })

    it('a comment being written stays with its row while someone adds a row right after it', () => {
      const { a, b, id, sync } = pair('- [ ] Ann\n  > first\n- [ ] Bob', ['Yes', 'No'])
      setRowNote(a, id, 't0', 'first\nsecond', ada)
      addRow(b, id, 't0', 'New')
      sync()
      for (const s of [a, b]) {
        expect(s.get(id)!.text).toBe('- [ ] Ann\n  > first\n  > second\n- [ ] New\n- [ ] Bob')
        expect(notes(s, id)).toEqual([
          ['Ann', 'first\nsecond'],
          ['New', null],
          ['Bob', null],
        ])
      }
    })

    it('a row removed by one and a comment on another by the other both land', () => {
      const { a, b, id, sync } = pair('- [ ] Ann\n  > a\n- [ ] Bob\n  > b\n- [ ] Cy', ['Yes', 'No'])
      removeRow(a, id, 't1')
      setRowNote(b, id, 't0', 'a, edited', ann)
      setRowNote(b, id, 't2', 'c', ann)
      sync()
      for (const s of [a, b]) expect(s.get(id)!.text).toBe('- [ ] Ann\n  > a, edited\n- [ ] Cy\n  > c')
    })
  })
})
