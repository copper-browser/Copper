/**
 * Who a checklist row is assigned to, on the card: small avatars at the
 * row's end, and the picker that sets them. The picker lists the people on
 * the canvas — the same list chat's @ picker shows, you among them — then
 * names already used on the board, then whatever name you type; it filters
 * as you type, moves with the arrow keys and takes several people (a click or
 * Return on someone puts them on the row, or takes them off). Model and
 * rules: `../checklist.ts` (`setRowAssignees`), `../assignees.ts` (the list).
 *
 * The popover lives in the card (so it pans and zooms with it) but is drawn
 * the same size on screen at any zoom, like the timeline's.
 */
import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type KeyboardEvent, type ReactNode } from 'react'
import { Check, UserPlus } from 'lucide-react'
import { ago, samePerson } from '../checklist'
import { assignOptions, personColor, type AssignOption } from '../assignees'
import { chat } from '../chat'
import { initials } from '../colors'
import type { ChecklistAssignee } from '../types'
import { cn } from './ui'

const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

/** One face: initials on the person's colour; yours gets a ring. */
export function Face({ name, color, mine, size = 20, className }: { name: string; color: string; mine?: boolean; size?: number; className?: string }) {
  return (
    <span
      aria-hidden="true"
      className={cn('cl-face', mine && 'cl-face-me', className)}
      style={{ width: size, height: size, fontSize: size <= 20 ? 9 : 10.5, background: color }}
    >
      {initials(name)}
    </span>
  )
}

/** "Collin Rijock · assigned by Ann, 4 min ago". */
export function assignedLine(p: ChecklistAssignee, name = p.name, now = Date.now()) {
  const when = p.at ? ago(p.at, now) : ''
  const by = p.by ? `assigned by ${p.by}${when ? `, ${when}` : ''}` : ''
  return [name, by].filter(Boolean).join(' · ')
}

/** The most faces a row shows before "+N". */
const MAX_FACES = 3

/**
 * A row's people at its end. A click (anywhere on them) opens the picker,
 * where each can be taken off or others added; read-only, they only say who.
 */
export function PeopleChips({
  people,
  nameOf,
  me,
  rowName,
  readOnly,
  open,
  onOpen,
}: {
  people: readonly ChecklistAssignee[]
  /** The name to show: someone on the canvas by their name there now (renames follow), else as written. */
  nameOf: (p: ChecklistAssignee) => string
  me: string
  rowName: string
  readOnly: boolean
  open: boolean
  onOpen: () => void
}) {
  const [tip, setTip] = useState<string | null>(null)
  if (!people.length) return null
  const shown = people.length > MAX_FACES ? people.slice(0, MAX_FACES - 1) : people
  const more = people.length - shown.length
  const names = people.map(nameOf)
  const label = `${rowName}: assigned to ${names.join(', ')}`
  const faces = (
    <>
      {shown.map((p, i) => (
        <span key={`${p.id ?? ''}:${p.name}`} className="cl-face-slot" onPointerEnter={() => setTip(assignedLine(p, names[i]))} onPointerLeave={() => setTip(null)}>
          <Face name={names[i]!} color={personColor(p)} mine={!!p.id && p.id === me} />
        </span>
      ))}
      {more > 0 && (
        <span className="cl-face-slot" onPointerEnter={() => setTip(names.slice(shown.length).join(', '))} onPointerLeave={() => setTip(null)}>
          <span className="cl-face cl-face-more" aria-hidden="true">
            +{more}
          </span>
        </span>
      )}
      {tip && (
        <span className="cl-tip cl-people-tip" role="presentation">
          {tip}
        </span>
      )}
    </>
  )
  if (readOnly)
    return (
      <span className="cl-people" role="img" aria-label={label}>
        {faces}
      </span>
    )
  return (
    <button
      type="button"
      className="cl-people cl-people-btn"
      aria-label={`${label}. Change`}
      aria-haspopup="listbox"
      aria-expanded={open}
      onPointerDown={stop}
      onDoubleClick={stop}
      onClick={e => {
        e.stopPropagation()
        setTip(null)
        onOpen()
      }}
    >
      {faces}
    </button>
  )
}

/** Where a popover sits in the card (card px): its top-left, or its bottom-left when it opens upward. */
export interface PopAnchor {
  x: number
  y: number
  up: boolean
  /** Reach left from x (right-aligned) rather than right. */
  left: boolean
}

/** The picker's anchor under (or over) `el`, at its right end (or its left with `start`), in `card` px. */
export function anchorUnder(el: HTMLElement, card: HTMLElement, cardW: number, start = false): PopAnchor {
  const r = el.getBoundingClientRect()
  const c = card.getBoundingClientRect()
  const s = cardW ? c.width / cardW || 1 : 1
  const room = card.closest('[role="application"]')?.getBoundingClientRect() ?? { top: 0, bottom: innerHeight, left: 0, right: innerWidth }
  const up = r.bottom + 300 > room.bottom && r.top - 300 > room.top
  const y = ((up ? r.top - 4 : r.bottom + 4) - c.top) / s
  // Right-aligned at its end, unless that would run off the board's left edge.
  const left = !start && r.right - 280 > room.left + 8
  return { x: ((left ? r.right : r.left) - c.left) / s, y, up, left }
}

/** The popover itself: in the card, the same size on screen at any zoom. A press outside it, or Escape, closes it. */
export function PeoplePop({
  at,
  label,
  onOutside,
  noteRow,
  children,
}: {
  at: PopAnchor
  label: string
  onOutside: () => void
  /** The row whose comment stays open while this is (its editor checks focus against it). */
  noteRow?: string
  children: ReactNode
}) {
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
    // The board's wheel listener is native: the list keeps the wheel while it scrolls.
    const el = ref.current
    const onWheel = (e: WheelEvent) => {
      const box = (e.target as Element).closest?.('.cl-pick-list')
      if (box && !e.ctrlKey && !e.metaKey && box.scrollHeight > box.clientHeight + 1) e.stopPropagation()
    }
    el?.addEventListener('wheel', onWheel)
    return () => {
      clearTimeout(timer)
      document.removeEventListener('pointerdown', onDown, true)
      el?.removeEventListener('wheel', onWheel)
    }
  }, [])
  return (
    <div
      ref={ref}
      role="dialog"
      aria-label={label}
      data-note-row={noteRow}
      className="cl-pick"
      style={{
        left: at.x,
        top: at.y,
        transformOrigin: '0 0',
        transform: `scale(calc(1 / var(--z, 1))) translate(${at.left ? '-100%' : '0'}, ${at.up ? '-100%' : '0'})`,
      }}
      onPointerDown={stop}
      onDoubleClick={stop}
      onWheel={stop}
    >
      {children}
    </div>
  )
}

/** The list of people: who is on the row is ticked; the active one answers Return. */
export function PeopleList({
  id,
  options,
  active,
  on,
  heading,
  onHover,
  onPick,
}: {
  id: string
  options: readonly AssignOption[]
  active: number
  /** Whether someone is on the row now. */
  on: (o: AssignOption) => boolean
  heading?: string
  onHover: (i: number) => void
  onPick: (o: AssignOption) => void
}) {
  const list = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    list.current?.querySelector<HTMLElement>(`[data-index="${active}"]`)?.scrollIntoView?.({ block: 'nearest' })
  }, [active])
  return (
    <div ref={list} id={id} role="listbox" aria-label={heading ?? 'People'} aria-multiselectable="true" className="cl-pick-list" onMouseDown={e => e.preventDefault()}>
      {heading && <p className="cl-pick-head">{heading}</p>}
      {options.map((o, i) => {
        const picked = on(o)
        return (
          <div
            key={o.key}
            id={`${id}-${i}`}
            role="option"
            aria-selected={picked}
            data-index={i}
            data-name={o.name}
            className={cn('cl-pick-item', i === active && 'cl-pick-active')}
            onMouseEnter={() => onHover(i)}
            onClick={e => {
              e.stopPropagation()
              onPick(o)
            }}
          >
            {o.fresh ? (
              <span className="cl-face cl-face-new" aria-hidden="true">
                <UserPlus className="h-3 w-3" />
              </span>
            ) : (
              <Face name={o.name} color={o.color} mine={o.me} size={22} />
            )}
            <span className="cl-pick-text">
              <span className="cl-pick-name">
                {o.fresh ? `Assign “${o.name}”` : o.name}
                {o.me && <span className="cl-pick-you"> (you)</span>}
              </span>
              {!o.fresh && o.email && o.email !== o.name && <span className="cl-pick-email">{o.email}</span>}
            </span>
            {picked && <Check className="cl-pick-check" aria-hidden="true" />}
          </div>
        )
      })}
    </div>
  )
}

/** Arrow keys through a list; true when the key was theirs. */
export function listKeys(e: KeyboardEvent, count: number, setActive: (fn: (a: number) => number) => void): boolean {
  if (!count || (e.key !== 'ArrowDown' && e.key !== 'ArrowUp')) return false
  e.preventDefault()
  const d = e.key === 'ArrowDown' ? 1 : -1
  setActive(a => (a + d + count) % count)
  return true
}

/** What the picker says above the list: whose list it is, or that it is still coming. */
export function pickerHeading(): string | undefined {
  if (!chat.config.enabled) return undefined
  return chat.config.membersKnown ? 'People on this canvas' : 'Loading the people on this canvas…'
}

/**
 * The picker opened from a row (its button, its people, or `@` with the row
 * focused): a field that filters, and the list. Return or a click puts the
 * person on the row or takes them off, and the field clears for the next;
 * Escape (or a press outside) closes it.
 */
export function AssignSearch({
  at,
  rowId,
  rowName,
  assigned,
  board,
  me,
  onToggle,
  onClose,
}: {
  at: PopAnchor
  rowId: string
  rowName: string
  assigned: readonly ChecklistAssignee[]
  /** Names already used on the board's checklists. */
  board: readonly ChecklistAssignee[]
  me: string
  onToggle: (o: AssignOption) => void
  /** `key`: Escape or Tab, which hands focus back to the row. */
  onClose: (how: 'key' | 'away') => void
}) {
  // The people on the canvas can arrive (or change) while it is open.
  useSyncExternalStore(chat.subscribe, chat.getVersion)
  const field = useRef<HTMLInputElement>(null)
  const [query, setQuery] = useState('')
  const [active, setActive] = useState(0)
  useEffect(() => {
    chat.wantMembers()
    field.current?.focus({ preventScroll: true })
    // The press that opened it may hand focus back to the board as it settles.
    const timer = setTimeout(() => field.current?.focus({ preventScroll: true }), 30)
    return () => clearTimeout(timer)
  }, [])
  const options = assignOptions(chat.people(), board, query, me, 50)
  const at0 = Math.min(active, Math.max(0, options.length - 1))
  const id = `cl-pick-${rowId}`
  const pick = (o: AssignOption) => {
    onToggle(o)
    setQuery('')
    setActive(0)
    field.current?.focus({ preventScroll: true })
  }
  return (
    <PeoplePop at={at} label={`Assign ${rowName}`} onOutside={() => onClose('away')} noteRow={rowId}>
      <input
        ref={field}
        className="cl-pick-field"
        placeholder="Assign to…"
        aria-label={`Assign ${rowName} to`}
        role="combobox"
        aria-expanded="true"
        aria-autocomplete="list"
        aria-controls={id}
        aria-activedescendant={options.length ? `${id}-${at0}` : undefined}
        value={query}
        spellCheck={false}
        maxLength={80}
        onChange={e => {
          setQuery(e.currentTarget.value)
          setActive(0)
        }}
        onKeyDown={e => {
          e.stopPropagation()
          if (e.nativeEvent.isComposing) return
          if (listKeys(e, options.length, setActive)) return
          if (e.key === 'Enter' && options[at0]) {
            e.preventDefault()
            pick(options[at0])
            return
          }
          if (e.key === 'Escape' || e.key === 'Tab') {
            e.preventDefault()
            onClose('key')
          }
        }}
        onPointerDown={stop}
      />
      <PeopleList id={id} options={options} active={at0} on={o => assigned.some(p => samePerson(p, o))} heading={pickerHeading()} onHover={setActive} onPick={pick} />
    </PeoplePop>
  )
}
