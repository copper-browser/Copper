import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import {
  addRow,
  checklistText,
  mergeAssignees,
  readAssigneeList,
  removeRow,
  renameColumn,
  resolveAssignee,
  setRowAssignees,
  setRowLabel,
  setRowNote,
  toggleAssignee,
  togglePick,
} from '../checklist'
import {
  assigneeBlock,
  assigneeName,
  checklistMarkdown,
  noteText,
  parseChecklistText,
  replaceRows,
  rowBlock,
  writeRowAssignees,
  writeRowNote,
} from '../checklist-text'
import { CanvasStore, HOST } from '../doc'
import { inlineText, parseMarkdownLite, toggleTask } from '../markdown-lite'
import { boardSearchItems } from '../search'
import * as released from './released/checklist-text-1012'
import { assignOptions, boardAssignees } from '../assignees'

const ann = { name: 'Ann', id: 'u-ann' }
const ada = { name: 'Ada Lovelace', id: 'u-ada' }
const collin = { name: 'Collin Rijock', id: 'u-collin', email: 'collin@example.com' }
const grace = { name: 'Grace Hopper', id: 'u-grace' }

const COLS = ['To do', 'In progress', 'Done']
const BOARD = [
  '### Sprint 12',
  '- [x] Fix the login page · In progress',
  '  > Blocked on the new certificate.',
  '  > Second line.',
  '  @Collin Rijock',
  '  @Ada Lovelace',
  '- [ ] Write the release notes',
  '  @Grace Hopper',
  '- [x] Ship it · Done',
  '  > Tuesday.',
  '- [ ] Nobody yet',
].join('\n')

function note(text: string, columns?: string[]) {
  const store = new CanvasStore(new Y.Doc())
  const id = store.create({ type: 'sticky', id: 'n', view: 'checklist', text, ...(columns ? { columns } : {}) })
  return { store, id }
}

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

/** Each row: label, pick, comment, assignee names. */
const rows = (store: CanvasStore, id: string) => {
  const s = store.get(id)!
  return s.rows!.map(r => [r.label, s.picks?.[r.id]?.col ?? null, s.notes?.[r.id]?.text ?? null, (s.assignees?.[r.id] ?? []).map(a => a.name)])
}
const names = (store: CanvasStore, id: string) => {
  const s = store.get(id)!
  return s.rows!.map(r => [r.label, (s.assignees?.[r.id] ?? []).map(a => a.name)])
}

describe('assignees in the checklist text', () => {
  it('reads indented @ lines after a row (and its comment) as its assignees, never as rows, titles or comment', () => {
    const p = parseChecklistText(BOARD, COLS)
    expect(p.title).toBe('Sprint 12')
    expect(p.rows.map(r => [r.label, r.pick, r.note, r.assignees])).toEqual([
      ['Fix the login page', 'In progress', 'Blocked on the new certificate.\nSecond line.', ['Collin Rijock', 'Ada Lovelace']],
      ['Write the release notes', null, '', ['Grace Hopper']],
      ['Ship it', 'Done', 'Tuesday.', []],
      ['Nobody yet', null, '', []],
    ])
    expect(p.rows.every(r => r.tidy)).toBe(true)
    // The row's block runs to its last @ line; its comment stops before the first.
    const first = p.rows[0]!
    expect(BOARD.slice(first.lineEnd, first.blockEnd)).toBe('\n  > Blocked on the new certificate.\n  > Second line.\n  @Collin Rijock\n  @Ada Lovelace')
    expect(BOARD.slice(first.assignStart, first.blockEnd)).toBe('\n  @Collin Rijock\n  @Ada Lovelace')
    expect(p.rows[3]!.assignStart).toBe(-1)
  })

  it('reads "@ Name", tabs and stray spaces the same; a name written twice is one; an @ not under a row is no one', () => {
    const p = parseChecklistText(['  @Loose', '### T', '@Not indented', '- [ ] Ann', '\t@ Bob  Lee ', '  @  bob  lee', '  @Cy', '', '  @After a blank'].join('\n'), ['Done'])
    expect(p.title).toBe('T')
    expect(p.rows.map(r => [r.label, r.assignees, r.tidy])).toEqual([['Ann', ['Bob Lee', 'Cy'], false]])
  })

  it('takes comment lines after @ lines too, and the next write puts the block back in order', () => {
    const text = '- [ ] Ann\n  @Bob\n  > hi\n- [ ] Cy'
    const p = parseChecklistText(text, ['Done'])
    expect(p.rows.map(r => [r.label, r.note, r.assignees, r.tidy])).toEqual([
      ['Ann', 'hi', ['Bob'], false],
      ['Cy', '', [], true],
    ])
    const doc = new Y.Doc()
    const t = doc.getText('t')
    t.insert(0, text)
    writeRowAssignees(t, parseChecklistText(t.toString(), ['Done']).rows[0]!, ['Bob', 'Dee'])
    expect(t.toString()).toBe('- [ ] Ann\n  > hi\n  @Bob\n  @Dee\n- [ ] Cy')
  })

  it('writes what it reads: picks, comments and assignees together, round and round', () => {
    const cases: { label: string; pick: string | null; note: string; assignees: string[] }[] = [
      { label: 'Fix the login page', pick: 'In progress', note: 'Blocked.\n\nSecond paragraph', assignees: ['Collin Rijock', 'Ada Lovelace'] },
      { label: 'Only people', pick: null, note: '', assignees: ['Grace Hopper'] },
      { label: 'Only a comment', pick: 'Done', note: '@not an assignee', assignees: [] },
      { label: 'Nothing', pick: null, note: '', assignees: [] },
      { label: 'Odd names', pick: 'To do', note: '> quoted', assignees: ['Ünïcode Nàme', 'a@b.example', 'Team · Design'] },
    ]
    const text = checklistMarkdown('Sprint', cases, COLS)
    const p = parseChecklistText(text, COLS)
    expect(p.rows.map(r => ({ label: r.label, pick: r.pick, note: r.note, assignees: r.assignees }))).toEqual(cases)
    // And the text it makes from what it read is the same text.
    expect(checklistMarkdown(p.title, p.rows, COLS)).toBe(text)
    expect(rowBlock('Ann', 'Done', COLS, 'hi', ['Bob'])).toBe('- [x] Ann · Done\n  > hi\n  @Bob')
    expect(assigneeBlock([])).toBe('')
    expect(assigneeBlock(['  @@Ann ', 'ann', '', 'Bob\nLee'])).toBe('\n  @Ann\n  @Bob Lee')
    expect(assigneeName('x'.repeat(200))).toHaveLength(80)
  })

  it('a card from before assignees reads exactly as it did', () => {
    const old = '### Going\n- [x] Ann · No\n  > Back at 6\n- [ ] Bob\n- [x] Cy'
    const now = parseChecklistText(old, ['Yes', 'No'])
    const then = released.parseChecklistText(old, ['Yes', 'No'])
    expect(now.rows.map(r => ({ ...r, assignees: undefined, assignStart: undefined, tidy: undefined }))).toEqual(
      then.rows.map(r => ({ ...r, assignees: undefined, assignStart: undefined, tidy: undefined }))
    )
    expect(now.rows.every(r => r.assignees.length === 0 && r.tidy)).toBe(true)
    const { store, id } = note(old, ['Yes', 'No'])
    expect(store.get(id)!.assignees).toEqual({})
  })
})

describe('a Copper that knows comments but not assignees (1.0.20261012.49)', () => {
  it('reads the same rows, picks and comments off a card with assignees, and only skips the names', () => {
    const now = parseChecklistText(BOARD, COLS)
    const then = released.parseChecklistText(BOARD, COLS)
    expect(then.title).toBe(now.title)
    expect(then.rows.map(r => [r.label, r.pick, r.note])).toEqual(now.rows.map(r => [r.label, r.pick, r.note]))
  })

  it('its comment, pick and rename writes leave the assignees where they are', () => {
    const doc = new Y.Doc()
    const t = doc.getText('t')
    t.insert(0, BOARD)
    const at = () => released.parseChecklistText(t.toString(), COLS)
    released.writeRowNote(t, at().rows[0]!, 'Unblocked.')
    released.writeRowNote(t, at().rows[1]!, 'Draft is up')
    released.writeRowNote(t, at().rows[2]!, '')
    released.writeRowPick(t, at().rows[1]!, 'Done', COLS)
    released.writeRowLabel(t, at().rows[3]!, 'Somebody yet')
    expect(parseChecklistText(t.toString(), COLS).rows.map(r => [r.label, r.pick, r.note, r.assignees])).toEqual([
      ['Fix the login page', 'In progress', 'Unblocked.', ['Collin Rijock', 'Ada Lovelace']],
      ['Write the release notes', 'Done', 'Draft is up', ['Grace Hopper']],
      ['Ship it', 'Done', '', []],
      ['Somebody yet', null, '', []],
    ])
  })
})

describe('a Copper from before checklists', () => {
  it('shows each row with its people after it, ticks the right line, and keeps them', () => {
    const items = parseMarkdownLite(BOARD).flatMap(b => (b.type === 'list' ? b.items : []))
    expect(items.map(i => inlineText(i.children))).toContain('Write the release notes @Grace Hopper')
    const { store, id } = note(BOARD, COLS)
    // Its click on the "Write the release notes" box (line 6).
    store.setText(id, toggleTask(store.get(id)!.text, 6))
    expect(rows(store, id)[1]).toEqual(['Write the release notes', 'To do', null, ['Grace Hopper']])
  })
})

describe('assigning on the board', () => {
  it('adds and removes only @ lines, with who they are beside the note; no one is no lines', () => {
    const { store, id } = note('### Sprint\n- [ ] Fix login\n  > hi\n- [ ] Notes\n- [ ] Ship', COLS)
    expect(setRowAssignees(store, id, 't0', [collin], ann)).toEqual([expect.objectContaining({ name: 'Collin Rijock', id: 'u-collin', by: 'Ann' })])
    setRowAssignees(store, id, 't1', [{ name: 'Design team' }], ann)
    setRowAssignees(store, id, 't2', [grace, ada], ann)
    expect(store.get(id)!.text).toBe('### Sprint\n- [ ] Fix login\n  > hi\n  @Collin Rijock\n- [ ] Notes\n  @Design team\n- [ ] Ship\n  @Grace Hopper\n  @Ada Lovelace')
    const s = store.get(id)!
    expect(s.assignees!.t0).toEqual([{ name: 'Collin Rijock', id: 'u-collin', email: 'collin@example.com', by: 'Ann', byId: 'u-ann', at: expect.any(Number) }])
    expect(s.assignees!.t1).toEqual([expect.objectContaining({ name: 'Design team', by: 'Ann' })])
    expect(store.shapes.get(id)!.get('assignees:fix login')).toEqual([expect.objectContaining({ name: 'Collin Rijock', id: 'u-collin' })])
    // Who stays keeps who assigned them; who is new is reported.
    expect(setRowAssignees(store, id, 't2', [grace, collin], ada)).toEqual([expect.objectContaining({ name: 'Collin Rijock', by: 'Ada Lovelace' })])
    expect(store.get(id)!.assignees!.t2!.map(p => [p.name, p.by])).toEqual([
      ['Grace Hopper', 'Ann'],
      ['Collin Rijock', 'Ada Lovelace'],
    ])
    expect(toggleAssignee(store, id, 't0', collin, ann)).toEqual({ on: false, added: [] })
    expect(store.get(id)!.text).toBe('### Sprint\n- [ ] Fix login\n  > hi\n- [ ] Notes\n  @Design team\n- [ ] Ship\n  @Grace Hopper\n  @Collin Rijock')
    expect(store.shapes.get(id)!.has('assignees:fix login')).toBe(false)
    expect(toggleAssignee(store, id, 't0', ada, ann)).toMatchObject({ on: true, added: [{ name: 'Ada Lovelace' }] })
    setRowAssignees(store, id, 't1', [], ann)
    expect(store.get(id)!.text).toBe('### Sprint\n- [ ] Fix login\n  > hi\n  @Ada Lovelace\n- [ ] Notes\n- [ ] Ship\n  @Grace Hopper\n  @Collin Rijock')
    // A name the text still has keeps its id; someone renamed in the text is a name of their own.
    store.setText(id, store.get(id)!.text.replace('@Grace Hopper', '@Grace B. Hopper'))
    expect(store.get(id)!.assignees!.t2).toEqual([{ name: 'Grace B. Hopper' }, expect.objectContaining({ name: 'Collin Rijock', id: 'u-collin' })])
  })

  it('an edit changes only the characters of its own line', () => {
    const doc = new Y.Doc()
    const t = doc.getText('t')
    t.insert(0, BOARD)
    const deltas: unknown[] = []
    t.observe(e => deltas.push(e.delta))
    const p = () => parseChecklistText(t.toString(), COLS)
    writeRowAssignees(t, p().rows[0]!, ['Collin Rijock', 'Ada Lovelace', 'Grace Hopper'])
    const end = BOARD.indexOf('  @Ada Lovelace') + '  @Ada Lovelace'.length
    expect(deltas).toEqual([[{ retain: end }, { insert: '\n  @Grace Hopper' }]])
    deltas.length = 0
    writeRowAssignees(t, p().rows[0]!, ['Collin Rijock', 'Grace Hopper'])
    expect(t.toString()).toContain('  @Collin Rijock\n  @Grace Hopper\n- [ ] Write')
    // A comment edit leaves the @ lines alone, and an @ edit the comment.
    writeRowNote(t, p().rows[0]!, 'Blocked on the new certificate.\nSecond line.\nThird.')
    writeRowAssignees(t, p().rows[1]!, [])
    expect(t.toString()).toBe(
      [
        '### Sprint 12',
        '- [x] Fix the login page · In progress',
        '  > Blocked on the new certificate.',
        '  > Second line.',
        '  > Third.',
        '  @Collin Rijock',
        '  @Grace Hopper',
        '- [ ] Write the release notes',
        '- [x] Ship it · Done',
        '  > Tuesday.',
        '- [ ] Nobody yet',
      ].join('\n')
    )
    // The first person under the last row, with no line break after it.
    writeRowAssignees(t, p().rows[3]!, ['Ann'])
    expect(t.toString().endsWith('- [ ] Nobody yet\n  @Ann')).toBe(true)
  })

  it('assignees travel with their row: picks, renames, comments, new rows, columns, reordering; removing the row takes them', () => {
    const { store, id } = note(BOARD, COLS)
    setRowAssignees(store, id, 't0', [collin, ada], ann)
    togglePick(store, id, 't0', 'Done', ann)
    setRowLabel(store, id, 't0', 'Fix the login page now')
    expect(store.shapes.get(id)!.get('assignees:fix the login page now')).toEqual(expect.arrayContaining([expect.objectContaining({ id: 'u-collin' })]))
    expect(store.shapes.get(id)!.has('assignees:fix the login page')).toBe(false)
    setRowNote(store, id, 't3', 'first comment', ann)
    setRowNote(store, id, 't1', 'a comment over the people', ann)
    expect(addRow(store, id, 't0', 'New')).toBe('t1')
    renameColumn(store, id, 2, 'Shipped')
    expect(rows(store, id)).toEqual([
      ['Fix the login page now', 'Shipped', 'Blocked on the new certificate.\nSecond line.', ['Collin Rijock', 'Ada Lovelace']],
      ['New', null, null, []],
      ['Write the release notes', null, 'a comment over the people', ['Grace Hopper']],
      ['Ship it', 'Shipped', 'Tuesday.', []],
      ['Nobody yet', null, 'first comment', []],
    ])
    expect(store.get(id)!.assignees!.t0![0]).toMatchObject({ id: 'u-collin' })
    // Reordering (as an agent's `rows` does) moves each row's people with it.
    store.transact(() => {
      const m = store.shapes.get(id)!
      const t = noteText(m)
      const cols = store.get(id)!.columns!
      const p = parseChecklistText(t.toString(), cols)
      replaceRows(t, p, [4, 2, 0, 1, 3].map(i => rowBlock(p.rows[i]!.label, p.rows[i]!.pick, cols, p.rows[i]!.note, p.rows[i]!.assignees)))
    })
    expect(names(store, id)).toEqual([
      ['Nobody yet', []],
      ['Write the release notes', ['Grace Hopper']],
      ['Fix the login page now', ['Collin Rijock', 'Ada Lovelace']],
      ['New', []],
      ['Ship it', []],
    ])
    removeRow(store, id, 't2')
    expect(store.shapes.get(id)!.has('assignees:fix the login page now')).toBe(false)
    expect(store.get(id)!.text).not.toContain('Collin')
    expect(names(store, id)[1]).toEqual(['Write the release notes', ['Grace Hopper']])
  })

  it('a legacy checklist keeps them under its own key, and loses them with the row', () => {
    const store = new CanvasStore(new Y.Doc())
    const id = store.create({ type: 'checklist', id: 'l', title: 'T', columns: ['Yes', 'No'], rows: [{ id: 'r1', label: 'Ann' }, { id: 'r2', label: 'Bob' }] })
    setRowAssignees(store, id, 'r2', [grace, { name: 'ops' }], ann)
    expect(store.get(id)!.assignees).toEqual({ r2: [expect.objectContaining({ name: 'Grace Hopper', id: 'u-grace' }), expect.objectContaining({ name: 'ops' })] })
    expect(readAssigneeList(store.shapes.get(id)!.get('assignees:r2'))).toHaveLength(2)
    removeRow(store, id, 'r2')
    expect(store.shapes.get(id)!.has('assignees:r2')).toBe(false)
  })

  it('copies and searches with the people', () => {
    const { store, id } = note(BOARD, COLS)
    const s = store.get(id)!
    expect(checklistText(s.title, s.rows!, s.picks!, s.columns!, s.notes!, s.assignees!)).toContain(
      '- Fix the login page: In progress\n  > Blocked on the new certificate.\n  > Second line.\n  @Collin Rijock\n  @Ada Lovelace\n- Write the release notes\n  @Grace Hopper'
    )
    expect(boardSearchItems(store.getShapes().values())[0]!.text).toContain('@Grace Hopper')
  })

  describe('from two Coppers at the same moment', () => {
    it('two people assigning different people to one row both stick', () => {
      const { a, b, id, sync } = pair('- [ ] Ann\n- [ ] Bob', COLS)
      setRowAssignees(a, id, 't0', [collin], ann)
      setRowAssignees(b, id, 't0', [grace], ada)
      sync()
      for (const s of [a, b]) {
        expect(names(s, id)[0]![1]).toEqual(expect.arrayContaining(['Collin Rijock', 'Grace Hopper']))
        expect(s.get(id)!.text.split('\n')).toHaveLength(4)
      }
    })

    it('a pick, a rename, a first comment and a first assignee on the same row all stick', () => {
      const { a, b, id, sync } = pair('- [ ] Ann\n- [ ] Bob\n- [ ] Cy', COLS)
      togglePick(a, id, 't0', 'Done', ada)
      setRowLabel(a, id, 't1', 'Bobby')
      setRowAssignees(b, id, 't0', [collin], ann)
      setRowNote(b, id, 't1', 'vegan', ann)
      setRowAssignees(b, id, 't1', [grace], ann)
      sync()
      for (const s of [a, b]) {
        expect(s.get(id)!.text).toBe('- [x] Ann · Done\n  @Collin Rijock\n- [ ] Bobby\n  > vegan\n  @Grace Hopper\n- [ ] Cy')
      }
    })

    it('a person added under a comment stays with its row while someone adds a row right after it', () => {
      const { a, b, id, sync } = pair('- [ ] Ann\n  > first\n- [ ] Bob', COLS)
      setRowAssignees(a, id, 't0', [collin], ada)
      addRow(b, id, 't0', 'New')
      sync()
      for (const s of [a, b]) expect(rows(s, id)).toEqual([
        ['Ann', null, 'first', ['Collin Rijock']],
        ['New', null, null, []],
        ['Bob', null, null, []],
      ])
    })

    it('a comment and an assignee written at once on one row both land in order', () => {
      const { a, b, id, sync } = pair('- [ ] Ann\n  @Grace Hopper\n- [ ] Bob', COLS)
      setRowNote(a, id, 't0', 'on it', ada)
      setRowAssignees(b, id, 't0', [grace, collin], ann)
      sync()
      for (const s of [a, b]) expect(s.get(id)!.text).toBe('- [ ] Ann\n  > on it\n  @Grace Hopper\n  @Collin Rijock\n- [ ] Bob')
    })
  })
})

describe('naming people', () => {
  const people = [
    { id: 'U-COLLIN', name: 'Collin Rijock', email: 'collin@example.com' },
    { id: 'u-ada', name: 'Ada Lovelace', email: 'ada@example.com' },
    { id: 'u-adam', name: 'Adam Smith', email: 'adam@example.com' },
  ]
  it('finds people on the canvas by id, email, name or the start of one name; anyone else is a name', () => {
    expect(resolveAssignee('collin@example.com', people)).toEqual({ name: 'Collin Rijock', id: 'u-collin', email: 'collin@example.com' })
    expect(resolveAssignee('u-collin', people)).toMatchObject({ name: 'Collin Rijock' })
    expect(resolveAssignee('@ada lovelace', people)).toMatchObject({ id: 'u-ada' })
    expect(resolveAssignee('coll', people)).toMatchObject({ id: 'u-collin' })
    // "Ada" starts two names: a name of its own rather than a guess.
    expect(resolveAssignee('Ada', people)).toEqual({ name: 'Ada' })
    expect(resolveAssignee('Design team', people)).toEqual({ name: 'Design team' })
    expect(resolveAssignee('ghost@example.com', people)).toEqual({ name: 'ghost@example.com', email: 'ghost@example.com' })
    expect(resolveAssignee({ name: 'Grace', email: 'grace@example.com' }, people)).toEqual({ name: 'Grace', email: 'grace@example.com' })
    expect(() => resolveAssignee(4, people)).toThrow(/assignees/)
    expect(() => resolveAssignee('  ', people)).toThrow(/assignees/)
  })

  it('merging keeps who assigned whom, and tells who is new', () => {
    const now = [{ name: 'Ann', id: 'u-ann', by: 'Bob', at: 1 }]
    const out = mergeAssignees(now, [{ name: 'ann', id: 'u-ann' }, { name: 'Cy' }, { name: 'cy' }], { name: 'Dee', id: 'u-dee' }, 5)
    expect(out.people).toEqual([
      { name: 'ann', id: 'u-ann', by: 'Bob', at: 1 },
      { name: 'Cy', by: 'Dee', byId: 'u-dee', at: 5 },
    ])
    expect(out.added).toEqual([{ name: 'Cy', by: 'Dee', byId: 'u-dee', at: 5 }])
  })
})

describe('the picker list', () => {
  const people = [
    { id: 'u-ann', name: 'Ann Example', email: 'ann@example.com' },
    { id: 'u-me', name: 'Ada Lovelace', email: 'ada@example.com' },
    { id: 'u-grace', name: 'Grace Hopper', email: 'grace@example.com' },
  ]
  const board = [{ name: 'Design team' }, { name: 'grace hopper' }, { name: 'Ann Example', id: 'u-ann' }, { name: 'Zed' }]
  const names = (o: { name: string; fresh?: boolean }[]) => o.map(x => (x.fresh ? `+${x.name}` : x.name))

  it('you first, then the canvas people, then other names from the board, each once', () => {
    expect(names(assignOptions(people, board, '', 'u-me'))).toEqual(['Ada Lovelace', 'Ann Example', 'Grace Hopper', 'Design team', 'Zed'])
    expect(assignOptions(people, board, '', 'u-me')[0]).toMatchObject({ me: true, id: 'u-me', email: 'ada@example.com' })
  })

  it('filters by name start, word start and email, best first; a typed name nobody has can be assigned', () => {
    expect(names(assignOptions(people, board, 'ho', 'u-me'))).toEqual(['Grace Hopper', '+ho'])
    expect(names(assignOptions(people, board, 'grace@', 'u-me'))).toEqual(['Grace Hopper', '+grace@'])
    expect(names(assignOptions(people, board, '@design team', 'u-me'))).toEqual(['Design team'])
    expect(assignOptions(people, board, 'kate@example.com', 'u-me')).toEqual([{ key: 'new:kate@example.com', name: 'kate@example.com', email: 'kate@example.com', color: expect.any(String), fresh: true }])
    expect(names(assignOptions(people, board, 'a', 'u-me', 2))).toEqual(['Ada Lovelace', 'Ann Example', '+a'])
  })

  it('names used on the board, from every checklist', () => {
    const { store } = note(BOARD, COLS)
    store.create({ type: 'sticky', id: 'm', view: 'checklist', text: '- [ ] x\n  @Zed\n  @Ada Lovelace' })
    expect(boardAssignees(store.getShapes().values()).map(p => p.name)).toEqual(['Collin Rijock', 'Ada Lovelace', 'Grace Hopper', 'Zed'])
  })
})
