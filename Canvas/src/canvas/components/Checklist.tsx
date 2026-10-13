/**
 * The checklist (RSVP) card: a title, column headers with live counts, and
 * one row per person or task with a box per column. One click on a box picks
 * it (or clears it) for anyone who can edit — selected or not, no edit mode;
 * the title, labels and edges still drag the card. Double-click a title,
 * label or column to rename it; while one is open, a click on another moves
 * the editor there. Model and rules: `../checklist.ts` — the same card for a
 * note in the checklist view (its text is the list) and the legacy shape.
 *
 * A row can carry a comment. Collapsed (the default), a row with one shows a
 * single muted line of it under the row; a row without one offers to add one
 * only on hover or keyboard focus. Opening one is this viewer's own business
 * (never stored): the editor opens under its row, grows to eight lines and
 * then scrolls in itself, and while it is open the card keeps the height it
 * had — the rows scroll inside it — so the stored size never changes and
 * nothing spills past the card. The toggle, Escape or a click elsewhere close
 * it.
 */
import { memo, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type KeyboardEvent, type PointerEvent } from 'react'
import { MessageSquarePlus, MessageSquareText, Plus, Trash2, X } from 'lucide-react'
import {
  CHECKLIST_MIN,
  MAX_COLUMNS,
  MAX_ROWS,
  MAX_COLUMN_LABEL,
  MAX_ROW_LABEL,
  addColumn,
  addRow,
  pickedBy,
  removeColumn,
  removeRow,
  renameColumn,
  setRowLabel,
  setRowNote,
  setTitle,
  tally,
  togglePick,
} from '../checklist'
import { oneLine } from '../checklist-text'
import { contrastInk, inkOn, paperOf, strokeOf } from '../colors'
import { countRender } from '../debug'
import { INIT } from '../doc'
import { textSplice } from '../text-diff'
import { isNamedColor, type ChecklistNote, type ChecklistPick, type ChecklistRow, type Shape } from '../types'
import { useBoard } from './context'
import { cn, useMountFocus } from './ui'
import './checklist.css'

const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

/** One-line field over a title, label or column name; keys are the caller's. */
function Field({
  label,
  value,
  placeholder,
  max,
  onChange,
  onKey,
  onDone,
  onLeave,
  className,
  style,
}: {
  label: string
  value: string
  placeholder: string
  max: number
  onChange: (next: string) => void
  onKey: (e: KeyboardEvent<HTMLInputElement>, value: string) => boolean
  onDone: (value: string) => void
  /** The editor moved elsewhere without finishing here (no blur arrives). */
  onLeave?: (value: string) => void
  className?: string
  style?: CSSProperties
}) {
  const ref = useRef<HTMLInputElement>(null)
  const done = useRef(false)
  const latest = useRef(value)
  const leave = useRef(onLeave)
  useLayoutEffect(() => {
    leave.current = onLeave
  })
  useMountFocus(ref)
  useEffect(() => {
    // The press that opened the field may hand focus back to the board as
    // its default action; take it back once that has settled.
    const timer = setTimeout(() => {
      if (!done.current && document.activeElement !== ref.current) ref.current?.focus({ preventScroll: true })
    }, 30)
    return () => {
      clearTimeout(timer)
      if (!done.current) leave.current?.(latest.current)
      done.current = true
    }
  }, [])
  const finish = () => {
    if (done.current) return
    done.current = true
    onDone(ref.current?.value ?? value)
  }
  /** A blur that lasts: the field is left (not the opening press settling). */
  const blurred = () =>
    setTimeout(() => {
      if (!done.current && document.activeElement !== ref.current) finish()
    }, 80)
  return (
    <input
      ref={ref}
      aria-label={label}
      defaultValue={value}
      placeholder={placeholder}
      maxLength={max}
      spellCheck={false}
      onChange={e => {
        latest.current = e.currentTarget.value
        onChange(e.currentTarget.value)
      }}
      onBlur={blurred}
      onKeyDown={e => {
        e.stopPropagation()
        if (onKey(e, e.currentTarget.value)) {
          e.preventDefault()
          done.current = true
          return
        }
        if (e.key === 'Enter' || e.key === 'Escape') {
          e.preventDefault()
          finish()
        }
      }}
      onPointerDown={stop}
      onDoubleClick={stop}
      className={cn('cl-field', className)}
      style={style}
    />
  )
}

/** The box itself: crisp, with a short check animation when it turns on. */
function Box({ on }: { on: boolean }) {
  return (
    <span className="cl-box" data-on={on || undefined} aria-hidden="true">
      {on && (
        <svg viewBox="0 0 16 16" className="cl-check">
          <path d="M3.6 8.4 6.6 11.3 12.4 4.9" />
        </svg>
      )}
    </span>
  )
}

interface CellProps {
  row: ChecklistRow
  col: string
  pick: ChecklistPick | undefined
  readOnly: boolean
  onToggle: () => void
  onKey: (e: KeyboardEvent<HTMLButtonElement>) => void
}

function Cell({ row, col, pick, readOnly, onToggle, onKey }: CellProps) {
  const on = pick?.col === col
  const [tip, setTip] = useState<string | null>(null)
  const name = row.label.trim() || 'Untitled row'
  return (
    <span className="cl-cell" role="cell">
      <button
        type="button"
        role="checkbox"
        aria-checked={on}
        aria-disabled={readOnly || undefined}
        aria-label={`${name}: ${col}${on && pick?.by ? ` (${pickedBy(pick)})` : ''}`}
        data-cell=""
        data-row={row.id}
        data-col={col}
        className="cl-hit"
        tabIndex={0}
        onPointerDown={readOnly ? undefined : stop}
        onDoubleClick={stop}
        onPointerEnter={() => setTip(on && pick ? pickedBy(pick) : null)}
        onPointerLeave={() => setTip(null)}
        onClick={e => {
          // The second click of a double-click is not a second toggle.
          if (readOnly || e.detail > 1) return
          e.stopPropagation()
          setTip(null)
          onToggle()
        }}
        onKeyDown={onKey}
      >
        <Box on={on} />
      </button>
      {tip && (
        <span className="cl-tip" role="presentation">
          {tip}
        </span>
      )}
    </span>
  )
}

/** A comment as it is left when its editor closes: no blank lines around it. */
const tidyNote = (s: string) => s.replace(/^(?:[ \t]*\n)+/, '').trimEnd()

/** The rows' scroller around an element, scrolled (world px) so `el` shows; its top wins. */
function reveal(el: HTMLElement) {
  const list = el.closest<HTMLElement>('.cl-rows')
  if (!list || list.scrollHeight <= list.clientHeight) return
  const scale = list.getBoundingClientRect().height / (list.offsetHeight || 1) || 1
  const below = (el.getBoundingClientRect().bottom - list.getBoundingClientRect().bottom) / scale
  if (below > 0) list.scrollTop += below
  const above = (list.getBoundingClientRect().top - el.getBoundingClientRect().top) / scale
  if (above > 0) list.scrollTop -= above
}

/**
 * A row's comment, open: a textarea that grows with its words up to eight
 * lines, then scrolls in itself. Every change is written at once (only that
 * row's comment lines change); someone else's typing shows as it arrives,
 * the caret staying among the same words.
 */
function NoteEditor({
  row,
  name,
  value,
  meta,
  readOnly,
  onChange,
  onClose,
}: {
  row: string
  name: string
  value: string
  meta: string
  readOnly: boolean
  onChange: (next: string) => void
  /** `key`: Escape, which leaves focus on the row's toggle. */
  onClose: (how: 'key' | 'away') => void
}) {
  const ref = useRef<HTMLTextAreaElement>(null)
  const composing = useRef(false)
  const grow = () => {
    const el = ref.current
    if (!el) return
    // Shrinking it to measure must not move the rows' scroll.
    const list = el.closest<HTMLElement>('.cl-rows')
    const top = list?.scrollTop ?? 0
    el.style.height = '0px'
    el.style.height = `${el.scrollHeight + el.offsetHeight - el.clientHeight}px`
    if (list) list.scrollTop = top
  }
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    grow()
    el.focus({ preventScroll: true })
    el.setSelectionRange(el.value.length, el.value.length)
    reveal(el.closest<HTMLElement>('.cl-row') ?? el)
    // The press that opened it may hand focus back to the board as it settles.
    const timer = setTimeout(() => {
      if (ref.current && document.activeElement !== ref.current) ref.current.focus({ preventScroll: true })
    }, 30)
    return () => clearTimeout(timer)
  }, [])
  useLayoutEffect(() => {
    const el = ref.current
    if (!el || composing.current || el.value === value) return
    const d = textSplice(el.value, value)
    const map = (i: number) => (i <= d.index ? i : i >= d.index + d.remove ? i + d.insert.length - d.remove : d.index + d.insert.length)
    const focused = document.activeElement === el
    const a = el.selectionStart
    const b = el.selectionEnd
    el.value = value
    if (focused) el.setSelectionRange(map(a), map(b))
    grow()
  }, [value])
  /** A blur that lasts and leaves the comment: the click went elsewhere. */
  const blurred = () =>
    setTimeout(() => {
      const el = ref.current
      if (!el || document.activeElement === el) return
      if (document.activeElement?.closest(`[data-note-row="${CSS.escape(row)}"]`)) return
      onClose('away')
    }, 80)
  return (
    <div className="cl-note-edit">
      <textarea
        ref={ref}
        aria-label={`Comment on ${name}`}
        defaultValue={value}
        placeholder={readOnly ? '' : 'Add a comment…'}
        readOnly={readOnly}
        rows={1}
        spellCheck
        className="cl-note-field"
        onChange={e => {
          if (readOnly) return
          onChange(e.currentTarget.value)
          grow()
        }}
        onCompositionStart={() => {
          composing.current = true
        }}
        onCompositionEnd={() => {
          composing.current = false
        }}
        onKeyDown={e => {
          e.stopPropagation()
          if (e.key === 'Escape') {
            e.preventDefault()
            onClose('key')
          }
        }}
        onBlur={blurred}
        onPointerDown={stop}
        onDoubleClick={stop}
      />
      {meta && <div className="cl-note-meta">{meta}</div>}
    </div>
  )
}

/** Where the editor is: `part:cl-title`, `part:cl-row:<id>`, `part:cl-col:<index>`. */
function editTarget(field: string | null) {
  if (!field?.startsWith('part:cl-')) return null
  const part = field.slice(5)
  if (part === 'cl-title') return { kind: 'title' as const }
  if (part.startsWith('cl-row:')) return { kind: 'row' as const, id: part.slice(7) }
  if (part.startsWith('cl-col:')) return { kind: 'col' as const, index: Number(part.slice(7)) }
  return null
}

export const ChecklistView = memo(function ChecklistView({
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
  const { store, me, readOnly } = board
  const columns = shape.columns ?? []
  const rows = shape.rows ?? []
  const picks = shape.picks ?? {}
  const notes = shape.notes ?? {}
  const counts = tally(columns, rows, picks)
  const single = columns.length === 1
  const target = editTarget(editing)
  const accent = strokeOf(shape.color)
  const check = isNamedColor(shape.color) ? 'var(--surface)' : contrastInk(shape.color)
  const band = shape.color === 'white' ? 'var(--surface-2)' : paperOf(shape.color)
  const bandInk = shape.color === 'white' ? 'var(--ink)' : inkOn(shape.color)
  const grid = single ? '28px minmax(0, 1fr)' : `minmax(0, 1fr) repeat(${columns.length}, var(--cl-col))`
  const done = Object.keys(picks).length

  // ---- a row's comment, open (this viewer's own state, never stored) ------------
  /** The open comment's row (by id, else by label should the rows move) and the card's height when it opened. */
  const [open, setOpen] = useState<{ id: string; label: string; h: number } | null>(null)
  const openRow = open
    ? (rows.find(r => r.id === open.id && r.label === open.label) ?? rows.find(r => r.label === open.label) ?? rows.find(r => r.id === open.id))
    : undefined
  // Follow the row should it move or be renamed under the editor; close when it goes.
  if (open && (!openRow || openRow.id !== open.id || openRow.label !== open.label))
    setOpen(openRow ? { ...open, id: openRow.id, label: openRow.label } : null)
  /** While one is open the card keeps its height and its rows scroll. */
  const locked = open && openRow ? open.h : null
  /** This viewer changed the open comment: closing it tidies blank lines away. */
  const edited = useRef(false)
  const toggleNote = (row: ChecklistRow) => {
    if (open && openRow?.id === row.id) {
      closeNote()
      return
    }
    if (open) closeNote()
    edited.current = false
    setOpen({ id: row.id, label: row.label, h: card.current?.offsetHeight ?? shape.h })
  }
  /** Close the open comment (with `only`, only while that row's is the one open: a late blur must not close the next). */
  const closeNote = (only?: string) => {
    const row = openRow
    if (only !== undefined && row?.id !== only) return
    setOpen(o => (only !== undefined && o?.id !== only ? o : null))
    if (!row || readOnly || !edited.current) return
    edited.current = false
    const now = store.live(shape.id)?.notes?.[row.id]?.text ?? ''
    if (tidyNote(now) !== now) setRowNote(store, shape.id, row.id, tidyNote(now), me, 'local', row.label)
  }
  const rowsRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    // The board's wheel listener is native; while the rows scroll, the wheel is theirs.
    const el = rowsRef.current
    if (!el || locked === null) return
    const onWheel = (e: WheelEvent) => {
      if (!e.ctrlKey && !e.metaKey && el.scrollHeight > el.clientHeight + 1) e.stopPropagation()
    }
    el.addEventListener('wheel', onWheel)
    return () => el.removeEventListener('wheel', onWheel)
  }, [locked])

  // ---- height follows the content (written by editors, outside undo) ----------
  const card = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    const el = card.current
    // An open comment holds the card's height: nothing to measure until it closes.
    if (!el || readOnly || locked !== null || typeof ResizeObserver === 'undefined') return
    let timer: ReturnType<typeof setTimeout> | null = null
    const measure = () => {
      if (timer) clearTimeout(timer)
      timer = setTimeout(() => {
        const h = Math.max(CHECKLIST_MIN.h, Math.ceil(el.offsetHeight))
        const stored = store.get(shape.id)?.h
        if (stored !== undefined && Math.abs(h - stored) > 1) store.update(shape.id, { h }, INIT, false)
      }, 120)
    }
    measure()
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    return () => {
      ro.disconnect()
      if (timer) clearTimeout(timer)
    }
  }, [store, shape.id, readOnly, locked])

  // ---- editing -----------------------------------------------------------------
  /** A row this card added and is naming: left empty, it goes again. */
  const fresh = useRef<string | null>(null)
  const leaveFresh = (unless?: string) => {
    const id = fresh.current
    if (!id || id === unless) return
    fresh.current = null
    const row = store.live(shape.id)?.rows?.find(r => r.id === id)
    if (row && !row.label.trim()) removeRow(store, shape.id, id)
  }
  const edit = (part: string | null) => {
    leaveFresh(part?.startsWith('cl-row:') ? part.slice(7) : undefined)
    board.editPart(shape.id, part)
  }
  const finishRow = () => leaveFresh()
  const newRowAfter = (after: string | null) => {
    const id = addRow(store, shape.id, after)
    if (!id) return
    fresh.current = id
    board.editPart(shape.id, `cl-row:${id}`)
  }
  // A double-click on an empty card starts its first row.
  const startEmpty = editing === 'part:cl-new'
  useEffect(() => {
    if (startEmpty && !readOnly) newRowAfter(rows[rows.length - 1]?.id ?? null)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [startEmpty])
  /** While the card is open, one click on another name moves the editor there. */
  const onCardDown = (e: PointerEvent) => {
    if (readOnly || !editing || e.button !== 0) return
    const part = (e.target as Element).closest('[data-part]')?.getAttribute('data-part')
    if (!part || !/^cl-(title|row:|col:)/.test(part) || `part:${part}` === editing) return
    e.stopPropagation()
    e.preventDefault()
    edit(part)
  }

  // ---- keyboard between boxes ----------------------------------------------------
  const cellKey = (ri: number, ci: number) => (e: KeyboardEvent<HTMLButtonElement>) => {
    const move = (r: number, c: number) => {
      const el = e.currentTarget.closest('[data-kind="checklist"]')?.querySelector<HTMLButtonElement>(
        `[data-row="${CSS.escape(rows[r]?.id ?? '')}"][data-col="${CSS.escape(columns[c] ?? '')}"]`
      )
      if (el) el.focus({ preventScroll: true })
    }
    if (e.key === ' ' || e.key === 'Enter') {
      // The button's own activation (a click) toggles it; the board must not
      // also take the key (Space pans, Enter edits).
      e.stopPropagation()
      return
    }
    const step: Record<string, [number, number]> = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1] }
    const d = step[e.key]
    if (d) {
      e.preventDefault()
      e.stopPropagation()
      move(Math.min(rows.length - 1, Math.max(0, ri + d[0])), Math.min(columns.length - 1, Math.max(0, ci + d[1])))
    }
    if (e.key === 'Escape') {
      e.stopPropagation()
      ;(e.currentTarget.closest('[role="application"]') as HTMLElement | null)?.focus({ preventScroll: true })
    }
  }

  const titleText = shape.title.trim()
  return (
    <div
      ref={card}
      data-id={shape.id}
      data-kind="checklist"
      role="table"
      aria-label={titleText ? `Checklist: ${titleText}` : 'Checklist'}
      aria-readonly={readOnly || undefined}
      onPointerDown={onCardDown}
      className={cn('cl-card absolute left-0 top-0', single && 'cl-single', selected && 'cl-selected', locked !== null && 'cl-locked')}
      style={
        {
          width: shape.w,
          minHeight: CHECKLIST_MIN.h,
          ...(locked !== null ? { height: locked } : {}),
          transform: `translate(${shape.x}px, ${shape.y}px)`,
          '--cl-accent': accent,
          '--cl-check': check,
          '--cl-band': band,
          '--cl-band-ink': bandInk,
          '--cl-grid': grid,
        } as CSSProperties
      }
    >
      <div>
        <div className="cl-band">
          <div className="cl-title-row" data-part="cl-title">
            {target?.kind === 'title' ? (
              <Field
                label="Checklist title"
                value={shape.title}
                placeholder="Title"
                max={500}
                onChange={title => setTitle(store, shape.id, title)}
                onKey={e => {
                  if (e.key !== 'Enter' && e.key !== 'Tab') return false
                  // Enter goes on to the first row: naming people in one go.
                  if (rows[0]) edit(`cl-row:${rows[0].id}`)
                  else newRowAfter(null)
                  return true
                }}
                onDone={() => board.endEdit(shape.id)}
                className="cl-title-field"
              />
            ) : (
              <span className={cn('cl-title', !titleText && 'cl-muted')}>{titleText || 'Untitled'}</span>
            )}
            {single && rows.length > 0 && (
              <span className="cl-count" aria-label={`${done} of ${rows.length} done`}>
                {done}/{rows.length}
              </span>
            )}
          </div>
          {!single && (
            <div className="cl-grid cl-heads" role="row">
              <span role="columnheader" className="cl-head-spacer">
                <span className="sr-only">Name</span>
              </span>
              {columns.map((c, i) => (
                <span
                  key={`${i}:${c}`}
                  role="columnheader"
                  className="cl-head"
                  data-part={`cl-col:${i}`}
                  aria-label={`${c}, ${counts[c] ?? 0}`}
                >
                  <span className="cl-head-label">{c}</span>
                  <span className={cn('cl-head-count', (counts[c] ?? 0) > 0 && 'cl-head-count-on')}>{counts[c] ?? 0}</span>
                  {target?.kind === 'col' && target.index === i && (
                    <span className="cl-col-edit" onPointerDown={stop} onDoubleClick={stop}>
                      <Field
                        label={`Rename column ${c}`}
                        value={c}
                        placeholder="Column"
                        max={MAX_COLUMN_LABEL}
                        onChange={() => {}}
                        onKey={(e, value) => {
                          if (e.key !== 'Enter' && e.key !== 'Tab') return false
                          renameColumn(store, shape.id, i, value)
                          if (e.key === 'Tab' && columns[i + 1] !== undefined) edit(`cl-col:${i + 1}`)
                          else board.endEdit(shape.id)
                          return true
                        }}
                        onDone={value => {
                          renameColumn(store, shape.id, i, value)
                          board.endEdit(shape.id)
                        }}
                        onLeave={value => renameColumn(store, shape.id, i, value)}
                        className="cl-col-field"
                      />
                      {columns.length > 1 && (
                        <button
                          type="button"
                          aria-label={`Remove column ${c}`}
                          className="cl-icon-btn"
                          onPointerDown={e => {
                            // Before the field's blur ends the edit.
                            e.preventDefault()
                            e.stopPropagation()
                            removeColumn(store, shape.id, i)
                            board.endEdit(shape.id)
                          }}
                        >
                          <Trash2 className="h-3.5 w-3.5" aria-hidden="true" />
                        </button>
                      )}
                    </span>
                  )}
                </span>
              ))}
            </div>
          )}
        </div>
        <div role="rowgroup" className="cl-rows" ref={rowsRef}>
          {rows.map((row, ri) => {
            const pick = picks[row.id]
            const note: ChecklistNote | undefined = notes[row.id]
            const noteOpen = openRow?.id === row.id
            const name = row.label.trim() || 'this row'
            const editingRow = target?.kind === 'row' && target.id === row.id
            const label = (
              <span
                role="rowheader"
                className="cl-label"
                data-part={`cl-row:${row.id}`}
              >
                {editingRow ? (
                  <Field
                    label="Row label"
                    value={row.label}
                    placeholder={single ? 'To do' : 'Name'}
                    max={MAX_ROW_LABEL}
                    onChange={next => setRowLabel(store, shape.id, row.id, next)}
                    onKey={(e, value) => {
                      if (e.key === 'Enter') {
                        if (!value.trim()) {
                          if (fresh.current !== row.id) fresh.current = row.id
                          finishRow()
                          board.endEdit(shape.id)
                        } else {
                          fresh.current = null
                          newRowAfter(row.id)
                        }
                        return true
                      }
                      if (e.key === 'Backspace' && !value) {
                        const prev = rows[ri - 1]
                        removeRow(store, shape.id, row.id)
                        fresh.current = null
                        edit(prev ? `cl-row:${prev.id}` : 'cl-title')
                        return true
                      }
                      if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
                        const next = rows[ri + (e.key === 'ArrowUp' ? -1 : 1)]
                        if (next) edit(`cl-row:${next.id}`)
                        else if (e.key === 'ArrowUp') edit('cl-title')
                        else return false
                        return true
                      }
                      return false
                    }}
                    onDone={() => {
                      finishRow()
                      board.endEdit(shape.id)
                    }}
                    className="cl-label-field"
                  />
                ) : (
                  <>
                    <span className={cn('cl-label-text', !row.label.trim() && 'cl-muted')}>{row.label.trim() || 'Untitled'}</span>
                    {selected && !readOnly && (
                      <button
                        type="button"
                        aria-label={`Remove ${row.label.trim() || 'this row'}`}
                        className="cl-icon-btn cl-row-remove"
                        onPointerDown={stop}
                        onDoubleClick={stop}
                        onClick={e => {
                          e.stopPropagation()
                          removeRow(store, shape.id, row.id)
                        }}
                      >
                        <X className="h-3 w-3" aria-hidden="true" />
                      </button>
                    )}
                    {(!readOnly || note) && (
                      <button
                        type="button"
                        aria-label={noteOpen ? `Close the comment on ${name}` : note ? `Comment on ${name}` : `Add a comment on ${name}`}
                        aria-expanded={noteOpen}
                        data-note-row={row.id}
                        className={cn('cl-icon-btn cl-note-toggle', selected && !readOnly && 'cl-note-toggle-shift')}
                        onPointerDown={e => {
                          e.stopPropagation()
                          // An open comment keeps focus, so the click (not its blur) closes it.
                          if (noteOpen) e.preventDefault()
                        }}
                        onDoubleClick={stop}
                        onClick={e => {
                          e.stopPropagation()
                          toggleNote(row)
                        }}
                      >
                        {note ? <MessageSquareText className="h-3.5 w-3.5" aria-hidden="true" /> : <MessageSquarePlus className="h-3.5 w-3.5" aria-hidden="true" />}
                      </button>
                    )}
                  </>
                )}
              </span>
            )
            const cells = columns.map((col, ci) => (
              <Cell
                key={`${ci}:${col}`}
                row={row}
                col={col}
                pick={pick}
                readOnly={readOnly}
                onToggle={() => togglePick(store, shape.id, row.id, col, me, 'local', row.label)}
                onKey={cellKey(ri, ci)}
              />
            ))
            const comment = noteOpen ? (
              <div role="cell" className="cl-note" data-note-row={row.id}>
                <NoteEditor
                  row={row.id}
                  name={name}
                  value={note?.text ?? ''}
                  meta={note ? pickedBy({ col: '', by: note.by, byId: note.byId, at: note.at }) : ''}
                  readOnly={readOnly}
                  onChange={next => {
                    edited.current = true
                    setRowNote(store, shape.id, row.id, next, me, 'local', row.label)
                  }}
                  onClose={how => {
                    if (how === 'key') (document.querySelector(`[data-id="${CSS.escape(shape.id)}"] .cl-note-toggle[data-note-row="${CSS.escape(row.id)}"]`) as HTMLElement | null)?.focus({ preventScroll: true })
                    closeNote(row.id)
                  }}
                />
              </div>
            ) : note ? (
              <div role="cell" className="cl-note" data-note-row={row.id}>
                <button
                  type="button"
                  aria-expanded={false}
                  className="cl-note-peek"
                  onPointerDown={stop}
                  onDoubleClick={stop}
                  onClick={e => {
                    e.stopPropagation()
                    toggleNote(row)
                  }}
                >
                  <MessageSquareText className="cl-note-icon" aria-hidden="true" />
                  <span className="sr-only">Comment on {name}: </span>
                  <span className="cl-note-peek-text">{oneLine(note.text)}</span>
                </button>
              </div>
            ) : null
            return (
              <div key={row.id} role="row" className={cn('cl-grid cl-row', pick && 'cl-row-picked', noteOpen && 'cl-row-open')}>
                {single ? (
                  <>
                    {cells}
                    {label}
                  </>
                ) : (
                  <>
                    {label}
                    {cells}
                  </>
                )}
                {comment}
              </div>
            )
          })}
          {rows.length === 0 && (
            <p className="cl-empty" data-part="cl-empty">
              {readOnly ? 'Nothing here yet.' : 'Double-click to add names.'}
            </p>
          )}
        </div>
        {!readOnly && (
          <div className="cl-foot" aria-label="Checklist actions">
            {rows.length < MAX_ROWS && (
              <button
                type="button"
                className="cl-add"
                onPointerDown={stop}
                onDoubleClick={stop}
                onClick={e => {
                  e.stopPropagation()
                  newRowAfter(rows[rows.length - 1]?.id ?? null)
                }}
              >
                <Plus className="h-3.5 w-3.5" aria-hidden="true" />
                {single ? 'Add item' : 'Add row'}
              </button>
            )}
            {columns.length < MAX_COLUMNS && (
              <button
                type="button"
                className="cl-add cl-add-col"
                onPointerDown={stop}
                onDoubleClick={stop}
                onClick={e => {
                  e.stopPropagation()
                  const i = addColumn(store, shape.id)
                  if (i >= 0) edit(`cl-col:${i}`)
                }}
              >
                <Plus className="h-3.5 w-3.5" aria-hidden="true" />
                Column
              </button>
            )}
          </div>
        )}
      </div>
    </div>
  )
})

/** The edit field a double-click on part of a checklist opens. */
export function checklistEditField(part: string | null): `part:${string}` {
  if (part === 'cl-empty') return 'part:cl-new'
  return `part:${part && part.startsWith('cl-') ? part : 'cl-title'}`
}
