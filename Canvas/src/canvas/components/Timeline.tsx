/**
 * The timeline card: a header (title, range and step), one level axis with a
 * dot at every step, and the items along it — notes (a chip on a stem),
 * bubbles (a short markdown card on a stem) and sections (a band over a span
 * of days, in a colour). Model: `../timeline.ts`; the text it is kept in:
 * `../timeline-text.ts`; where everything goes: `../timeline-layout.ts`.
 *
 * Anyone who can edit works it directly, selected or not, with no edit mode:
 * hover the axis for a day, click it for a note or a bubble, drag along it
 * for a section; click an item to edit it, drag a dot (or its chip) to move
 * it, drag a section's body or edges to shift or stretch it. Focused items
 * take Delete, ↵ and ←/→ (⇧ for a step). The header and the card's empty
 * room still drag the card; selected, the header shows the range and step.
 *
 * Popovers, tips and readouts are this viewer's own state (never stored) and
 * keep their size on screen at any zoom. An edit is one undo step.
 */
import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type KeyboardEvent, type PointerEvent as ReactPointerEvent, type ReactNode } from 'react'
import { Check, ChevronDown } from 'lucide-react'
import { inkOn, paperOf, strokeOf } from '../colors'
import { countRender } from '../debug'
import { INIT } from '../doc'
import { TIMELINE_MIN, addItem, editItem, refOf, removeItem, setRange, setTimelineTitle, timelineMeasure, type ItemPatch, type ItemRef, type TimelineItem } from '../timeline'
import { ITEM_COLORS, STEPS, STEP_WORD, cleanIso, dayOf, isoOf, oneLine, todayIso, type ItemColor, type Step } from '../timeline-text'
import { TL, dayAtX, dayName, dayX, layoutTimeline, sectionReadout, spanText, type LayoutItem, type TimelineLayout } from '../timeline-layout'
import type { Shape, ShapeColor } from '../types'
import { useBoard } from './context'
import { MarkdownLite } from './MarkdownLite'
import { cn, useMountFocus } from './ui'
import './timeline.css'

const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

const STEP_LABEL: Record<Step, string> = { day: 'Day', week: 'Week', month: 'Month', quarter: 'Quarter', year: 'Year' }
const STEP_DAYS: Record<Step, number> = { day: 1, week: 7, month: 30, quarter: 91, year: 365 }
const COLOR_NAME: Record<ItemColor, string> = { yellow: 'Yellow', pink: 'Pink', blue: 'Blue', green: 'Green', purple: 'Purple', gray: 'Gray' }

/** An item's colours as CSS variables: its own, else the card's (neutral on a white or grey card). */
function colorVars(c: ItemColor | null, card: ShapeColor, section = false): CSSProperties {
  if (c)
    return {
      '--tl-c-paper': paperOf(c),
      '--tl-c-stroke': strokeOf(c),
      '--tl-c-ink': inkOn(c),
      '--tl-c-fill': `color-mix(in srgb, var(--paper-${c}) 74%, var(--surface))`,
      '--tl-c-border': `color-mix(in srgb, var(--stroke-${c}) 30%, var(--line))`,
      '--tl-c-text': inkOn(c),
      '--tl-c-title': inkOn(c),
    } as CSSProperties
  if (section) return colorVars('gray', card)
  const accent = card === 'white' || card === 'gray' ? 'var(--ink-3)' : strokeOf(card)
  return {
    '--tl-c-paper': 'var(--surface-2)',
    '--tl-c-stroke': accent,
    '--tl-c-ink': 'var(--ink)',
    '--tl-c-fill': 'var(--surface)',
    '--tl-c-border': 'var(--line-2)',
    '--tl-c-text': 'var(--ink)',
    '--tl-c-title': 'var(--ink)',
  } as CSSProperties
}

const swatchVar = (c: ItemColor) => `var(--swatch-${c})`

// ---- small parts ------------------------------------------------------------------

/** The title, edited in place: every keystroke is the title (peers see it as typed). */
function TitleField({ value, onChange, onDone }: { value: string; onChange: (v: string) => void; onDone: () => void }) {
  const ref = useRef<HTMLInputElement>(null)
  const done = useRef(false)
  useMountFocus(ref)
  useEffect(() => {
    // The press that opened the field may hand focus back to the board; take it back.
    const timer = setTimeout(() => {
      if (!done.current && document.activeElement !== ref.current) ref.current?.focus({ preventScroll: true })
    }, 30)
    return () => {
      clearTimeout(timer)
      done.current = true
    }
  }, [])
  const finish = () => {
    if (done.current) return
    done.current = true
    onDone()
  }
  return (
    <input
      ref={ref}
      aria-label="Timeline title"
      defaultValue={value}
      placeholder="Title"
      maxLength={500}
      spellCheck={false}
      className="tl-title-field"
      onChange={e => onChange(e.currentTarget.value)}
      onBlur={() =>
        setTimeout(() => {
          if (!done.current && document.activeElement !== ref.current) finish()
        }, 80)
      }
      onKeyDown={e => {
        e.stopPropagation()
        if (e.key === 'Enter' || e.key === 'Escape' || e.key === 'Tab') {
          e.preventDefault()
          finish()
        }
      }}
      onPointerDown={stop}
      onDoubleClick={stop}
    />
  )
}

/** A native date field that only reports whole, real days. */
function DateField({ label, value, onChange, className }: { label: string; value: string; onChange: (iso: string) => void; className?: string }) {
  return (
    <input
      type="date"
      aria-label={label}
      className={cn('tl-date', className)}
      value={value}
      required
      onChange={e => {
        const v = cleanIso(e.currentTarget.value)
        if (v) onChange(v)
      }}
      onKeyDown={e => {
        if (e.key !== 'Escape') e.stopPropagation()
      }}
      onPointerDown={stop}
      onDoubleClick={stop}
    />
  )
}

function Swatches({ value, onPick, none = true }: { value: ItemColor | null; onPick: (c: ItemColor | null) => void; none?: boolean }) {
  return (
    <div className="tl-swatches" role="group" aria-label="Colour">
      {none && <button type="button" className="tl-swatch" data-none="" aria-label="No colour" aria-pressed={value === null} onClick={() => onPick(null)} />}
      {ITEM_COLORS.map(c => (
        <button
          key={c}
          type="button"
          className="tl-swatch"
          aria-label={COLOR_NAME[c]}
          aria-pressed={value === c}
          style={{ '--sw': swatchVar(c) } as CSSProperties}
          onClick={() => onPick(c)}
        />
      ))}
    </div>
  )
}

/** Where a popover hangs from: a point in the card, and which way it opens. */
interface Anchor {
  x: number
  y: number
  up: boolean
  /** Centred on x; or reaching right (left) from just short of it; or starting at x (a menu under its button). */
  align: 'center' | 'left' | 'right' | 'start'
}

/**
 * A popover in the card, the same size on screen at any zoom. Escape, or a
 * press anywhere outside it, closes it (`onOutside` decides what that keeps).
 */
function Popover({ at, onOutside, narrow, label, children }: { at: Anchor; onOutside: () => void; narrow?: boolean; label: string; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null)
  const outside = useRef(onOutside)
  useLayoutEffect(() => {
    outside.current = onOutside
  })
  useEffect(() => {
    const onDown = (e: PointerEvent) => {
      if (ref.current && e.target instanceof Node && ref.current.contains(e.target)) return
      outside.current()
    }
    // Next tick: the press that opened it is not outside it.
    const timer = setTimeout(() => document.addEventListener('pointerdown', onDown, true), 0)
    // The board's wheel listener is native: a field that scrolls keeps the wheel to itself.
    const el = ref.current
    const onWheel = (e: WheelEvent) => {
      const box = (e.target as Element).closest?.('textarea, .tl-view-body')
      if (box && !e.ctrlKey && !e.metaKey && box.scrollHeight > box.clientHeight + 1) e.stopPropagation()
    }
    el?.addEventListener('wheel', onWheel)
    return () => {
      clearTimeout(timer)
      document.removeEventListener('pointerdown', onDown, true)
      el?.removeEventListener('wheel', onWheel)
    }
  }, [])
  const tx = at.align === 'start' ? '0' : at.align === 'left' ? '-18px' : at.align === 'right' ? 'calc(-100% + 18px)' : '-50%'
  return (
    <div
      ref={ref}
      role="dialog"
      aria-label={label}
      className={cn('tl-pop', narrow && 'tl-pop-narrow')}
      style={{ left: at.x, top: at.y, transformOrigin: '0 0', transform: `scale(calc(1 / var(--z, 1))) translate(${tx}, ${at.up ? '-100%' : '0'})` }}
      onPointerDown={stop}
      onDoubleClick={stop}
    >
      {children}
    </div>
  )
}

type PinKind = 'note' | 'bubble'

/** Note ⇄ Bubble. */
function KindSwitch({ value, onChange }: { value: PinKind; onChange: (k: PinKind) => void }) {
  return (
    <div className="tl-seg" role="group" aria-label="Kind">
      {(['note', 'bubble'] as const).map(k => (
        <button key={k} type="button" aria-pressed={value === k} onClick={() => onChange(k)}>
          {k === 'note' ? 'Note' : 'Bubble'}
        </button>
      ))}
    </div>
  )
}

/** Keys shared by the popovers' fields: Escape closes; Return (⌘Return in a body) saves. */
function fieldKeys(e: KeyboardEvent<HTMLInputElement | HTMLTextAreaElement>, save: () => void, close: () => void, area = false) {
  e.stopPropagation()
  if (e.key === 'Escape') {
    e.preventDefault()
    close()
  } else if (e.key === 'Enter' && (!area || e.metaKey || e.ctrlKey) && !e.nativeEvent.isComposing) {
    e.preventDefault()
    save()
  }
}

interface NewFields {
  date: string
  end: string | null
  label: string
  color: ItemColor | null
  body: string | null
}

/** A new note, bubble or section at a day (or over a span of days, from a drag). */
function NewPop({
  at,
  start,
  end,
  step,
  sectionColor,
  onAdd,
  onClose,
}: {
  at: Anchor
  start: string
  end: string | null
  step: Step
  sectionColor: ItemColor
  onAdd: (f: NewFields) => void
  onClose: () => void
}) {
  const [kind, setKind] = useState<PinKind | 'section'>(end ? 'section' : 'note')
  const [label, setLabel] = useState('')
  const [body, setBody] = useState('')
  const [color, setColor] = useState<ItemColor | null>(end ? sectionColor : null)
  const [until, setUntil] = useState(end ?? isoOf((dayOf(start) ?? 0) + STEP_DAYS[step] - 1))
  const labelRef = useRef<HTMLInputElement>(null)
  useMountFocus(labelRef)
  const typed = !!(label.trim() || body.trim())
  const can = kind === 'section' || typed
  const save = () => {
    if (!can) return
    const t = oneLine(label).trim()
    if (kind === 'section') onAdd({ date: start, end: until < start ? start : until, label: t, color, body: null })
    else onAdd({ date: start, end: null, label: t, color, body: kind === 'bubble' ? body : null })
  }
  const a = dayOf(start) ?? 0
  const b = dayOf(until) ?? a
  return (
    <Popover at={at} label={kind === 'section' ? 'New section' : 'New item'} onOutside={() => (typed ? save() : onClose())}>
      <div className="tl-pop-head">
        {kind === 'section' ? <span className="tl-pop-title">{sectionReadout(Math.min(a, b), Math.max(a, b))}</span> : <KindSwitch value={kind} onChange={setKind} />}
        {kind !== 'section' && <span className="tl-pop-when">{dayName(a)}</span>}
      </div>
      <input
        ref={labelRef}
        className="tl-field"
        aria-label={kind === 'section' ? 'Section name' : 'Label'}
        placeholder={kind === 'section' ? 'Section name' : kind === 'bubble' ? 'Title' : 'Label'}
        maxLength={200}
        value={label}
        onChange={e => setLabel(e.currentTarget.value)}
        onKeyDown={e => fieldKeys(e, save, onClose)}
      />
      {kind === 'bubble' && (
        <textarea
          className="tl-area"
          aria-label="Bubble text"
          placeholder="Details — markdown works"
          value={body}
          onChange={e => setBody(e.currentTarget.value)}
          onKeyDown={e => fieldKeys(e, save, onClose, true)}
        />
      )}
      {kind === 'section' && (
        <div className="tl-pop-row">
          <span className="tl-label">Ends</span>
          <DateField label="Section end" value={until} onChange={setUntil} />
        </div>
      )}
      <div className="tl-pop-row">
        <Swatches value={color} onPick={setColor} none={kind !== 'section'} />
      </div>
      <div className="tl-pop-foot">
        {kind !== 'section' && (
          <button
            type="button"
            className="tl-btn"
            onClick={() => {
              setKind('section')
              setColor(c => c ?? sectionColor)
              labelRef.current?.focus()
            }}
          >
            Section from here
          </button>
        )}
        <button type="button" className="tl-btn tl-btn-primary" disabled={!can} onClick={save}>
          {kind === 'section' ? 'Add section' : 'Add'}
        </button>
      </div>
    </Popover>
  )
}

/** Change an item: its label, body, dates, colour, Note ⇄ Bubble; or delete it. */
function EditPop({ at, item, onSave, onDelete, onClose }: { at: Anchor; item: TimelineItem; onSave: (p: ItemPatch) => void; onDelete: () => void; onClose: () => void }) {
  const section = item.kind === 'section'
  const [label, setLabel] = useState(item.label)
  const [body, setBody] = useState<string | null>(item.body)
  const [color, setColor] = useState<ItemColor | null>(item.color)
  const [date, setDate] = useState(item.date)
  const [end, setEnd] = useState<string | null>(item.end)
  const kept = useRef(item.body ?? '')
  const labelRef = useRef<HTMLInputElement>(null)
  useMountFocus(labelRef)
  /** Only what changed, so a peer's edit to another field of the item stands. */
  const save = () => {
    const p: ItemPatch = {}
    const t = oneLine(label).trim()
    if (t !== item.label) p.label = t
    if (body !== item.body) p.body = body
    if (color !== item.color) p.color = color
    if (date !== item.date) p.date = date
    if (end !== item.end) p.end = end
    if (Object.keys(p).length) onSave(p)
    else onClose()
  }
  const kind: PinKind = body === null ? 'note' : 'bubble'
  return (
    <Popover at={at} label={section ? 'Edit section' : 'Edit item'} onOutside={save}>
      <div className="tl-pop-head">
        {section ? <span className="tl-pop-title">{sectionReadout(dayOf(date) ?? 0, dayOf(end ?? date) ?? 0)}</span> : (
          <KindSwitch
            value={kind}
            onChange={k => {
              if (k === 'note' && body !== null) kept.current = body
              setBody(k === 'note' ? null : kept.current)
            }}
          />
        )}
        {!section && <span className="tl-pop-when">{dayName(dayOf(date) ?? 0)}</span>}
      </div>
      <input
        ref={labelRef}
        className="tl-field"
        aria-label={section ? 'Section name' : 'Label'}
        placeholder={section ? 'Section name' : kind === 'bubble' ? 'Title' : 'Label'}
        maxLength={200}
        value={label}
        onChange={e => setLabel(e.currentTarget.value)}
        onKeyDown={e => fieldKeys(e, save, onClose)}
      />
      {body !== null && (
        <textarea
          className="tl-area"
          aria-label="Bubble text"
          placeholder="Details — markdown works"
          value={body}
          onChange={e => setBody(e.currentTarget.value)}
          onKeyDown={e => fieldKeys(e, save, onClose, true)}
        />
      )}
      {section ? (
        <>
          <div className="tl-pop-row">
            <span className="tl-label">From</span>
            <DateField label="Section start" value={date} onChange={setDate} />
          </div>
          <div className="tl-pop-row">
            <span className="tl-label">To</span>
            <DateField label="Section end" value={end ?? date} onChange={setEnd} />
          </div>
        </>
      ) : (
        <div className="tl-pop-row">
          <span className="tl-label">Date</span>
          <DateField label="Date" value={date} onChange={setDate} />
        </div>
      )}
      <div className="tl-pop-row">
        <Swatches value={color} onPick={setColor} />
      </div>
      <div className="tl-pop-foot">
        <button type="button" className="tl-btn tl-btn-danger" onClick={onDelete}>
          Delete
        </button>
        <button type="button" className="tl-btn tl-btn-primary" onClick={save}>
          Done
        </button>
      </div>
    </Popover>
  )
}

/** What a viewer who cannot edit sees of an item: all of it. */
function ViewPop({ at, item, onClose, onOpenUrl }: { at: Anchor; item: TimelineItem; onClose: () => void; onOpenUrl: (url: string) => void }) {
  const a = dayOf(item.date) ?? 0
  return (
    <Popover at={at} label={item.label || 'Item'} onOutside={onClose}>
      <div className="tl-pop-head">
        <span className="tl-pop-title">{item.end ? sectionReadout(a, dayOf(item.end) ?? a) : dayName(a)}</span>
      </div>
      {item.label && <div style={{ fontWeight: 600 }}>{item.label}</div>}
      {item.body?.trim() && (
        <div className="tl-view-body">
          <MarkdownLite source={item.body} onOpenUrl={onOpenUrl} />
        </div>
      )}
    </Popover>
  )
}

function StepMenu({ at, step, onPick, onClose }: { at: Anchor; step: Step; onPick: (s: Step) => void; onClose: () => void }) {
  const first = useRef<HTMLButtonElement>(null)
  useEffect(() => first.current?.focus({ preventScroll: true }), [])
  return (
    <Popover at={at} label="Step" narrow onOutside={onClose}>
      <div role="listbox" aria-label="Step">
        {STEPS.map(s => (
          <button
            key={s}
            ref={s === step ? first : undefined}
            type="button"
            role="option"
            aria-selected={s === step}
            className="tl-menu-item"
            onClick={() => onPick(s)}
            onKeyDown={e => {
              e.stopPropagation()
              if (e.key === 'Escape') onClose()
              if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
                e.preventDefault()
                const list = [...(e.currentTarget.parentElement?.children ?? [])] as HTMLElement[]
                const i = list.indexOf(e.currentTarget)
                list[(i + (e.key === 'ArrowDown' ? 1 : list.length - 1)) % list.length]?.focus()
              }
            }}
          >
            {STEP_LABEL[s]}
            {s === step && <Check className="h-3.5 w-3.5" aria-hidden="true" />}
          </button>
        ))}
      </div>
    </Popover>
  )
}

/**
 * The range's start or end in the header: what is typed stays here until it
 * is a whole day worth keeping (a blur, Return, or a pause on a four-digit
 * year), so the year field's partial values never reach the board.
 */
function RangeDate({ label, value, onCommit }: { label: string; value: string; onCommit: (iso: string) => void }) {
  const [draft, setDraft] = useState(value)
  const [prev, setPrev] = useState(value)
  if (value !== prev) {
    setPrev(value)
    setDraft(value)
  }
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => () => {
    if (timer.current) clearTimeout(timer.current)
  }, [])
  const commit = (v: string) => {
    if (timer.current) clearTimeout(timer.current)
    timer.current = null
    const iso = cleanIso(v)
    if (iso && iso !== value && Number(iso.slice(0, 4)) >= 1000) onCommit(iso)
  }
  return (
    <input
      type="date"
      aria-label={label}
      className="tl-date"
      value={draft}
      required
      onChange={e => {
        const v = e.currentTarget.value
        setDraft(v)
        if (timer.current) clearTimeout(timer.current)
        timer.current = setTimeout(() => commit(v), 700)
      }}
      onBlur={e => commit(e.currentTarget.value)}
      onKeyDown={e => {
        if (e.key === 'Enter') {
          e.preventDefault()
          commit(e.currentTarget.value)
        }
        if (e.key === 'Escape') {
          setDraft(value)
          return
        }
        e.stopPropagation()
      }}
      onPointerDown={stop}
      onDoubleClick={stop}
    />
  )
}

type Gesture =
  | { kind: 'span'; a: number; b: number; sx: number; moved: boolean }
  | { kind: 'pin'; item: TimelineItem; d0: number; day0: number; day: number; sx: number; moved: boolean }
  | { kind: 'sec'; item: TimelineItem; mode: 'move' | 'start' | 'end'; d0: number; a0: number; b0: number; a: number; b: number; sx: number; moved: boolean }

type Pop = { kind: 'new'; start: string; end: string | null; at: Anchor } | { kind: 'item'; ref: ItemRef; at: Anchor } | { kind: 'step'; at: Anchor }

const EMPTY = { start: '2026-01-01', end: '2026-03-31', step: 'week' as Step, ranged: false, items: [] as TimelineItem[] }

const sameRef = (it: TimelineItem, r: ItemRef) => it.date === r.date && it.end === r.end && it.label === r.label
const findLive = (items: readonly TimelineItem[], r: ItemRef) => {
  const at = items[r.index]
  return at && sameRef(at, r) ? at : items.find(it => sameRef(it, r))
}

/** Where the lanes (or, without sections, the tick labels) end. */
const bandBottom = (l: TimelineLayout) => (l.lanes ? l.lanesY + l.lanes * TL.lane + (l.lanes - 1) * TL.laneGap : l.labelsY + TL.labelH + (l.subRow ? TL.subH : 0))

export const TimelineView = memo(function TimelineView({
  shape,
  editing,
  selected,
}: {
  shape: Shape
  /** The board's edit field when this card is being edited, else null. */
  editing: string | null
  selected: boolean
}) {
  countRender('shapeRenders')
  const board = useBoard()
  const { store, readOnly } = board
  const data = shape.timeline ?? EMPTY
  const card = useRef<HTMLDivElement>(null)
  const today = todayIso()
  const measure = timelineMeasure()
  const base = useMemo(() => layoutTimeline({ ...data, w: shape.w, h: shape.h, today, measure }), [data, shape.w, shape.h, today, measure])

  const gesture = useRef<Gesture | null>(null)
  const [drag, setDrag] = useState<Gesture | null>(null)
  /** The day under the pointer on the axis. */
  const [hover, setHover] = useState<number | null>(null)
  /** The item under the pointer (its index), to light its dot, stem and box together. */
  const [hot, setHot] = useState<number | null>(null)
  const [pop, setPop] = useState<Pop | null>(null)
  /** An item to give the keyboard back to once it has moved (its index and part). */
  const refocus = useRef<{ index: number; part: string } | null>(null)

  // The layout with the dragged item where the pointer has it.
  const layout = useMemo(() => {
    if (!drag || !drag.moved || drag.kind === 'span') return base
    const items: LayoutItem[] = data.items.map(it => {
      if (it.index !== drag.item.index) return it
      return drag.kind === 'pin' ? { ...it, date: isoOf(drag.day) } : { ...it, date: isoOf(drag.a), end: isoOf(drag.b) }
    })
    return layoutTimeline({ ...data, items, w: shape.w, h: base.h, today, measure })
  }, [drag, base, data, shape.w, today, measure])
  const H = Math.max(layout.h, TIMELINE_MIN.h)

  // ---- the card is as tall as its content (written by editors, outside undo) -------
  useEffect(() => {
    if (readOnly) return
    const need = Math.ceil(base.needed)
    if (need > shape.h + 0.5) store.update(shape.id, { h: need }, INIT, false)
  }, [readOnly, base.needed, shape.h, shape.id, store])

  useLayoutEffect(() => {
    const want = refocus.current
    if (!want || !card.current) return
    refocus.current = null
    card.current.querySelector<HTMLElement>(`[data-item="${want.index}"][data-focus="${want.part}"]`)?.focus({ preventScroll: true })
  })

  // A peer deleted the item whose editor is open: close it.
  const popItem = pop?.kind === 'item' ? findLive(data.items, pop.ref) : undefined
  if (pop?.kind === 'item' && !popItem) setPop(null)

  // ---- geometry ----------------------------------------------------------------------
  const scale = () => {
    const r = card.current?.getBoundingClientRect()
    return { r, s: r && shape.w ? r.width / shape.w : 1 }
  }
  const dayAtClient = (clientX: number) => {
    const { r, s } = scale()
    return dayAtX(base, r ? (clientX - r.left) / s : 0)
  }
  /** A popover's anchor under the axis band at `x`, turned up or sideways to stay on screen. */
  const anchorAt = (x: number): Anchor => {
    const below = bandBottom(base) + 10
    const { r, s } = scale()
    let up = false
    let align: Anchor['align'] = 'center'
    if (r) {
      const room = card.current?.closest('[role="application"]')?.getBoundingClientRect() ?? { left: 0, top: 0, right: innerWidth, bottom: innerHeight }
      const sx = r.left + x * s
      const sy = r.top + below * s
      if (sy + 300 > room.bottom && r.top + (base.axisY - 16) * s - 300 > room.top) up = true
      if (sx - 140 < room.left + 8) align = 'left'
      else if (sx + 140 > room.right - 8) align = 'right'
    }
    return { x, y: up ? base.axisY - 16 : below, up, align }
  }
  const xOf = (day: number) => dayX(base, day)
  const clampDay = (d: number) => Math.min(base.endDay, Math.max(base.startDay, d))

  // ---- gestures: one press, the window's moves, one release ----------------------------
  const finish = (g: Gesture) => {
    switch (g.kind) {
      case 'span': {
        if (!g.moved) {
          setPop({ kind: 'new', start: isoOf(g.a), end: null, at: anchorAt(xOf(g.a)) })
          return
        }
        const a = Math.min(g.a, g.b)
        const b = Math.max(g.a, g.b)
        setPop({ kind: 'new', start: isoOf(a), end: isoOf(b), at: anchorAt((xOf(a) + xOf(b)) / 2) })
        return
      }
      case 'pin':
        if (g.moved && g.day !== g.day0) {
          store.undo.stopCapturing()
          editItem(store, shape.id, refOf(g.item), { date: isoOf(g.day) })
          store.undo.stopCapturing()
        } else if (!g.moved) openItem(g.item, xOf(g.day0))
        return
      case 'sec':
        if (g.moved && (g.a !== g.a0 || g.b !== g.b0)) {
          store.undo.stopCapturing()
          editItem(store, shape.id, refOf(g.item), { date: isoOf(g.a), end: isoOf(g.b) })
          store.undo.stopCapturing()
        } else if (!g.moved) openItem(g.item, xOf(clampDay(Math.round((g.a0 + g.b0) / 2))))
    }
  }
  const begin = (e: ReactPointerEvent, g: Gesture) => {
    e.stopPropagation()
    e.preventDefault()
    gesture.current = g
    setHover(null)
    const move = (ev: PointerEvent) => {
      const cur = gesture.current
      if (!cur || (!cur.moved && Math.abs(ev.clientX - cur.sx) < 4)) return
      const d = dayAtClient(ev.clientX)
      let next: Gesture
      if (cur.kind === 'span') next = { ...cur, moved: true, b: d }
      else if (cur.kind === 'pin') next = { ...cur, moved: true, day: clampDay(cur.day0 + d - cur.d0) }
      else {
        const by = d - cur.d0
        if (cur.mode === 'move') next = { ...cur, moved: true, a: cur.a0 + by, b: cur.b0 + by }
        else if (cur.mode === 'start') next = { ...cur, moved: true, a: Math.min(cur.a0 + by, cur.b0), b: cur.b0 }
        else next = { ...cur, moved: true, a: cur.a0, b: Math.max(cur.b0 + by, cur.a0) }
      }
      gesture.current = next
      setDrag(next)
    }
    const end = (ev: PointerEvent) => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', end)
      window.removeEventListener('pointercancel', end)
      const cur = gesture.current
      gesture.current = null
      setDrag(null)
      if (cur && ev.type === 'pointerup') finish(cur)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', end)
    window.addEventListener('pointercancel', end)
  }

  const openItem = (it: TimelineItem, x: number) => {
    setHot(null)
    setPop({ kind: 'item', ref: refOf(it), at: anchorAt(x) })
  }
  const onAxisDown = (e: ReactPointerEvent) => {
    if (readOnly || e.button !== 0) return
    const d = dayAtClient(e.clientX)
    begin(e, { kind: 'span', a: d, b: d, sx: e.clientX, moved: false })
  }
  const onPinDown = (it: TimelineItem) => (e: ReactPointerEvent) => {
    if (e.button !== 0) return
    const day0 = dayOf(it.date) ?? 0
    if (readOnly) {
      e.stopPropagation()
      openItem(it, xOf(day0))
      return
    }
    begin(e, { kind: 'pin', item: it, d0: dayAtClient(e.clientX), day0, day: day0, sx: e.clientX, moved: false })
  }
  const onSectionDown = (it: TimelineItem, mode: 'move' | 'start' | 'end') => (e: ReactPointerEvent) => {
    if (e.button !== 0) return
    const a0 = dayOf(it.date) ?? 0
    const b0 = dayOf(it.end ?? it.date) ?? a0
    if (readOnly) {
      e.stopPropagation()
      openItem(it, xOf(clampDay(Math.round((a0 + b0) / 2))))
      return
    }
    begin(e, { kind: 'sec', item: it, mode, d0: dayAtClient(e.clientX), a0, b0, a: a0, b: b0, sx: e.clientX, moved: false })
  }

  // ---- the keyboard on a focused item ----------------------------------------------------
  /**
   * Where the last key sent an item, until the card draws it there: a key
   * repeating faster than a render still finds the item it just moved.
   */
  const moved = useRef<{ from: string; to: ItemRef } | null>(null)
  const keyOf = (r: ItemRef) => `${r.index}|${r.date}|${r.end ?? ''}|${r.label}`
  const current = (it: TimelineItem): ItemRef => {
    const r = refOf(it)
    const m = moved.current
    return m && m.from === keyOf(r) ? m.to : r
  }
  const toBoard = (el: Element) => (el.closest('[role="application"]') as HTMLElement | null)?.focus({ preventScroll: true })
  const itemKeys = (it: TimelineItem, part: string, x: number) => (e: KeyboardEvent<HTMLElement>) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      e.stopPropagation()
      openItem(it, x)
      return
    }
    if (e.key === 'Escape') {
      e.stopPropagation()
      toBoard(e.currentTarget)
      return
    }
    if (readOnly) return
    if (e.key === 'Delete' || e.key === 'Backspace') {
      e.preventDefault()
      e.stopPropagation()
      store.undo.stopCapturing()
      removeItem(store, shape.id, current(it))
      toBoard(e.currentTarget)
      return
    }
    if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      e.preventDefault()
      e.stopPropagation()
      const ref = current(it)
      const by = (e.key === 'ArrowLeft' ? -1 : 1) * (e.shiftKey ? STEP_DAYS[data.step] : 1)
      const date = isoOf((dayOf(ref.date) ?? 0) + by)
      const end = ref.end ? isoOf((dayOf(ref.end) ?? 0) + by) : null
      store.undo.stopCapturing()
      const index = editItem(store, shape.id, ref, end ? { date, end } : { date })
      if (index < 0) return
      moved.current = { from: keyOf(refOf(it)), to: { index, date, end, label: ref.label } }
      refocus.current = { index, part }
    }
  }

  // ---- what is drawn -------------------------------------------------------------------
  const accent = shape.color === 'white' ? 'var(--surface-2)' : paperOf(shape.color)
  const bandInk = shape.color === 'white' ? 'var(--ink)' : inkOn(shape.color)
  const titleText = shape.title.trim()
  const span = spanText(base.startDay, base.endDay)
  const summary = `${span} · ${STEP_WORD[data.step]}`
  const axisTop = layout.axisY - 14
  const hitBottom = layout.labelsY + TL.labelH + (layout.subRow ? TL.subH : 0)
  const showSettings = selected && !readOnly
  const tipDay = drag?.kind === 'pin' && drag.moved ? drag.day : !drag && !pop && hover !== null ? hover : null
  const newPop = pop?.kind === 'new' ? pop : null
  const spanBand =
    drag?.kind === 'span' && drag.moved
      ? { a: Math.min(drag.a, drag.b), b: Math.max(drag.a, drag.b) }
      : newPop?.end
        ? { a: dayOf(newPop.start) ?? 0, b: dayOf(newPop.end) ?? 0 }
        : null
  const ghost = newPop && !newPop.end ? (dayOf(newPop.start) ?? null) : tipDay
  const secDrag = drag?.kind === 'sec' && drag.moved ? drag : null
  const empty = data.items.length === 0
  const live = drag && drag.kind !== 'span' && drag.moved ? drag.item.index : null

  const openStep = (el: HTMLElement) => {
    const { r, s } = scale()
    const b = el.getBoundingClientRect()
    if (!r) return
    setPop({ kind: 'step', at: { x: (b.left - r.left) / s, y: (b.bottom - r.top) / s + 4 / s, up: false, align: 'start' } })
  }

  return (
    <div
      ref={card}
      data-id={shape.id}
      data-kind="timeline"
      role="group"
      aria-label={titleText ? `Timeline: ${titleText}` : 'Timeline'}
      aria-readonly={readOnly || undefined}
      className={cn('tl-card baked-shadow baked-shadow-12 absolute left-0 top-0', selected && 'tl-selected')}
      style={
        {
          width: shape.w,
          height: H,
          transform: `translate(${shape.x}px, ${shape.y}px)`,
          '--tl-band': accent,
          '--tl-band-ink': bandInk,
          ...(pop ? { zIndex: 5 } : {}),
        } as CSSProperties
      }
    >
      <div className="tl-head" data-part="tl-title">
        <div className="tl-title-row">
          {editing === 'part:tl-title' && !readOnly ? (
            <TitleField value={shape.title} onChange={t => setTimelineTitle(store, shape.id, t)} onDone={() => board.endEdit(shape.id)} />
          ) : (
            <span className={cn('tl-title', !titleText && 'tl-muted')}>{titleText || 'Untitled'}</span>
          )}
        </div>
        <div className="tl-sub">
          {showSettings ? (
            <div className="tl-settings">
              <RangeDate label="Start" value={data.start} onCommit={start => setRange(store, shape.id, { start })} />
              <span className="tl-arrow" aria-hidden="true">
                →
              </span>
              <RangeDate label="End" value={data.end} onCommit={end => setRange(store, shape.id, { end })} />
              <button
                type="button"
                className="tl-step-btn"
                aria-haspopup="listbox"
                aria-expanded={pop?.kind === 'step'}
                aria-label={`Step: ${STEP_LABEL[data.step]}`}
                onPointerDown={stop}
                onDoubleClick={stop}
                onClick={e => (pop?.kind === 'step' ? setPop(null) : openStep(e.currentTarget))}
                onKeyDown={stop}
              >
                {STEP_WORD[data.step][0]!.toUpperCase() + STEP_WORD[data.step].slice(1)}
                <ChevronDown className="h-3 w-3" aria-hidden="true" />
              </button>
            </div>
          ) : (
            <span className="tl-summary">{summary}</span>
          )}
          {layout.outside > 0 && (
            <span className="tl-outside" title="Kept in the text; widen the range to see them">
              +{layout.outside} outside range
            </span>
          )}
        </div>
      </div>

      <svg className="tl-lines" width={shape.w} height={H} aria-hidden="true">
        {layout.today !== null && <line className="tl-today-line" x1={layout.today} x2={layout.today} y1={TL.head + 18} y2={layout.axisY + 6} />}
        {layout.pins.map(p => {
          if (p.box.w === 0) return null
          const y1 = p.side === 'above' ? layout.axisY - 5 : layout.axisY + 5
          const y2 = p.side === 'above' ? p.box.y + p.box.h : p.box.y
          const vars = colorVars(p.item.color, shape.color)
          return (
            <line
              key={p.item.index}
              className="tl-stem"
              data-hot={hot === p.item.index || live === p.item.index || undefined}
              x1={p.x}
              x2={p.x}
              y1={y1}
              y2={y2}
              style={{ '--tl-stem': `color-mix(in srgb, ${String((vars as Record<string, string>)['--tl-c-stroke'])} 42%, var(--line-2))`, '--tl-stem-hot': (vars as Record<string, string>)['--tl-c-stroke'] } as CSSProperties}
            />
          )
        })}
        <line className="tl-axis" x1={layout.x0 - 6} x2={layout.x1 + 6} y1={layout.axisY} y2={layout.axisY} />
        {layout.ticks.map(t =>
          t.dot ? <circle key={t.day} className="tl-tick-dot" data-major={t.major || undefined} data-hot={ghost === t.day || undefined} cx={t.x} cy={layout.axisY} r={ghost === t.day ? 3.4 : t.major ? 2.4 : 1.8} /> : null
        )}
      </svg>

      {layout.today !== null && (
        <span className="tl-today" style={{ left: layout.today, top: TL.head + 4 }}>
          Today
        </span>
      )}

      {layout.ticks.map(t =>
        t.label ? (
          <span key={`l${t.day}`} className="tl-tick" style={{ left: t.labelX, top: layout.labelsY }}>
            {t.label}
          </span>
        ) : null
      )}
      {layout.ticks.map(t =>
        t.sub ? (
          <span key={`s${t.day}`} className="tl-tick tl-tick-sub" style={{ left: t.subX, top: layout.labelsY + TL.labelH }}>
            {t.sub}
          </span>
        ) : null
      )}

      <div
        className="tl-axis-hit"
        data-readonly={readOnly || undefined}
        style={{ left: layout.x0, width: layout.x1 - layout.x0, top: axisTop, height: hitBottom - axisTop }}
        onPointerDown={onAxisDown}
        onPointerMove={e => {
          if (!gesture.current) setHover(dayAtClient(e.clientX))
        }}
        onPointerLeave={() => setHover(null)}
      />

      {spanBand && (
        <div
          className="tl-span"
          style={{ left: xOf(spanBand.a) - base.cellW / 2, width: (spanBand.b - spanBand.a + 1) * base.cellW, top: layout.axisY - 9, height: 18 }}
        />
      )}
      {ghost !== null && <div className="tl-ghost" style={{ left: xOf(ghost), top: layout.axisY }} />}

      {layout.sections.map(sec => {
        const it = sec.item as TimelineItem
        const a = dayOf(it.date) ?? 0
        const b = dayOf(it.end ?? it.date) ?? a
        const x = xOf(clampDay(Math.round((a + b) / 2)))
        return (
          <div
            key={it.index}
            role="button"
            tabIndex={0}
            data-item={it.index}
            data-focus="sec"
            className="tl-sec"
            data-hot={hot === it.index || live === it.index || undefined}
            data-open-left={sec.openLeft || undefined}
            data-open-right={sec.openRight || undefined}
            data-readonly={readOnly || undefined}
            aria-label={`${it.label || 'Section'}, ${sectionReadout(a, b)}`}
            style={{ left: sec.x, top: sec.y, width: sec.w, height: sec.h, ...colorVars(it.color, shape.color, true) }}
            onPointerDown={onSectionDown(it, 'move')}
            onPointerEnter={() => setHot(it.index)}
            onPointerLeave={() => setHot(h => (h === it.index ? null : h))}
            onKeyDown={itemKeys(it, 'sec', x)}
            onDoubleClick={stop}
          >
            <span className="tl-sec-label">{it.label}</span>
            {!readOnly && !sec.openLeft && <span className="tl-sec-edge" data-side="start" onPointerDown={onSectionDown(it, 'start')} />}
            {!readOnly && !sec.openRight && <span className="tl-sec-edge" data-side="end" onPointerDown={onSectionDown(it, 'end')} />}
          </div>
        )
      })}

      {layout.pins.map(p => {
        const it = p.item as TimelineItem
        const vars = colorVars(it.color, shape.color)
        const lit = hot === it.index || live === it.index || undefined
        const day = dayOf(it.date) ?? 0
        const name = `${it.label || (it.kind === 'bubble' ? 'Bubble' : 'Note')}, ${dayName(day)}`
        const common = {
          'data-item': it.index,
          onPointerDown: onPinDown(it),
          onPointerEnter: () => setHot(it.index),
          onPointerLeave: () => setHot((h: number | null) => (h === it.index ? null : h)),
          onDoubleClick: stop,
        }
        return (
          <div key={it.index} style={vars}>
            <button
              type="button"
              className="tl-dot"
              data-focus="dot"
              data-hot={lit}
              data-readonly={readOnly || undefined}
              aria-label={name}
              style={{ left: p.x, top: layout.axisY }}
              onKeyDown={itemKeys(it, 'dot', p.x)}
              {...common}
            />
            {p.box.w > 0 && it.kind !== 'bubble' && (
              <div
                role="button"
                tabIndex={-1}
                className="tl-chip"
                data-focus="chip"
                data-hot={lit}
                aria-hidden="true"
                style={{ left: p.box.x, top: p.box.y, width: p.box.w }}
                {...common}
              >
                <span className="tl-chip-text">{it.label}</span>
              </div>
            )}
            {p.box.w > 0 && it.kind === 'bubble' && (
              <Bubble item={it} box={p.box} side={p.side} x={p.x} lines={p.lines} lit={!!lit} {...common} />
            )}
          </div>
        )
      })}

      {empty && !readOnly && !pop && hover === null && (
        <p className="tl-empty" style={{ top: layout.axisY - 46 }}>
          Click the line to add a note, or drag along it for a section
        </p>
      )}

      {tipDay !== null && (
        <div className="tl-tip" style={{ left: xOf(tipDay), top: layout.axisY + 8 }}>
          {dayName(tipDay)}
        </div>
      )}
      {spanBand && drag?.kind === 'span' && (
        <div className="tl-tip" style={{ left: (xOf(spanBand.a) + xOf(spanBand.b)) / 2, top: layout.axisY + 11 }}>
          {sectionReadout(spanBand.a, spanBand.b)}
        </div>
      )}
      {secDrag && (
        // Just over the band being dragged (over the tick labels, clear of the items above).
        <div
          className="tl-tip tl-tip-up"
          style={{
            left: (xOf(clampDay(secDrag.a)) + xOf(clampDay(secDrag.b))) / 2,
            top: (layout.sections.find(sec => sec.item.index === secDrag.item.index)?.y ?? layout.axisY) - 3,
          }}
        >
          {sectionReadout(secDrag.a, secDrag.b)}
        </div>
      )}

      {newPop && (
        <NewPop
          key={`${newPop.start}:${newPop.end ?? ''}`}
          at={newPop.at}
          start={newPop.start}
          end={newPop.end}
          step={data.step}
          sectionColor={nextSectionColor(data.items)}
          onClose={() => setPop(null)}
          onAdd={f => {
            store.undo.stopCapturing()
            addItem(store, shape.id, f)
            store.undo.stopCapturing()
            setPop(null)
          }}
        />
      )}
      {pop?.kind === 'item' && popItem && !readOnly && (
        <EditPop
          key={`${pop.ref.index}:${pop.ref.date}:${pop.ref.label}`}
          at={pop.at}
          item={popItem}
          onClose={() => setPop(null)}
          onSave={p => {
            store.undo.stopCapturing()
            editItem(store, shape.id, pop.ref, p)
            store.undo.stopCapturing()
            setPop(null)
          }}
          onDelete={() => {
            store.undo.stopCapturing()
            removeItem(store, shape.id, pop.ref)
            setPop(null)
          }}
        />
      )}
      {pop?.kind === 'item' && popItem && readOnly && <ViewPop at={pop.at} item={popItem} onClose={() => setPop(null)} onOpenUrl={board.openUrl} />}
      {pop?.kind === 'step' && (
        <StepMenu
          at={pop.at}
          step={data.step}
          onClose={() => setPop(null)}
          onPick={step => {
            store.undo.stopCapturing()
            setRange(store, shape.id, { step })
            store.undo.stopCapturing()
            setPop(null)
          }}
        />
      )}
    </div>
  )
})

/** A section's colour no other section wears yet (blue first). */
function nextSectionColor(items: readonly TimelineItem[]): ItemColor {
  const used = new Set(items.filter(it => it.kind === 'section').map(it => it.color))
  return (['blue', 'green', 'purple', 'pink', 'yellow', 'gray'] as const).find(c => !used.has(c)) ?? 'blue'
}

/** A bubble: its label, then as much of its body as fits, faded where it is cut. */
function Bubble({
  item,
  box,
  side,
  x,
  lines,
  lit,
  ...handlers
}: {
  item: TimelineItem
  box: { x: number; y: number; w: number; h: number }
  side: 'above' | 'below'
  x: number
  lines: number
  lit: boolean
  'data-item': number
  onPointerDown: (e: ReactPointerEvent) => void
  onPointerEnter: () => void
  onPointerLeave: () => void
  onDoubleClick: (e: { stopPropagation: () => void }) => void
}) {
  const body = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    const el = body.current
    if (!el) return
    if (el.scrollHeight > el.clientHeight + 1) el.setAttribute('data-cut', '')
    else el.removeAttribute('data-cut')
  })
  const tail = Math.min(box.w - 12, Math.max(12, x - box.x))
  return (
    <div
      role="button"
      tabIndex={-1}
      className="tl-bubble"
      data-focus="bubble"
      data-side={side}
      data-hot={lit || undefined}
      aria-hidden="true"
      style={{ left: box.x, top: box.y, width: box.w, height: box.h }}
      {...handlers}
    >
      {(item.label || !lines) && <div className="tl-bubble-title">{item.label || 'Untitled'}</div>}
      {lines > 0 && (
        <div ref={body} className="tl-bubble-body" style={{ height: lines * TL.bubbleLine }}>
          <MarkdownLite source={item.body ?? ''} />
        </div>
      )}
      <span className="tl-tail" style={{ left: tail }} />
    </div>
  )
}

