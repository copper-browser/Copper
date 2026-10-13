/**
 * State behind the board's search box: open/closed, the query, results,
 * which hit is highlighted, and Cmd/Ctrl+F (captured, so the browser's own
 * find never opens over the board).
 */
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type RefObject } from 'react'
import type { CommentThread } from './comments'
import { boardSearchItems, commentSearchItems, indexSearchItems, searchIndex, snippetChars, stepHit, type SearchResult } from './search'
import type { Shape } from './types'

const isMac = () =>
  typeof navigator !== 'undefined' && /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent)

const NO_THREADS: readonly CommentThread[] = []

export interface BoardSearch {
  open: boolean
  query: string
  setQuery: (query: string) => void
  results: SearchResult[]
  /** Index of the highlighted hit; -1 when there are none. */
  active: number
  /** The view is on the highlighted hit (Enter moves on to the next one). */
  landed: boolean
  show: () => void
  close: () => void
  move: (dir: 1 | -1) => void
  step: (dir: 1 | -1) => SearchResult | null
  land: (index: number) => SearchResult | null
  inputRef: RefObject<HTMLInputElement | null>
  boxRef: RefObject<HTMLDivElement | null>
  /** Screen px of the viewport's top the open box covers; 0 when closed. */
  coveredTop: () => number
  focusKey: number
}

export function useBoardSearch({
  shapes,
  threads = NO_THREADS,
  viewport,
}: {
  shapes: ReadonlyMap<string, Shape>
  /** Comment threads: found by what was said in them. */
  threads?: readonly CommentThread[]
  viewport: RefObject<HTMLElement | null>
}): BoardSearch {
  const [open, setOpen] = useState(false)
  const [query, setQueryState] = useState('')
  const [cursor, setCursor] = useState<{ ref: string | null; landed: boolean }>({ ref: null, landed: false })
  const [focusKey, setFocusKey] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const boxRef = useRef<HTMLDivElement>(null)

  const items = useMemo(
    () => (open ? [...boardSearchItems(shapes.values()), ...commentSearchItems(threads, shapes)] : []),
    [open, shapes, threads]
  )
  const index = useMemo(() => indexSearchItems(items), [items])
  // Snippets are cut to what a row shows, centred on the match, so a narrow
  // box still shows the matched word.
  const [width, setWidth] = useState(460)
  useLayoutEffect(() => {
    const el = boxRef.current
    if (!open || !el) return
    const measure = () => {
      const w = Math.round(el.getBoundingClientRect().width)
      if (w > 0) setWidth(prev => (prev === w ? prev : w))
    }
    measure()
    if (typeof ResizeObserver === 'undefined') return
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    return () => ro.disconnect()
  }, [open])
  const snippet = snippetChars(width)
  const results = useMemo(() => searchIndex(index, query, { snippet }), [index, query, snippet])

  const found = cursor.ref ? results.findIndex(r => r.ref === cursor.ref) : -1
  const active = results.length === 0 ? -1 : Math.max(found, 0)
  const landed = found !== -1 && cursor.landed

  const setQuery = useCallback((next: string) => {
    setQueryState(next)
    setCursor({ ref: null, landed: false })
  }, [])

  const show = useCallback(() => {
    setOpen(true)
    setFocusKey(k => k + 1)
  }, [])

  const close = useCallback(() => {
    setOpen(false)
    setCursor(c => ({ ...c, landed: false }))
    viewport.current?.focus({ preventScroll: true })
  }, [viewport])

  const move = (dir: 1 | -1) => {
    if (results.length === 0) return
    const next = (active + dir + results.length) % results.length
    setCursor({ ref: results[next]!.ref, landed: false })
  }

  const step = (dir: 1 | -1) => {
    const next = stepHit(results.length, active, landed, dir)
    const hit = results[next]
    if (!hit) return null
    setCursor({ ref: hit.ref, landed: true })
    return hit
  }

  const land = (i: number) => {
    const hit = results[i]
    if (!hit) return null
    setCursor({ ref: hit.ref, landed: true })
    return hit
  }

  // Cmd+F (Ctrl+F off the Mac) opens this instead of the browser's find,
  // wherever focus is on the page, sticky editors included. Capture phase,
  // so no editor sees the key first.
  const openRef = useRef(open)
  useEffect(() => {
    openRef.current = open
  })
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target instanceof Element ? e.target : null
      if (e.key === 'Escape' && openRef.current && (target === viewport.current || target === document.body)) {
        close()
        return
      }
      if (e.key.toLowerCase() !== 'f' || e.altKey || e.shiftKey) return
      if (!(isMac() ? e.metaKey : e.ctrlKey)) return
      e.preventDefault()
      e.stopPropagation()
      show()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [show, close, viewport])

  return {
    open,
    query,
    setQuery,
    results,
    active,
    landed,
    show,
    close,
    move,
    step,
    land,
    inputRef,
    boxRef,
    coveredTop: () => {
      const box = boxRef.current?.getBoundingClientRect()
      const top = viewport.current?.getBoundingClientRect().top
      return box && top !== undefined ? Math.max(0, box.bottom - top) : 0
    },
    focusKey,
  }
}
