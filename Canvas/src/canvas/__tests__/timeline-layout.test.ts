import { describe, expect, it } from 'vitest'
import { dayAtX, dayX, layoutTimeline, sectionReadout, spanText, stepTicks, type Box, type LayoutItem } from '../timeline-layout'
import { dayOf, isoOf, kindOf, type ItemColor } from '../timeline-text'

const day = (iso: string) => dayOf(iso)!

let n = 0
const pin = (date: string, label: string, body: string | null = null, color: ItemColor | null = null): LayoutItem => ({
  index: n++,
  date,
  end: null,
  label,
  color,
  body,
  kind: kindOf({ end: null, body }),
})
const section = (date: string, end: string, label: string, color: ItemColor | null = 'blue'): LayoutItem => ({
  index: n++,
  date,
  end,
  label,
  color,
  body: null,
  kind: 'section',
})

const overlaps = (a: Box, b: Box) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h

/** 25 notes and bubbles and 6 sections, bunched the way real plans are. */
function crowded(): LayoutItem[] {
  n = 0
  const list: LayoutItem[] = []
  const words = ['Kickoff', 'Design review', 'API freeze', 'Beta', 'Docs', 'Pricing call', 'Security review', 'Launch', 'Retro', 'Board meeting']
  for (let i = 0; i < 25; i++) {
    const d = isoOf(day('2026-10-01') + Math.round(i * 3.4) + (i % 3))
    const label = `${words[i % words.length]} ${i}`
    list.push(i % 4 === 1 ? pin(d, label, 'A body with **markdown**, long enough to wrap onto a second line or a third one.') : pin(d, label))
  }
  list.push(section('2026-10-05', '2026-10-25', 'Build sprint 1'))
  list.push(section('2026-10-20', '2026-11-12', 'Build sprint 2', 'green'))
  list.push(section('2026-11-01', '2026-11-20', 'QA', 'pink'))
  list.push(section('2026-11-15', '2026-12-10', 'Launch prep', 'purple'))
  list.push(section('2026-09-01', '2026-10-10', 'Before the range', 'yellow'))
  list.push(section('2026-12-01', '2027-01-31', 'Past the range', 'gray'))
  return list
}

describe('the timeline layout', () => {
  it('maps days to equal cells along one level axis', () => {
    const l = layoutTimeline({ start: '2026-10-01', end: '2026-10-31', step: 'day', items: [], w: 880, h: 300 })
    expect(l.cellW).toBeCloseTo((880 - 48) / 31)
    expect(dayX(l, day('2026-10-01'))).toBeCloseTo(24 + l.cellW / 2)
    expect(dayAtX(l, dayX(l, day('2026-10-14')))).toBe(day('2026-10-14'))
    expect(dayAtX(l, -50)).toBe(day('2026-10-01'))
    expect(dayAtX(l, 5000)).toBe(day('2026-10-31'))
  })

  it('ticks every step; month and longer on the first of each', () => {
    const iso = (days: number[]) => days.map(isoOf)
    expect(iso(stepTicks(day('2026-10-01'), day('2026-10-29'), 'week'))).toEqual(['2026-10-01', '2026-10-08', '2026-10-15', '2026-10-22', '2026-10-29'])
    expect(iso(stepTicks(day('2026-10-14'), day('2027-02-01'), 'month'))).toEqual(['2026-11-01', '2026-12-01', '2027-01-01', '2027-02-01'])
    expect(iso(stepTicks(day('2026-02-01'), day('2027-01-01'), 'quarter'))).toEqual(['2026-04-01', '2026-07-01', '2026-10-01', '2027-01-01'])
    expect(iso(stepTicks(day('2025-06-01'), day('2028-01-01'), 'year'))).toEqual(['2026-01-01', '2027-01-01', '2028-01-01'])
  })

  it('never lets two tick labels touch, at any width', () => {
    for (const w of [360, 520, 880, 1400]) {
      for (const [start, end, step] of [
        ['2026-01-01', '2026-12-31', 'day'],
        ['2026-01-01', '2026-12-31', 'week'],
        ['2026-10-01', '2027-03-31', 'week'],
        ['2020-01-01', '2035-12-31', 'month'],
      ] as const) {
        const l = layoutTimeline({ start, end, step, items: [], w, h: 300 })
        const labels = l.ticks.filter(t => t.label).map(t => ({ x: t.labelX, hw: (t.label!.length * 6.6) / 2 }))
        for (let i = 1; i < labels.length; i++) expect(labels[i]!.x - labels[i]!.hw).toBeGreaterThan(labels[i - 1]!.x + labels[i - 1]!.hw)
        expect(labels.length).toBeGreaterThan(1)
        for (const t of l.ticks) {
          expect(t.labelX).toBeGreaterThanOrEqual(0)
          expect(t.labelX).toBeLessThanOrEqual(w)
        }
      }
    }
  })

  it('marks the year where a range crosses one', () => {
    const l = layoutTimeline({ start: '2026-10-01', end: '2027-03-31', step: 'month', items: [], w: 880, h: 300 })
    expect(l.subRow).toBe(true)
    expect(l.ticks.filter(t => t.sub).map(t => [isoOf(t.day), t.sub])).toEqual([
      ['2026-10-01', '2026'],
      ['2027-01-01', '2027'],
    ])
    expect(layoutTimeline({ start: '2026-01-01', end: '2026-06-30', step: 'month', items: [], w: 880, h: 300 }).subRow).toBe(false)
  })

  it('lays 25 notes and bubbles and 6 sections out with nothing overlapping', () => {
    for (const w of [520, 880, 1280]) {
      const l = layoutTimeline({ start: '2026-10-01', end: '2026-12-31', step: 'week', items: crowded(), w, h: 300 })
      const boxes = l.pins.filter(p => p.box.w > 0)
      expect(boxes).toHaveLength(25)
      for (let i = 0; i < boxes.length; i++) {
        const a = boxes[i]!.box
        expect(a.x).toBeGreaterThanOrEqual(0)
        expect(a.x + a.w).toBeLessThanOrEqual(w)
        expect(a.y).toBeGreaterThanOrEqual(62)
        expect(a.y + a.h).toBeLessThanOrEqual(l.h)
        for (let j = i + 1; j < boxes.length; j++) expect(overlaps(a, boxes[j]!.box), `${boxes[i]!.item.label} / ${boxes[j]!.item.label} at ${w}`).toBe(false)
        // A stem leaves its own box from inside it.
        expect(boxes[i]!.x).toBeGreaterThanOrEqual(a.x)
        expect(boxes[i]!.x).toBeLessThanOrEqual(a.x + a.w)
        // Boxes clear the axis band: above it, or below the lanes.
        if (boxes[i]!.side === 'above') expect(a.y + a.h).toBeLessThanOrEqual(l.axisY - 10)
        else expect(a.y).toBeGreaterThanOrEqual(l.lanesY + l.lanes * 24)
      }
      // Sections in lanes: none overlapping another in its lane.
      expect(l.outside).toBe(0)
      for (let i = 0; i < l.sections.length; i++)
        for (let j = i + 1; j < l.sections.length; j++) {
          const a = l.sections[i]!
          const b = l.sections[j]!
          if (a.lane === b.lane) expect(a.x + a.w <= b.x || b.x + b.w <= a.x).toBe(true)
        }
      expect(l.sections.find(s => s.item.label === 'Before the range')).toMatchObject({ openLeft: true, openRight: false })
      expect(l.sections.find(s => s.item.label === 'Past the range')).toMatchObject({ openLeft: false, openRight: true })
      expect(l.h).toBeGreaterThan(300)
      expect(l.needed).toBe(l.h)
    }
  })

  it('keeps stems clear of other boxes where it can', () => {
    n = 0
    // Notes a few days apart, mid-card: each later stem would run up through an earlier chip
    // unless the chips below step aside (or lift over it).
    const items = [pin('2026-11-01', 'A long label for the first'), pin('2026-11-05', 'Second label here'), pin('2026-11-09', 'Third one'), pin('2026-11-30', 'Far away')]
    const l = layoutTimeline({ start: '2026-10-01', end: '2026-12-31', step: 'week', items, w: 880, h: 300 })
    for (const p of l.pins)
      for (const q of l.pins) {
        if (p === q || q.tier >= p.tier || p.side !== q.side) continue
        // p's stem runs from its box down to the axis, past every lower tier's box.
        expect(p.x > q.box.x - 1 && p.x < q.box.x + q.box.w + 1, `${p.item.label} through ${q.item.label}`).toBe(false)
      }
    expect(Math.max(...l.pins.map(p => p.tier))).toBeGreaterThan(0)
  })

  it('stacks notes on the same day, the higher stem behind the lower chip', () => {
    n = 0
    const items = [pin('2026-10-10', 'Standup'), pin('2026-10-10', 'Review'), pin('2026-10-10', 'Ship')]
    const l = layoutTimeline({ start: '2026-10-01', end: '2026-12-31', step: 'week', items, w: 880, h: 300 })
    expect(l.pins.map(p => p.tier)).toEqual([0, 1, 2])
    const xs = new Set(l.pins.map(p => p.x))
    expect(xs.size).toBe(1)
  })

  it('counts items outside the range and does not draw them', () => {
    n = 0
    const items = [pin('2026-09-01', 'Early'), pin('2026-10-05', 'In'), section('2027-02-01', '2027-02-10', 'Late')]
    const l = layoutTimeline({ start: '2026-10-01', end: '2026-12-31', step: 'week', items, w: 880, h: 300 })
    expect(l.outside).toBe(2)
    expect(l.pins.map(p => p.item.label)).toEqual(['In'])
    expect(l.sections).toEqual([])
  })

  it('needs no more height than an empty card, and only grows for what it holds', () => {
    const empty = layoutTimeline({ start: '2026-10-01', end: '2026-12-31', step: 'week', items: [], w: 880, h: 300 })
    expect(empty.needed).toBeLessThan(300)
    expect(empty.h).toBe(300)
    // The height never changes which tiers sit above: a taller card only adds room.
    const items = crowded()
    const a = layoutTimeline({ start: '2026-10-01', end: '2026-12-31', step: 'week', items, w: 880, h: 300 })
    const b = layoutTimeline({ start: '2026-10-01', end: '2026-12-31', step: 'week', items, w: 880, h: a.needed + 200 })
    expect(b.pins.map(p => [p.side, p.tier])).toEqual(a.pins.map(p => [p.side, p.tier]))
  })

  it('shows today only inside the range', () => {
    const at = layoutTimeline({ start: '2026-10-01', end: '2026-12-31', step: 'week', items: [], w: 880, h: 300, today: '2026-10-14' })
    expect(at.today).toBeCloseTo(dayX(at, day('2026-10-14')))
    expect(layoutTimeline({ start: '2026-10-01', end: '2026-12-31', step: 'week', items: [], w: 880, h: 300, today: '2027-01-01' }).today).toBeNull()
  })

  it('says spans the way people read them', () => {
    expect(spanText(day('2026-10-01'), day('2026-12-31'))).toBe('Oct 1 – Dec 31, 2026')
    expect(spanText(day('2026-12-01'), day('2027-01-31'))).toBe('Dec 1, 2026 – Jan 31, 2027')
    expect(sectionReadout(day('2026-10-20'), day('2026-11-03'))).toBe('Oct 20 – Nov 3 · 15 days')
    expect(sectionReadout(day('2026-10-20'), day('2026-10-20'))).toBe('Oct 20 · 1 day')
  })
})
