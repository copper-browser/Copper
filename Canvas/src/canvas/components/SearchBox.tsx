/** The board's search box (screen space, top centre). State lives in `useBoardSearch`. */
import { Fragment, useEffect, useId, useRef, type KeyboardEvent } from 'react'
import { ArrowUpRight, CalendarRange, ChevronDown, ChevronUp, Frame, Link2, ListChecks, MessageSquare, Search, StickyNote, Type, X } from 'lucide-react'
import type { Highlighted, SearchKind, SearchResult } from '../search'
import type { BoardSearch } from '../use-search'
import { IconButton, Panel, cn } from './ui'

const KIND_ICON: Record<SearchKind, typeof StickyNote> = {
  frame: Frame,
  sticky: StickyNote,
  text: Type,
  arrow: ArrowUpRight,
  link: Link2,
  checklist: ListChecks,
  timeline: CalendarRange,
  comment: MessageSquare,
}
const KIND_LABEL: Record<SearchKind, string> = {
  frame: 'Frame',
  sticky: 'Sticky',
  text: 'Text',
  arrow: 'Arrow label',
  link: 'Link',
  checklist: 'Checklist',
  timeline: 'Timeline',
  comment: 'Comment',
}

const MAX_ROWS = 100

function Marked({ value }: { value: Highlighted }) {
  const parts = []
  let at = 0
  for (const [a, b] of value.marks) {
    if (a > at) parts.push(value.text.slice(at, a))
    parts.push(
      <mark key={a} className="rounded-[3px] bg-[var(--mark)] px-px text-ink">
        {value.text.slice(a, b)}
      </mark>
    )
    at = b
  }
  if (at < value.text.length) parts.push(value.text.slice(at))
  return (
    <>
      {parts.map((p, i) => (
        <Fragment key={i}>{p}</Fragment>
      ))}
    </>
  )
}

export function SearchBox({ search, onReveal }: { search: BoardSearch; onReveal: (hit: SearchResult) => void }) {
  const listId = useId()
  const listRef = useRef<HTMLUListElement>(null)
  const { open, focusKey, inputRef, boxRef, active, results, query } = search

  // The board's wheel listener is native and non-passive; stop it natively.
  useEffect(() => {
    const el = boxRef.current
    if (!el) return
    const onWheel = (e: WheelEvent) => e.stopPropagation()
    el.addEventListener('wheel', onWheel)
    return () => el.removeEventListener('wheel', onWheel)
  }, [open, boxRef])

  useEffect(() => {
    if (!open) return
    const el = inputRef.current
    el?.focus({ preventScroll: true })
    el?.select()
  }, [open, focusKey, inputRef])

  useEffect(() => {
    listRef.current?.querySelector('[aria-selected="true"]')?.scrollIntoView?.({ block: 'nearest' })
  }, [active])

  if (!open) return null

  const go = (dir: 1 | -1) => {
    const hit = search.step(dir)
    if (hit) onReveal(hit)
  }

  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    e.stopPropagation()
    if (e.key === 'Escape') {
      e.preventDefault()
      search.close()
    } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault()
      search.move(e.key === 'ArrowDown' ? 1 : -1)
    } else if (e.key === 'Enter') {
      e.preventDefault()
      go(e.shiftKey ? -1 : 1)
    }
  }

  const n = results.length
  const hasQuery = query.trim() !== ''
  const count = !hasQuery ? '' : n === 0 ? 'No matches' : `${active + 1} of ${n}`
  const optionId = (i: number) => `${listId}-${i}`

  return (
    <div ref={boxRef} className="absolute left-1/2 top-3 z-40 w-[min(460px,calc(100%-1.5rem))] -translate-x-1/2">
      <Panel role="search" aria-label="Search the canvas" data-testid="canvas-search" className="pop-in cursor-auto select-text overflow-hidden">
        <div className="flex items-center gap-2 py-1.5 pl-3 pr-1.5">
          <Search className="h-4 w-4 shrink-0 text-ink-3" aria-hidden="true" />
          <input
            ref={inputRef}
            role="combobox"
            aria-label="Search notes, frames, links, arrows and comments"
            aria-expanded={hasQuery && n > 0}
            aria-controls={listId}
            aria-activedescendant={active >= 0 ? optionId(active) : undefined}
            aria-autocomplete="list"
            value={query}
            placeholder="Search the canvas"
            spellCheck={false}
            onChange={e => search.setQuery(e.target.value)}
            onKeyDown={onKeyDown}
            className="h-7 min-w-0 flex-1 bg-transparent text-[13.5px] text-ink outline-none placeholder:text-ink-4"
          />
          <span aria-live="polite" className="shrink-0 text-[11.5px] tabular-nums text-ink-3">
            {count}
          </span>
          <IconButton
            size="sm"
            label="Previous match"
            keys="⇧↵"
            tipBelow
            disabled={n === 0}
            onMouseDown={e => e.preventDefault()}
            onClick={() => go(-1)}
          >
            <ChevronUp className="h-4 w-4" />
          </IconButton>
          <IconButton
            size="sm"
            label="Next match"
            keys="↵"
            tipBelow
            disabled={n === 0}
            onMouseDown={e => e.preventDefault()}
            onClick={() => go(1)}
          >
            <ChevronDown className="h-4 w-4" />
          </IconButton>
          <IconButton size="sm" label="Close search" keys="Esc" tipBelow onClick={search.close}>
            <X className="h-4 w-4" />
          </IconButton>
        </div>

        {hasQuery && n > 0 && (
          <ul
            ref={listRef}
            id={listId}
            role="listbox"
            aria-label="Matches"
            className="@container max-h-[min(320px,50vh)] overflow-y-auto overflow-x-hidden border-t border-line py-1"
          >
            {results.slice(0, MAX_ROWS).map((hit, i) => {
              const Icon = KIND_ICON[hit.kind]
              return (
                <li
                  key={hit.ref}
                  id={optionId(i)}
                  role="option"
                  aria-selected={i === active}
                  className={cn('flex cursor-pointer items-start gap-2.5 px-3 py-1.5', i === active ? 'bg-surface-2' : 'hover:bg-surface-2/60')}
                  onMouseDown={e => e.preventDefault()}
                  onClick={() => {
                    const next = search.land(i)
                    if (next) onReveal(next)
                  }}
                >
                  <Icon className="mt-[3px] h-3.5 w-3.5 shrink-0 text-ink-3" aria-label={KIND_LABEL[hit.kind]} />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-[13px] leading-5 text-ink">
                      <Marked value={hit.primary} />
                    </p>
                    {(hit.secondary || hit.by) && (
                      <p className="flex min-w-0 items-baseline gap-1 text-[11.5px] leading-4 text-ink-3">
                        {hit.secondary && (
                          <span className="min-w-0 truncate">
                            <Marked value={hit.secondary} />
                          </span>
                        )}
                        {hit.by && (
                          <span data-part="by" className="min-w-0 max-w-[65%] shrink-0 truncate text-[11px] text-ink-4 @max-[340px]:hidden">
                            {hit.secondary ? '· ' : ''}by {hit.by}
                          </span>
                        )}
                      </p>
                    )}
                  </div>
                </li>
              )
            })}
          </ul>
        )}

        {hasQuery && n === 0 && (
          <p className="border-t border-line px-3 py-2.5 text-[12.5px] text-ink-3">Nothing on the board matches “{query.trim()}”.</p>
        )}
      </Panel>
    </div>
  )
}
