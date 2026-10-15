import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import {
  addMonths,
  dayOf,
  insertItemLines,
  isoOf,
  itemLine,
  parseTimelineText,
  readItemColor,
  readStep,
  removeItemLines,
  replaceItems,
  timelineMarkdown,
  writeItem,
  writeRange,
  writeTitle,
  type ItemFields,
} from '../timeline-text'

const SAMPLE = [
  '### Q4 launch',
  '2026-10-01 → 2026-12-31 · weekly',
  '',
  '- 2026-10-14 · Kickoff',
  '- 2026-10-20 → 2026-11-03 · Build sprint · blue',
  '- 2026-11-18 · Launch review · purple',
  '  > Bubble body, **markdown**,',
  '  > as quote lines under the item',
].join('\n')

const text = (s: string) => {
  const t = new Y.Doc().getText('t')
  t.insert(0, s)
  return t
}
const items = (s: string) => parseTimelineText(s).items.map(it => [it.date, it.end, it.label, it.color, it.body, it.kind])

describe('the timeline text', () => {
  it('reads the title, the range and the step, and each kind of item', () => {
    const p = parseTimelineText(SAMPLE)
    expect(p.title).toBe('Q4 launch')
    expect(p.range).toMatchObject({ start: '2026-10-01', end: '2026-12-31', step: 'week', stepGiven: true })
    expect(items(SAMPLE)).toEqual([
      ['2026-10-14', null, 'Kickoff', null, null, 'note'],
      ['2026-10-20', '2026-11-03', 'Build sprint', 'blue', null, 'section'],
      ['2026-11-18', null, 'Launch review', 'purple', 'Bubble body, **markdown**,\nas quote lines under the item', 'bubble'],
    ])
  })

  it('is tolerant of what people type, and keeps what it cannot read as it is', () => {
    const s = [
      'Some intro prose',
      '## Plan ##',
      '2027-03-31 -> 2027-01-01 · Monthly',
      '* 2027-01-05: Ship it',
      '- 2027-02-30 · not a real day',
      '- 2027-01-10 – 2027-01-03 · Backwards · GREY',
      '- 2027-01-20 · A · B · teal',
      '- 2027-01-21 · Pink',
      '- 2027-01-22 · pink',
      '- not a date',
      '- 2027-01-23',
      '>',
      '- 2027-01-24 · Bubble',
      '  >',
    ].join('\n')
    const p = parseTimelineText(s)
    expect(p.title).toBe('Plan')
    expect(p.range).toMatchObject({ start: '2027-01-01', end: '2027-03-31', step: 'month' })
    expect(items(s)).toEqual([
      ['2027-01-05', null, 'Ship it', null, null, 'note'],
      ['2027-01-03', '2027-01-10', 'Backwards', 'gray', null, 'section'],
      ['2027-01-20', null, 'A · B · teal', null, null, 'note'],
      ['2027-01-21', null, '', 'pink', null, 'note'],
      ['2027-01-22', null, '', 'pink', null, 'note'],
      ['2027-01-23', null, '', null, '', 'bubble'],
      ['2027-01-24', null, 'Bubble', null, '', 'bubble'],
    ])
  })

  it('takes the first range line only, and defaults its step to weekly', () => {
    const p = parseTimelineText('2026-01-01 → 2026-02-01\n2025-01-01 → 2025-02-01 · daily')
    expect(p.range).toMatchObject({ start: '2026-01-01', end: '2026-02-01', step: 'week', stepGiven: false })
    // A step word it does not know still leaves the range (weekly until someone picks a step).
    expect(parseTimelineText('2026-01-01 → 2026-02-01 · fortnightly').range).toMatchObject({ step: 'week', stepGiven: false })
  })

  it('round-trips what it writes, in date order', () => {
    const list: ItemFields[] = [
      { date: '2026-11-18', label: 'Review', color: 'purple', body: 'Line one\n\nLine *three*' },
      { date: '2026-10-14', label: 'Kickoff' },
      { date: '2026-10-20', end: '2026-11-03', label: 'Sprint · two', color: 'blue' },
      { date: '2026-10-15', label: '', body: '' },
    ]
    const md = timelineMarkdown('Q4', { start: '2026-10-01', end: '2026-12-31', step: 'week' }, list)
    expect(md).toBe(
      [
        '### Q4',
        '2026-10-01 → 2026-12-31 · weekly',
        '',
        '- 2026-10-14 · Kickoff',
        '- 2026-10-15',
        '  >',
        '- 2026-10-20 → 2026-11-03 · Sprint · two · blue',
        '- 2026-11-18 · Review · purple',
        '  > Line one',
        '  >',
        '  > Line *three*',
      ].join('\n')
    )
    expect(items(md)).toEqual([
      ['2026-10-14', null, 'Kickoff', null, null, 'note'],
      ['2026-10-15', null, '', null, '', 'bubble'],
      ['2026-10-20', '2026-11-03', 'Sprint · two', 'blue', null, 'section'],
      ['2026-11-18', null, 'Review', 'purple', 'Line one\n\nLine *three*', 'bubble'],
    ])
  })

  it('keeps a label that ends in a colour word by writing the colour after it', () => {
    const line = itemLine({ date: '2026-01-01', label: 'Go green', color: null })
    expect(line).toBe('- 2026-01-01 · Go green')
    expect(items(line)[0]![2]).toBe('Go green')
    // Only a whole " · colour" segment is a colour.
    expect(items(itemLine({ date: '2026-01-01', label: 'Paint · blue', color: 'pink' }))[0]).toEqual(['2026-01-01', null, 'Paint · blue', 'pink', null, 'note'])
  })

  it('reads steps and colours as people say them', () => {
    expect(['daily', 'Weeks', 'mo', 'Q', 'annual', 'fortnight'].map(readStep)).toEqual(['day', 'week', 'month', 'quarter', 'year', null])
    expect(['Blue', 'grey', ' gray ', 'white', 'teal'].map(readItemColor)).toEqual(['blue', 'gray', 'gray', null, null])
  })

  it('counts days in UTC, months clamped', () => {
    expect(dayOf('1970-01-02')).toBe(1)
    expect(isoOf(dayOf('2028-02-29')!)).toBe('2028-02-29')
    expect(dayOf('2027-02-29')).toBeNull()
    expect(addMonths('2026-11-30', 3)).toBe('2027-02-28')
    expect(addMonths('2026-01-31', -2)).toBe('2025-11-30')
  })
})

describe('writes on the text', () => {
  it('changes only its own line, and moves an item whose date passes its neighbours', () => {
    const t = text(SAMPLE)
    let p = parseTimelineText(t.toString())
    expect(writeItem(t, p, p.items[0]!, { date: '2026-10-15', label: 'Kick-off', color: 'green' })).toBe(0)
    expect(t.toString().split('\n')[3]).toBe('- 2026-10-15 · Kick-off · green')
    p = parseTimelineText(t.toString())
    // Past the section: lifted out and put back after it.
    expect(writeItem(t, p, p.items[0]!, { date: '2026-12-01', label: 'Kick-off', color: 'green' })).toBe(2)
    expect(items(t.toString()).map(i => i[2])).toEqual(['Build sprint', 'Launch review', 'Kick-off'])
    expect(t.toString().endsWith('  > as quote lines under the item\n- 2026-12-01 · Kick-off · green')).toBe(true)
  })

  it('turns a note into a bubble and back, its body under its line', () => {
    const t = text(SAMPLE)
    let p = parseTimelineText(t.toString())
    writeItem(t, p, p.items[0]!, { date: '2026-10-14', label: 'Kickoff', body: 'Agenda:\n- intro' })
    expect(t.toString().split('\n').slice(3, 6)).toEqual(['- 2026-10-14 · Kickoff', '  > Agenda:', '  > - intro'])
    p = parseTimelineText(t.toString())
    expect(p.items[0]).toMatchObject({ kind: 'bubble', body: 'Agenda:\n- intro' })
    writeItem(t, p, p.items[0]!, { date: '2026-10-14', label: 'Kickoff', body: null })
    expect(t.toString()).toBe(SAMPLE)
    // The last item's body goes too, with nothing left dangling.
    p = parseTimelineText(t.toString())
    writeItem(t, p, p.items[2]!, { date: '2026-11-18', label: 'Launch review', color: 'purple', body: null })
    expect(t.toString().endsWith('- 2026-11-18 · Launch review · purple')).toBe(true)
  })

  it('adds where the date belongs and removes an item with its body', () => {
    const t = text(SAMPLE)
    expect(insertItemLines(t, parseTimelineText(t.toString()), { date: '2026-10-01', label: 'First' })).toBe(0)
    expect(insertItemLines(t, parseTimelineText(t.toString()), { date: '2026-11-18', label: 'Same day' })).toBe(4)
    expect(insertItemLines(t, parseTimelineText(t.toString()), { date: '2026-12-31', label: 'Last', body: 'x' })).toBe(5)
    expect(items(t.toString()).map(i => i[2])).toEqual(['First', 'Kickoff', 'Build sprint', 'Launch review', 'Same day', 'Last'])
    const p = parseTimelineText(t.toString())
    removeItemLines(t, p.items[3]!)
    removeItemLines(t, parseTimelineText(t.toString()).items[4]!)
    expect(t.toString()).toBe(
      ['### Q4 launch', '2026-10-01 → 2026-12-31 · weekly', '', '- 2026-10-01 · First', '- 2026-10-14 · Kickoff', '- 2026-10-20 → 2026-11-03 · Build sprint · blue', '- 2026-11-18 · Same day'].join('\n')
    )
  })

  it('starts a list under the range with a blank line, and a range under the title', () => {
    const t = text('### Plan')
    writeRange(t, parseTimelineText(t.toString()), '2026-01-01', '2026-03-01', 'month')
    insertItemLines(t, parseTimelineText(t.toString()), { date: '2026-02-01', label: 'Mid' })
    expect(t.toString()).toBe('### Plan\n2026-01-01 → 2026-03-01 · monthly\n\n- 2026-02-01 · Mid')
    writeRange(t, parseTimelineText(t.toString()), '2026-01-01', '2026-06-30', 'quarter')
    writeTitle(t, parseTimelineText(t.toString()), 'Plan B')
    expect(t.toString()).toBe('### Plan B\n2026-01-01 → 2026-06-30 · quarterly\n\n- 2026-02-01 · Mid')
    // Typed a key at a time, a space and all: no stray space is left behind.
    const typed = text('### T\n2026-01-01 → 2026-02-01 · daily')
    for (const v of ['L', 'La', 'La ', 'La p', 'La pl']) writeTitle(typed, parseTimelineText(typed.toString()), v)
    expect(typed.toString()).toBe('### La pl\n2026-01-01 → 2026-02-01 · daily')
    const closed = text('## Old ##')
    writeTitle(closed, parseTimelineText(closed.toString()), 'New')
    expect(closed.toString()).toBe('## New ##')
    const bare = text('')
    writeTitle(bare, parseTimelineText(''), 'New')
    expect(bare.toString()).toBe('### New')
  })

  it('replaces the whole list in place, keeping prose and stray lines', () => {
    const t = text(`${SAMPLE}\n\nNotes from Ann`)
    replaceItems(t, parseTimelineText(t.toString()), [
      { date: '2026-12-01', label: 'B' },
      { date: '2026-11-01', label: 'A', body: 'hi' },
    ])
    expect(t.toString()).toBe(['### Q4 launch', '2026-10-01 → 2026-12-31 · weekly', '', '- 2026-11-01 · A', '  > hi', '- 2026-12-01 · B', '', 'Notes from Ann'].join('\n'))
    replaceItems(t, parseTimelineText(t.toString()), [])
    expect(t.toString()).toBe(['### Q4 launch', '2026-10-01 → 2026-12-31 · weekly', '', '', 'Notes from Ann'].join('\n'))
    const fresh = text('### T\n2026-01-01 → 2026-02-01 · daily')
    replaceItems(fresh, parseTimelineText(fresh.toString()), [{ date: '2026-01-02', label: 'x' }])
    expect(fresh.toString()).toBe('### T\n2026-01-01 → 2026-02-01 · daily\n\n- 2026-01-02 · x')
  })
})

describe('two Coppers editing at once', () => {
  /** Two replicas of one text that exchange updates only when told to. */
  function pair(s: string) {
    const a = new Y.Doc()
    a.getText('t').insert(0, s)
    const b = new Y.Doc()
    Y.applyUpdate(b, Y.encodeStateAsUpdate(a))
    const sync = () => {
      const ua = Y.encodeStateAsUpdate(a, Y.encodeStateVector(b))
      const ub = Y.encodeStateAsUpdate(b, Y.encodeStateVector(a))
      Y.applyUpdate(b, ua)
      Y.applyUpdate(a, ub)
    }
    return { a: a.getText('t'), b: b.getText('t'), sync }
  }

  it('both land when each edits a different item', () => {
    const { a, b, sync } = pair(SAMPLE)
    const pa = parseTimelineText(a.toString())
    const pb = parseTimelineText(b.toString())
    writeItem(a, pa, pa.items[0]!, { date: '2026-10-14', label: 'Kickoff (all hands)', color: 'yellow' })
    writeItem(b, pb, pb.items[1]!, { date: '2026-10-20', end: '2026-11-10', label: 'Build sprint', color: 'green' })
    sync()
    expect(a.toString()).toBe(b.toString())
    expect(items(a.toString())).toEqual([
      ['2026-10-14', null, 'Kickoff (all hands)', 'yellow', null, 'note'],
      ['2026-10-20', '2026-11-10', 'Build sprint', 'green', null, 'section'],
      ['2026-11-18', null, 'Launch review', 'purple', 'Bubble body, **markdown**,\nas quote lines under the item', 'bubble'],
    ])
  })

  it('an add and an edit, a removal and a body edit, all land', () => {
    const { a, b, sync } = pair(SAMPLE)
    insertItemLines(a, parseTimelineText(a.toString()), { date: '2026-10-25', label: 'Demo', color: 'pink' })
    const pb = parseTimelineText(b.toString())
    writeItem(b, pb, pb.items[2]!, { date: '2026-11-18', label: 'Launch review', color: 'purple', body: 'Bubble body, **markdown**,\nas quote lines under the item\nand a third' })
    sync()
    const pa = parseTimelineText(a.toString())
    removeItemLines(a, pa.items[0]!)
    const pb2 = parseTimelineText(b.toString())
    writeItem(b, pb2, pb2.items[1]!, { date: '2026-10-20', end: '2026-11-03', label: 'Sprint 1', color: 'blue' })
    sync()
    expect(a.toString()).toBe(b.toString())
    expect(items(a.toString()).map(i => [i[0], i[2], i[4]])).toEqual([
      ['2026-10-20', 'Sprint 1', null],
      ['2026-10-25', 'Demo', null],
      ['2026-11-18', 'Launch review', 'Bubble body, **markdown**,\nas quote lines under the item\nand a third'],
    ])
  })

  it('a label edit and a first body on the same item, at once, both land', () => {
    const { a, b, sync } = pair('### T\n2026-01-01 → 2026-02-01 · daily\n\n- 2026-01-05 · One\n- 2026-01-09 · Two')
    const pa = parseTimelineText(a.toString())
    const pb = parseTimelineText(b.toString())
    writeItem(a, pa, pa.items[0]!, { date: '2026-01-05', label: 'One!' })
    writeItem(b, pb, pb.items[0]!, { date: '2026-01-05', label: 'One', body: 'why' })
    sync()
    expect(a.toString()).toBe(b.toString())
    expect(items(a.toString()).map(i => [i[2], i[4]])).toEqual([
      ['One!', 'why'],
      ['Two', null],
    ])
  })

  it('two adds after the same item both land, each line whole', () => {
    const { a, b, sync } = pair(SAMPLE)
    insertItemLines(a, parseTimelineText(a.toString()), { date: '2026-12-02', label: 'A' })
    insertItemLines(b, parseTimelineText(b.toString()), { date: '2026-12-01', label: 'B' })
    sync()
    expect(a.toString()).toBe(b.toString())
    expect(items(a.toString()).map(i => i[2]).slice(3).sort()).toEqual(['A', 'B'])
    // Each line is whole: no add merged into the bubble's body.
    expect(parseTimelineText(a.toString()).items[2]!.body).toBe('Bubble body, **markdown**,\nas quote lines under the item')
  })
})
