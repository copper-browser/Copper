/**
 * Comment threads on the board, all in screen space: the pins on shapes'
 * top-right corners, the thread popover beside a pin, the Comments panel and
 * the board's right-click menu. The board owns which thread is open; the
 * threads themselves live in the document (`comments.ts`).
 */
import {
  memo,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
  type RefObject,
  type KeyboardEvent as ReactKeyboardEvent,
} from 'react'
import { ArrowUp, Check, ChevronDown, ChevronLeft, MessageSquare, MessageSquarePlus, MessageSquareText, Pencil, RotateCcw, Trash2, X } from 'lucide-react'
import { postToHost } from '../../host-bridge'
import { initials } from '../colors'
import {
  MAX_COMMENT,
  agoLabel,
  isShown,
  liveMessages,
  replyCount,
  sameAuthor,
  shapeLabel,
  type CommentAuthor,
  type CommentMessage,
  type CommentStore,
  type CommentThread,
} from '../comments'
import { fullTime, segments, stableColor } from '../chat/model'
import type { Box, Point } from '../geometry'
import type { Shape } from '../types'
import { IconButton, Kbd, cn } from './ui'

/** Pin height on screen (constant at every zoom). */
export const PIN_H = 22
/** Screen px between a shape's top-right corner and its pin. */
export const PIN_GAP = 3
export const POP_W = 320
export const PANEL_W = 300
/** Screen px the panel keeps from the window's edges (top: under the title bar; bottom: above zoom). */
export const PANEL_TOP = 60
export const PANEL_BOTTOM = 64
/** Screen px a popover keeps above the board's bottom edge (the tool bar). */
const BOTTOM_CLEAR = 64
/** ⌥⌘M, as in Google Docs ("Insert comment"); C is the chat here. */
export const COMMENT_KEYS = isMacLike() ? '⌥⌘M' : 'Ctrl+Alt+M'
const MAX_FIELD_PX = 140

function isMacLike() {
  return typeof navigator !== 'undefined' && /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent)
}

/** What the popover shows: one thread, a new one being written, or the threads on one shape. */
export type CommentFocus =
  | { kind: 'thread'; id: string; /** Where to show it when its shape is gone (screen px). */ at?: Point }
  | { kind: 'new'; anchor: string }
  | { kind: 'shape'; anchor: string }

export interface PinPlace {
  anchor: string
  /** Top-left of the pin, screen px. */
  x: number
  y: number
  /** The threads it stands for: open ones (and the one shown, even if resolved), oldest first. */
  threads: CommentThread[]
}

/**
 * Where pins go: one per shape that has open threads, its bottom-left corner
 * just off the shape's top-right corner, the same size at every zoom. Threads
 * on deleted shapes have no pin (the panel lists them); resolved ones show only
 * while open. Pins far off screen are left out.
 */
export function pinPlaces({
  threads,
  boundsOf,
  toScreen,
  size,
  focus,
}: {
  threads: readonly CommentThread[]
  boundsOf: (id: string) => Box | null
  toScreen: (p: Point) => Point
  size: { w: number; h: number }
  focus: CommentFocus | null
}): PinPlace[] {
  const open = focus?.kind === 'thread' ? focus.id : null
  const by = new Map<string, CommentThread[]>()
  for (const t of threads) {
    if (!isShown(t) || (t.resolved && t.id !== open)) continue
    const list = by.get(t.anchor) ?? []
    list.push(t)
    by.set(t.anchor, list)
  }
  if (focus?.kind === 'new' && !by.has(focus.anchor)) by.set(focus.anchor, [])
  const out: PinPlace[] = []
  for (const [anchor, list] of by) {
    const b = boundsOf(anchor)
    if (!b) continue
    const corner = toScreen({ x: b.x + b.w, y: b.y })
    const x = Math.round(corner.x + PIN_GAP)
    const y = Math.round(corner.y - PIN_GAP - PIN_H)
    if (x > size.w + 40 || x < -80 || y > size.h + 40 || y < -80) continue
    out.push({ anchor, x, y, threads: list })
  }
  return out
}

/** The board's wheel listener is native and non-passive: a list that scrolls keeps its wheel. */
function useOwnWheel(ref: RefObject<HTMLElement | null>) {
  useEffect(() => {
    const el = ref.current
    if (!el) return
    const stop = (e: WheelEvent) => {
      if (!e.ctrlKey && !e.metaKey) e.stopPropagation()
    }
    el.addEventListener('wheel', stop)
    return () => el.removeEventListener('wheel', stop)
  }, [ref])
}

const useNow = (ms: number) => {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), ms)
    return () => clearInterval(t)
  }, [ms])
  return now
}

/** Keys, copy and paste inside comments are theirs: the board's window listeners never see them. */
const keepEvents = {
  onCopy: (e: { stopPropagation(): void }) => e.stopPropagation(),
  onCut: (e: { stopPropagation(): void }) => e.stopPropagation(),
  onPaste: (e: { stopPropagation(): void }) => e.stopPropagation(),
  onPointerDown: (e: { stopPropagation(): void }) => e.stopPropagation(),
  onDoubleClick: (e: { stopPropagation(): void }) => e.stopPropagation(),
}

function Avatar({ name, id, size = 20 }: { name: string; id: string; size?: number }) {
  return (
    <span
      aria-hidden="true"
      className="flex shrink-0 items-center justify-center rounded-full font-semibold text-white"
      style={{ width: size, height: size, fontSize: size <= 20 ? 9 : 10, background: stableColor(id || name) }}
    >
      {initials(name)}
    </span>
  )
}

/** A message's words: line breaks kept, links that open in a tab, long words wrapped. */
function Words({ text }: { text: string }) {
  return (
    <>
      {segments(text, []).map((s, i) =>
        s.kind === 'link' ? (
          <a
            key={i}
            href={s.url}
            className="text-accent-strong underline decoration-accent/40 underline-offset-2 hover:decoration-accent dark:text-accent"
            onClick={e => {
              e.preventDefault()
              postToHost({ type: 'openUrl', url: s.url })
            }}
          >
            {s.text}
          </a>
        ) : (
          <span key={i}>{s.kind === 'text' ? s.text : `@${s.name}`}</span>
        )
      )}
    </>
  )
}

// ---- pins -------------------------------------------------------------------------

export const CommentPins = memo(function CommentPins({
  pins,
  focus,
  onOpen,
}: {
  pins: readonly PinPlace[]
  focus: CommentFocus | null
  onOpen: (pin: PinPlace) => void
}) {
  if (pins.length === 0) return null
  return (
    <div className="pointer-events-none absolute inset-0 overflow-hidden" data-testid="comment-pins">
      {pins.map(p => {
        const count = p.threads.length
        const single = count === 1 ? p.threads[0]! : null
        const on =
          (focus?.kind === 'thread' && p.threads.some(t => t.id === focus.id)) ||
          ((focus?.kind === 'new' || focus?.kind === 'shape') && focus.anchor === p.anchor)
        const draft = count === 0
        const label = draft
          ? 'New comment'
          : single
            ? `Comment by ${single.by}${replyCount(single) ? `, ${replyCount(single)} ${replyCount(single) === 1 ? 'reply' : 'replies'}` : ''}${single.resolved ? ', resolved' : ''}`
            : `${count} comment threads`
        return (
          <button
            key={p.anchor}
            type="button"
            data-pin={p.anchor}
            aria-label={label}
            aria-expanded={on}
            title={single ? `${single.by}: ${liveMessages(single)[0]?.text.slice(0, 120) ?? ''}` : label}
            className={cn(
              'pointer-events-auto absolute flex items-center justify-center gap-0.5 rounded-full rounded-bl-[3px] border px-[5px] text-[10px] font-semibold leading-none tabular-nums shadow-1 outline-none transition-colors duration-100 focus-visible:ring-2 focus-visible:ring-accent/60',
              on || draft
                ? 'border-accent bg-accent text-accent-ink'
                : 'border-line-2 bg-surface text-ink-2 hover:border-ink-4 hover:text-ink',
              single?.resolved && !on && 'opacity-70'
            )}
            style={{ left: p.x, top: p.y, height: PIN_H, minWidth: PIN_H }}
            onPointerDown={e => e.stopPropagation()}
            onDoubleClick={e => e.stopPropagation()}
            onClick={() => onOpen(p)}
          >
            {draft ? (
              <MessageSquarePlus className="h-3 w-3" aria-hidden="true" />
            ) : single ? (
              initials(single.by)
            ) : (
              <>
                <MessageSquare className="h-[11px] w-[11px]" aria-hidden="true" />
                {count}
              </>
            )}
          </button>
        )
      })}
    </div>
  )
})

// ---- the field ----------------------------------------------------------------------

function CommentField({
  value,
  onChange,
  onSubmit,
  onCancel,
  placeholder,
  label,
  submitLabel,
  autoFocus,
  inline = false,
}: {
  value: string
  onChange: (v: string) => void
  onSubmit: () => void
  onCancel?: () => void
  placeholder: string
  label: string
  submitLabel: string
  autoFocus?: boolean
  /** The send button sits inside the field (a reply), not in a row of its own. */
  inline?: boolean
}) {
  const ref = useRef<HTMLTextAreaElement>(null)
  const composing = useRef(false)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    el.style.height = '0px'
    el.style.height = `${Math.min(MAX_FIELD_PX, el.scrollHeight)}px`
  }, [value])
  useEffect(() => {
    if (!autoFocus) return
    const focus = () => {
      const el = ref.current
      if (!el || document.activeElement === el) return
      el.focus({ preventScroll: true })
      el.setSelectionRange(el.value.length, el.value.length)
    }
    focus()
    const frame = requestAnimationFrame(focus)
    return () => cancelAnimationFrame(frame)
  }, [autoFocus])
  const empty = !value.trim()
  const onKeyDown = (e: ReactKeyboardEvent<HTMLTextAreaElement>) => {
    if (composing.current || e.nativeEvent.isComposing) return
    if (e.key === 'Enter' && !e.shiftKey && !e.altKey && !e.ctrlKey) {
      e.preventDefault()
      if (!empty) onSubmit()
      return
    }
    if (e.key === 'Escape' && onCancel) {
      e.preventDefault()
      e.stopPropagation()
      onCancel()
    }
  }
  const near = value.length > MAX_COMMENT - 400
  return (
    <div>
      <div className="relative rounded-[10px] border border-line-2 bg-surface transition-[border-color,box-shadow] duration-100 focus-within:border-accent/55 focus-within:shadow-[0_0_0_3px_var(--accent-soft)]">
        <textarea
          ref={ref}
          rows={1}
          value={value}
          maxLength={MAX_COMMENT}
          spellCheck
          aria-label={label}
          placeholder={placeholder}
          className={cn(
            'block w-full resize-none overflow-y-auto overflow-x-hidden bg-transparent py-[7px] pl-2.5 text-[13px] leading-[19px] text-ink outline-none [overflow-wrap:anywhere] placeholder:text-ink-4',
            inline ? 'pr-10' : 'pr-2.5'
          )}
          style={{ maxHeight: MAX_FIELD_PX }}
          onChange={e => onChange(e.target.value)}
          onKeyDown={onKeyDown}
          onCompositionStart={() => (composing.current = true)}
          onCompositionEnd={() => (composing.current = false)}
        />
        {inline && (
          <button
            type="button"
            aria-label={`${submitLabel} (↵)`}
            disabled={empty}
            onMouseDown={e => e.preventDefault()}
            onClick={onSubmit}
            className="absolute bottom-[4px] right-[4px] flex h-[25px] w-[25px] items-center justify-center rounded-[7px] bg-accent text-accent-ink outline-none transition-colors hover:bg-accent-strong focus-visible:ring-2 focus-visible:ring-accent/60 disabled:bg-surface-2 disabled:text-ink-4"
          >
            <ArrowUp className="h-3.5 w-3.5" strokeWidth={2.25} aria-hidden="true" />
          </button>
        )}
      </div>
      {!inline && (
        <div className="mt-1.5 flex items-center justify-end gap-1.5">
          {near && <span className={cn('mr-auto text-[11px] tabular-nums text-ink-4', value.length >= MAX_COMMENT && 'text-danger')}>{MAX_COMMENT - value.length}</span>}
          {onCancel && (
            <button
              type="button"
              className="h-7 rounded-lg px-2.5 text-[12.5px] font-medium text-ink-2 outline-none hover:bg-surface-2 hover:text-ink focus-visible:ring-2 focus-visible:ring-accent/60"
              onMouseDown={e => e.preventDefault()}
              onClick={onCancel}
            >
              Cancel
            </button>
          )}
          <button
            type="button"
            disabled={empty}
            className="h-7 rounded-lg bg-accent px-2.5 text-[12.5px] font-semibold text-accent-ink outline-none transition-colors hover:bg-accent-strong focus-visible:ring-2 focus-visible:ring-accent/60 disabled:bg-surface-2 disabled:text-ink-4"
            onMouseDown={e => e.preventDefault()}
            onClick={onSubmit}
          >
            {submitLabel}
          </button>
        </div>
      )}
    </div>
  )
}

/** Drafts outlive the popover: closing it by accident never loses what was typed. */
const drafts = new Map<string, string>()

/** A draft kept by `key`; the popover remounts per thread, so the key never changes under it. */
function useDraft(key: string): [string, (v: string) => void] {
  const [value, setValue] = useState(() => drafts.get(key) ?? '')
  const set = (v: string) => {
    if (v) drafts.set(key, v)
    else drafts.delete(key)
    setValue(v)
  }
  return [value, set]
}

// ---- the popover ----------------------------------------------------------------------

/** A shape's name in a heading; a deleted one keeps the name it had. */
export function anchorTitle(t: CommentThread, shapes: ReadonlyMap<string, Shape>): { name: string; gone: boolean } {
  const s = shapes.get(t.anchor)
  if (s) return { name: shapeLabel(s), gone: false }
  return { name: t.anchorName || 'Shape', gone: true }
}

function MessageRow({
  m,
  first,
  mine,
  readOnly,
  now,
  editing,
  onEdit,
  onDelete,
  onSave,
  onCancelEdit,
}: {
  m: CommentMessage
  first: boolean
  mine: boolean
  readOnly: boolean
  now: number
  editing: boolean
  onEdit: () => void
  onDelete: () => void
  onSave: (text: string) => void
  onCancelEdit: () => void
}) {
  const [text, setText] = useState(m.text)
  if (m.deleted)
    return first ? (
      <div data-message={m.id} className="px-3 py-2 text-[12px] italic text-ink-4">
        Comment deleted
      </div>
    ) : null
  return (
    <div data-message={m.id} className="group/msg relative px-3 py-2">
      <div className="flex min-w-0 items-center gap-2">
        <Avatar name={m.by} id={m.byId} />
        <span className="min-w-0 truncate text-[12px] font-semibold text-ink-2">{m.by}</span>
        <time className="shrink-0 text-[11px] text-ink-4" dateTime={new Date(m.at).toISOString()} title={fullTime(m.at)}>
          {agoLabel(m.at, now)}
        </time>
        {m.editedAt && (
          <span className="shrink-0 text-[11px] text-ink-4" title={`Edited ${fullTime(m.editedAt)}`}>
            · edited
          </span>
        )}
        <span className="flex-1" />
        {mine && !readOnly && !editing && (
          <span className="-my-1 flex shrink-0 items-center opacity-0 transition-opacity focus-within:opacity-100 group-hover/msg:opacity-100">
            <button
              type="button"
              aria-label="Edit comment"
              title="Edit"
              className="flex h-6 w-6 items-center justify-center rounded-md text-ink-4 outline-none hover:bg-surface-2 hover:text-ink-2 focus-visible:ring-2 focus-visible:ring-accent/60"
              onClick={onEdit}
            >
              <Pencil className="h-3 w-3" aria-hidden="true" />
            </button>
            <button
              type="button"
              aria-label="Delete comment"
              title="Delete for everyone"
              className="flex h-6 w-6 items-center justify-center rounded-md text-ink-4 outline-none hover:bg-surface-2 hover:text-danger focus-visible:ring-2 focus-visible:ring-accent/60"
              onClick={onDelete}
            >
              <Trash2 className="h-3 w-3" aria-hidden="true" />
            </button>
          </span>
        )}
      </div>
      {editing ? (
        <div className="mt-1.5 pl-7">
          <CommentField
            value={text}
            onChange={setText}
            onSubmit={() => onSave(text)}
            onCancel={onCancelEdit}
            placeholder="Comment"
            label="Edit comment"
            submitLabel="Save"
            autoFocus
          />
        </div>
      ) : (
        <div className="mt-[3px] select-text whitespace-pre-wrap break-words pl-7 text-[13px] leading-[19px] text-ink [overflow-wrap:anywhere]">
          <Words text={m.text} />
        </div>
      )}
    </div>
  )
}

function ThreadCard({
  t,
  now,
  onOpen,
  active,
  heading,
}: {
  t: CommentThread
  now: number
  onOpen: (el: HTMLElement) => void
  active?: boolean
  heading?: ReactNode
}) {
  const first = liveMessages(t)[0]
  const replies = replyCount(t)
  return (
    <button
      type="button"
      data-thread={t.id}
      aria-current={active ? 'true' : undefined}
      className={cn(
        'block w-full min-w-0 px-3 py-2 text-left outline-none transition-colors duration-100 focus-visible:bg-surface-2',
        active ? 'bg-accent-soft' : 'hover:bg-surface-2'
      )}
      onClick={e => onOpen(e.currentTarget)}
    >
      {heading}
      <span className="flex min-w-0 items-center gap-2">
        <Avatar name={t.by} id={t.byId} size={18} />
        <span className="min-w-0 truncate text-[12px] font-semibold text-ink-2">{t.by}</span>
        <span className="flex-1" />
        <time className="shrink-0 text-[11px] text-ink-4" title={fullTime(t.lastAt)}>
          {agoLabel(t.lastAt, now)}
        </time>
      </span>
      <span className="mt-[3px] line-clamp-2 break-words pl-[26px] text-[12.5px] leading-[18px] text-ink [overflow-wrap:anywhere]">
        {t.messages[0]?.deleted ? <span className="italic text-ink-4">Comment deleted</span> : (first?.text ?? '')}
      </span>
      {replies > 0 && (
        <span className="mt-0.5 block pl-[26px] text-[11px] text-ink-3">
          {replies} {replies === 1 ? 'reply' : 'replies'}
        </span>
      )}
    </button>
  )
}

export interface PopoverArea {
  /** The board's size on screen. */
  w: number
  h: number
  /** Right edge the popover keeps left of (the panel, when it is open). */
  right: number
}

export function CommentPopover({
  focus,
  threads,
  shapes,
  store,
  me,
  readOnly,
  pin,
  area,
  onFocus,
  onClose,
  onResolved,
  onDeleted,
}: {
  focus: CommentFocus
  threads: readonly CommentThread[]
  shapes: ReadonlyMap<string, Shape>
  store: CommentStore
  me: CommentAuthor
  readOnly: boolean
  /** The pin it hangs from, screen px; null when its shape is gone or off the board. */
  pin: { x: number; y: number; w: number; h: number } | null
  area: PopoverArea
  onFocus: (next: CommentFocus) => void
  onClose: () => void
  /** A thread was resolved here (the board offers to reopen it). */
  onResolved: (id: string) => void
  /** One of your messages was deleted here (the board offers to bring it back). */
  onDeleted: (threadId: string, messageId: string, text: string) => void
}) {
  const box = useRef<HTMLDivElement>(null)
  const list = useRef<HTMLDivElement>(null)
  useOwnWheel(box)
  const now = useNow(30_000)
  const [height, setHeight] = useState(0)
  useLayoutEffect(() => {
    const el = box.current
    if (!el) return
    const measure = () => setHeight(prev => (Math.abs(prev - el.offsetHeight) < 1 ? prev : el.offsetHeight))
    measure()
    if (typeof ResizeObserver === 'undefined') return
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  const thread = focus.kind === 'thread' ? (threads.find(t => t.id === focus.id) ?? null) : null
  const anchor = focus.kind === 'thread' ? (thread?.anchor ?? '') : focus.anchor
  const shape = shapes.get(anchor)
  const onShape = threads.filter(t => t.anchor === anchor && isShown(t) && !t.resolved)
  const draftKey = focus.kind === 'thread' ? `reply:${focus.id}` : `new:${anchor}`
  const [draft, setDraft] = useDraft(draftKey)
  const [editing, setEditing] = useState<string | null>(null)
  const [error, setError] = useState('')
  const messages = thread?.messages

  // Opened at the newest message; follow new ones while at the bottom (always your own).
  const lastId = useRef<string | null>(null)
  const atBottom = useRef(true)
  useLayoutEffect(() => {
    const el = list.current
    const last = messages?.[messages.length - 1]
    if (!el || !last || last.id === lastId.current) return
    if (lastId.current === null || atBottom.current || sameAuthor(last.byId, me.id)) el.scrollTop = el.scrollHeight
    lastId.current = last.id
  }, [messages, me.id])

  // A thread that vanished (deleted everywhere) or a new one whose shape went: nothing to show.
  const gone = (focus.kind === 'thread' && (!thread || !isShown(thread))) || (focus.kind !== 'thread' && !shape)
  useEffect(() => {
    if (gone) onClose()
  }, [gone, onClose])

  const width = Math.min(POP_W, Math.max(240, area.w - 16))
  // Clear of the tool bar along the bottom (and the title bar along the top).
  const floor = area.h - BOTTOM_CLEAR
  const maxH = Math.max(180, Math.min(560, floor - 8))
  let left: number
  let top: number
  if (pin) {
    left = pin.x + pin.w + 8
    if (left + width > area.right - 8) left = pin.x - width - 8
    top = pin.y - 6
  } else if (focus.kind === 'thread' && focus.at) {
    left = focus.at.x - width - 8
    top = focus.at.y - 6
  } else {
    left = area.right - width - 12
    top = PANEL_TOP
  }
  left = Math.round(Math.min(Math.max(left, 8), Math.max(8, area.w - width - 8)))
  top = Math.round(Math.min(Math.max(top, 8), Math.max(8, floor - Math.min(height || 200, maxH))))

  if (gone) return null

  const title = thread ? anchorTitle(thread, shapes) : { name: shape ? shapeLabel(shape) : 'Shape', gone: false }
  const post = () => {
    setError('')
    try {
      if (focus.kind === 'thread' && thread) {
        store.reply(thread.id, draft, me, { anchorName: shape ? shapeLabel(shape) : undefined })
        atBottom.current = true
        setDraft('')
      } else if (focus.kind === 'new' && shape) {
        const id = store.create(shape.id, draft, me, { anchorName: shapeLabel(shape) })
        setDraft('')
        onFocus({ kind: 'thread', id })
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const header = (
    <header className="flex h-10 shrink-0 items-center gap-1 border-b border-line pl-3 pr-1.5">
      {focus.kind === 'thread' && onShape.length > 1 && !thread?.resolved && (
        <IconButton size="sm" label="All comments on this shape" tipBelow className="-ml-1.5" onClick={() => onFocus({ kind: 'shape', anchor })}>
          <ChevronLeft className="h-4 w-4" />
        </IconButton>
      )}
      <h2 className="flex min-w-0 flex-1 items-baseline gap-1.5 text-[12.5px] leading-5">
        <span className="min-w-0 truncate font-semibold text-ink">
          {focus.kind === 'new' ? `Comment on ${title.name}` : title.name}
        </span>
        {title.gone && <span className="shrink-0 text-[11.5px] text-ink-4">deleted shape</span>}
        {focus.kind === 'shape' && <span className="shrink-0 text-[11.5px] text-ink-4">{onShape.length} threads</span>}
      </h2>
      {thread && !readOnly && (
        thread.resolved ? (
          <IconButton size="sm" label="Reopen" tipBelow tipEnd onClick={() => store.setResolved(thread.id, false, me)}>
            <RotateCcw className="h-[15px] w-[15px]" />
          </IconButton>
        ) : (
          <IconButton
            size="sm"
            label="Resolve"
            tipBelow
            tipEnd
            onClick={() => {
              store.setResolved(thread.id, true, me)
              onResolved(thread.id)
            }}
          >
            <Check className="h-4 w-4" />
          </IconButton>
        )
      )}
      <IconButton size="sm" label="Close" keys="Esc" tipBelow tipEnd onClick={onClose}>
        <X className="h-4 w-4" />
      </IconButton>
    </header>
  )

  return (
    <div
      ref={box}
      role="dialog"
      aria-label={focus.kind === 'new' ? `New comment on ${title.name}` : `Comments on ${title.name}`}
      data-testid="comment-popover"
      className="pop-in absolute z-40 flex cursor-auto flex-col rounded-[14px] border border-line bg-surface shadow-2"
      style={{ left, top, width, maxHeight: maxH }}
      {...keepEvents}
      onKeyDown={e => {
        e.stopPropagation()
        if (e.key === 'Escape' && !e.defaultPrevented) {
          e.preventDefault()
          onClose()
        }
      }}
    >
      {header}
      {thread?.resolved && (
        <p className="flex shrink-0 items-center gap-1.5 border-b border-line px-3 py-1.5 text-[11.5px] text-ink-3">
          <Check className="h-3.5 w-3.5 shrink-0 text-success" aria-hidden="true" />
          <span className="min-w-0 truncate">
            Resolved{thread.resolvedBy ? ` by ${thread.resolvedBy}` : ''}
            {thread.resolvedAt ? ` · ${agoLabel(thread.resolvedAt, now)}` : ''}
          </span>
        </p>
      )}
      {focus.kind === 'shape' ? (
        <div ref={list} className="min-h-0 flex-1 overflow-y-auto overflow-x-hidden py-1 [scrollbar-width:thin]">
          {onShape.map(t => (
            <ThreadCard key={t.id} t={t} now={now} onOpen={() => onFocus({ kind: 'thread', id: t.id })} />
          ))}
        </div>
      ) : focus.kind === 'thread' && thread ? (
        <div
          ref={list}
          role="log"
          aria-label="Comments"
          className="min-h-0 flex-1 overflow-y-auto overflow-x-hidden py-1 [scrollbar-width:thin]"
          onScroll={e => {
            const el = e.currentTarget
            atBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 32
          }}
        >
          {thread.messages.map((m, i) => (
            <MessageRow
              key={m.id}
              m={m}
              first={i === 0}
              mine={sameAuthor(m.byId, me.id)}
              readOnly={readOnly}
              now={now}
              editing={editing === m.id}
              onEdit={() => setEditing(m.id)}
              onCancelEdit={() => setEditing(null)}
              onSave={text => {
                try {
                  store.edit(thread.id, m.id, text, me)
                  setEditing(null)
                } catch (e) {
                  setError(e instanceof Error ? e.message : String(e))
                }
              }}
              onDelete={() => {
                if (store.remove(thread.id, m.id, me)) onDeleted(thread.id, m.id, m.text)
              }}
            />
          ))}
        </div>
      ) : null}
      {!readOnly && focus.kind !== 'shape' && (
        <div className={cn('shrink-0 px-3 pb-3', focus.kind === 'thread' ? 'border-t border-line pt-2.5' : 'pt-3')}>
          <CommentField
            value={draft}
            onChange={v => {
              setDraft(v)
              setError('')
            }}
            onSubmit={post}
            onCancel={focus.kind === 'new' ? onClose : undefined}
            placeholder={focus.kind === 'new' ? 'Add a comment…' : 'Reply…'}
            label={focus.kind === 'new' ? 'Comment' : 'Reply'}
            submitLabel={focus.kind === 'new' ? 'Comment' : 'Reply'}
            inline={focus.kind === 'thread'}
            autoFocus={!editing}
          />
          {error && (
            <p role="alert" className="mt-1.5 text-[11.5px] text-danger">
              {error}
            </p>
          )}
        </div>
      )}
      {!readOnly && focus.kind === 'shape' && (
        <div className="shrink-0 border-t border-line p-1.5">
          <button
            type="button"
            className="flex h-8 w-full items-center gap-2 rounded-lg px-2 text-[12.5px] font-medium text-ink-2 outline-none hover:bg-surface-2 hover:text-ink focus-visible:ring-2 focus-visible:ring-accent/60"
            onClick={() => onFocus({ kind: 'new', anchor })}
          >
            <MessageSquarePlus className="h-4 w-4 text-ink-3" aria-hidden="true" />
            New comment
          </button>
        </div>
      )}
    </div>
  )
}

// ---- the panel ----------------------------------------------------------------------

export function CommentsPanel({
  threads,
  shapes,
  focus,
  readOnly,
  onPick,
  onClose,
}: {
  threads: readonly CommentThread[]
  shapes: ReadonlyMap<string, Shape>
  focus: CommentFocus | null
  readOnly: boolean
  /** A thread was picked; `at` is the row's left middle, screen px of the board. */
  onPick: (t: CommentThread, at: Point) => void
  onClose: () => void
}) {
  const root = useRef<HTMLDivElement>(null)
  useOwnWheel(root)
  const now = useNow(30_000)
  const [showResolved, setShowResolved] = useState(false)
  const shown = threads.filter(isShown)
  const byActivity = (a: CommentThread, b: CommentThread) => b.lastAt - a.lastAt || (a.id < b.id ? -1 : 1)
  const open = shown.filter(t => !t.resolved).sort(byActivity)
  const resolved = shown.filter(t => t.resolved).sort(byActivity)
  const active = focus?.kind === 'thread' ? focus.id : null

  const pick = (t: CommentThread, el: HTMLElement) => {
    const r = el.getBoundingClientRect()
    const base = root.current?.offsetParent?.getBoundingClientRect()
    onPick(t, { x: r.left - (base?.left ?? 0), y: r.top - (base?.top ?? 0) })
  }

  const row = (t: CommentThread) => {
    const where = anchorTitle(t, shapes)
    return (
      <ThreadCard
          key={t.id}
          t={t}
          now={now}
          active={active === t.id}
          onOpen={el => pick(t, el)}
          heading={
            <span className="mb-1 flex min-w-0 items-baseline gap-1.5 text-[11.5px] leading-4">
              <span className={cn('min-w-0 truncate font-medium', where.gone ? 'text-ink-4' : 'text-ink-3')}>{where.name}</span>
              {where.gone && <span className="shrink-0 text-ink-4">· deleted shape</span>}
            </span>
          }
        />
    )
  }

  return (
    <aside
      ref={root}
      aria-label="Comments"
      data-testid="comments-panel"
      className="pop-in absolute right-3 z-40 flex cursor-auto flex-col overflow-hidden rounded-[14px] border border-line bg-surface shadow-2"
      style={{ top: PANEL_TOP, bottom: PANEL_BOTTOM, width: `min(${PANEL_W}px, calc(100% - 24px))` }}
      {...keepEvents}
      onKeyDown={e => {
        e.stopPropagation()
        if (e.key === 'Escape') {
          e.preventDefault()
          onClose()
        }
      }}
    >
      <header className="flex h-11 shrink-0 items-center gap-2 border-b border-line pl-3.5 pr-1.5">
        <h2 className="text-[13px] font-semibold tracking-[-0.005em] text-ink">Comments</h2>
        {open.length > 0 && <span className="text-[12px] tabular-nums text-ink-3">{open.length} open</span>}
        <span className="flex-1" />
        <IconButton size="sm" label="Close comments" tipBelow tipEnd onClick={onClose}>
          <X className="h-4 w-4" />
        </IconButton>
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto overflow-x-hidden [scrollbar-width:thin]">
        {shown.length === 0 ? (
          <div className="px-5 py-8 text-center">
            <p className="text-[13px] font-semibold text-ink-2">No comments yet</p>
            {!readOnly && (
              <p className="mt-1 text-[12px] leading-relaxed text-ink-3">
                Select a frame or any shape and choose <span className="font-medium text-ink-2">Comment</span>, press <Kbd>{COMMENT_KEYS}</Kbd>, or
                right-click it.
              </p>
            )}
          </div>
        ) : (
          <>
            {open.length === 0 && <p className="px-3.5 py-3 text-[12px] text-ink-3">Every comment here is resolved.</p>}
            <div className="divide-y divide-line">{open.map(row)}</div>
            {resolved.length > 0 && (
              <div className="border-t border-line">
                <button
                  type="button"
                  aria-expanded={showResolved}
                  className="flex h-9 w-full items-center gap-1.5 px-3.5 text-left text-[12px] font-medium text-ink-3 outline-none hover:text-ink-2 focus-visible:bg-surface-2"
                  onClick={() => setShowResolved(v => !v)}
                >
                  <ChevronDown className={cn('h-3.5 w-3.5 transition-transform', !showResolved && '-rotate-90')} aria-hidden="true" />
                  Resolved
                  <span className="tabular-nums text-ink-4">{resolved.length}</span>
                </button>
                {showResolved && <div className="divide-y divide-line opacity-80">{resolved.map(row)}</div>}
              </div>
            )}
          </>
        )}
      </div>
    </aside>
  )
}

/** The Comments toggle beside chat and search. */
export function CommentsButton({ open, count, onToggle }: { open: boolean; count: number; onToggle: () => void }) {
  return (
    <IconButton
      size="sm"
      label={open ? 'Hide comments' : count > 0 ? `Comments, ${count} open` : 'Comments'}
      tipBelow
      tipEnd
      active={open}
      data-testid="comments-toggle"
      onClick={onToggle}
    >
      <MessageSquareText className="h-4 w-4" />
    </IconButton>
  )
}

// ---- right-click menu -----------------------------------------------------------------

export interface MenuItem {
  label: string
  keys?: string
  danger?: boolean
  disabled?: boolean
  run: () => void
}

/** A small menu at the pointer: never past the board's edges; Escape or a click elsewhere closes it. */
export function BoardMenu({
  at,
  area,
  items,
  onClose,
}: {
  at: Point
  area: { w: number; h: number }
  items: (MenuItem | 'divider')[]
  onClose: () => void
}) {
  const root = useRef<HTMLDivElement>(null)
  const [size, setSize] = useState({ w: 200, h: 0 })
  useLayoutEffect(() => {
    const el = root.current
    if (el) setSize({ w: el.offsetWidth, h: el.offsetHeight })
    el?.querySelector<HTMLElement>('[role="menuitem"]:not([disabled])')?.focus({ preventScroll: true })
  }, [])
  useEffect(() => {
    const away = (e: PointerEvent) => {
      if (!root.current?.contains(e.target as Node)) onClose()
    }
    const blur = () => onClose()
    window.addEventListener('pointerdown', away, true)
    window.addEventListener('wheel', blur, { capture: true, passive: true })
    window.addEventListener('blur', blur)
    return () => {
      window.removeEventListener('pointerdown', away, true)
      window.removeEventListener('wheel', blur, true)
      window.removeEventListener('blur', blur)
    }
  }, [onClose])
  const left = Math.max(6, Math.min(at.x, area.w - size.w - 6))
  const top = Math.max(6, at.y + size.h > area.h - 6 ? at.y - size.h : at.y)
  return (
    <div
      ref={root}
      role="menu"
      aria-label="Shape"
      data-testid="board-menu"
      className="pop-in absolute z-50 min-w-[196px] cursor-default rounded-[10px] border border-line bg-surface p-1 shadow-2"
      style={{ left, top }}
      {...keepEvents}
      onContextMenu={e => e.preventDefault()}
      onKeyDown={e => {
        e.stopPropagation()
        if (e.key === 'Escape') {
          e.preventDefault()
          onClose()
          return
        }
        if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return
        e.preventDefault()
        const all = [...(root.current?.querySelectorAll<HTMLElement>('[role="menuitem"]:not([disabled])') ?? [])]
        const i = all.indexOf(document.activeElement as HTMLElement)
        all[(i + (e.key === 'ArrowDown' ? 1 : -1) + all.length) % all.length]?.focus({ preventScroll: true })
      }}
    >
      {items.map((item, i) =>
        item === 'divider' ? (
          <div key={`d${i}`} className="mx-1 my-1 h-px bg-line" role="separator" />
        ) : (
          <button
            key={item.label}
            type="button"
            role="menuitem"
            disabled={item.disabled}
            className={cn(
              'flex h-7 w-full items-center gap-3 rounded-md px-2 text-left text-[12.5px] outline-none disabled:opacity-40',
              item.danger ? 'text-danger hover:bg-danger/10 focus:bg-danger/10' : 'text-ink hover:bg-surface-2 focus:bg-surface-2'
            )}
            onClick={() => {
              onClose()
              item.run()
            }}
          >
            <span className="flex-1 truncate">{item.label}</span>
            {item.keys && <span className="shrink-0 text-[11px] tabular-nums text-ink-4">{item.keys}</span>}
          </button>
        )
      )}
    </div>
  )
}

