/**
 * The board: pan/zoom, the pointer state machine (select, marquee, move,
 * resize, draw frames and arrows, reattach arrow ends), keyboard shortcuts,
 * clipboard, drag-and-drop, and the layer stack that draws it all.
 */
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  useSyncExternalStore,
  type DragEvent as ReactDragEvent,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent as ReactPointerEvent,
} from 'react'
import { controller, type Session } from '../../controller'
import { hasNativeHost, postToHost } from '../../host-bridge'
import { findFreeSpot, occupied } from '../../placement'
import { frameChildren, hostOf } from '../../ops'
import { arrowBox, arrowPath, type ArrowPath } from '../arrows'
import { readAgents } from '../agents'
import { LOCAL, newId, type ShapeInput } from '../doc'
import {
  boxFromPoints,
  boxesOverlap,
  containsBox,
  containsPoint,
  fitBoxes,
  nearestSide,
  screenToWorld,
  unionBox,
  visibleWorld,
  zoomAt,
  zoomTo,
  type Box,
  type Point,
  type Side,
  type View,
} from '../geometry'
import { countRender } from '../debug'
import { gridBackground } from '../grid'
import { growFor } from '../overflow'
import { imageFile, imageFromFile, imageFromUrl, imageSizeFor, isUrlText, looksLikeImageUrl, urlFrom } from '../images'
import { MIN_SIZE, isResizable, minSizeOf, resizeBox, resizeBoxKeepAspect, type Handle } from '../resize'
import { LIVE_SIZE, framesToMount, frameUrl } from '../frames'
import { COMMENT_REF, arrowLabelBox, revealView, type SearchResult } from '../search'
import { isShown, type CommentAuthor } from '../comments'
import { statusView } from '../status'
import { SHAPE_SIZE, isRefEndpoint, type Endpoint, type NamedColor, type Shape, type ShapeColor } from '../types'
import { LaserCanvas, LaserTrails } from '../laser'
import { useLiveAgents, usePeers, useRemoteLasers } from '../use-presence'
import { useBoardSearch } from '../use-search'
import { useViewFlight } from '../use-view-flight'
import {
  AuthorChip,
  CompactBar,
  EditHint,
  EmptyHint,
  LinkPrompt,
  SelectionBar,
  ShortcutsSheet,
  TOOL_KEYS,
  TitleBar,
  Toasts,
  Toolbar,
  TopRight,
  ZoomBar,
  type Tool,
  type Toast,
} from './Chrome'
import { BoardContext, type BoardActions, type EditField } from './context'
import {
  AgentCursors,
  AnchorDots,
  ArrowDraft,
  ArrowEndHandles,
  EditingOutline,
  Marquee,
  PeerCursors,
  ResizeHandles,
  SearchRings,
  SelectionOutlines,
  type RingPlace,
} from './Overlays'
import { SearchBox } from './SearchBox'
import {
  BoardMenu,
  COMMENT_KEYS,
  CommentPins,
  CommentPopover,
  CommentsPanel,
  PANEL_W,
  PIN_H,
  POP_W,
  pinPlaces,
  type CommentFocus,
  type MenuItem,
} from './Comments'
import { ArrowLabel, ArrowLayer, FrameView, ImageView, LinkView, StickyView, TextView, type DrawnArrow } from './Shapes'
import { ChecklistView, checklistEditField } from './Checklist'
import { checklistText, isChecklist } from '../checklist'
import { TimelineView } from './Timeline'
import { TIMELINE_SIZE, isTimeline, neededHeight, newTimelineText } from '../timeline'
import { WebFrame, type FrameUser } from './WebFrame'
import { MOD, cn } from './ui'

type Gesture =
  | { kind: 'pan'; start: Point; view: View }
  | {
      kind: 'move'
      start: Point
      startScreen: Point
      origins: Map<string, Shape>
      moved: boolean
      hit: string
      last: number
      next?: Map<string, Partial<Shape>>
      /** Pressed the shield of the frame that was already the selection: a click (no drag) puts it in use. */
      shield?: boolean
    }
  | { kind: 'resize'; id: string; handle: Handle; start: Point; box: Box; type: Shape['type']; live?: boolean; view?: string; at?: Box; last: number }
  | { kind: 'marquee'; start: Point; startScreen: Point; base: string[]; additive: boolean; frameClick?: string; moved: boolean }
  | { kind: 'frame'; start: Point; startScreen: Point; box?: Box }
  | { kind: 'arrow'; from: Endpoint; startScreen: Point; moved: boolean }
  | { kind: 'arrow-end'; id: string; end: 'from' | 'to'; other: Endpoint | undefined }
  | { kind: 'laser' }

interface Draft {
  from: Endpoint
  to: Endpoint
  hover: { id: string; side?: Side } | null
}

interface ClipShape extends ShapeInput {
  id: string
}

const CLIP_TYPE = 'application/x-copper-canvas'
const SEND_MS = 50
/** Screen px the tool bar takes at the bottom (its panel and margin). */
const TOOLBAR_PX = 68
const DOUBLE_MS = 350
/** The layer stays promoted until the view has rested this long. */
const SETTLE_MS = 150
/** How long a released laser stroke stays in awareness (its hold and fade, and a margin). */
const LASER_LINGER_MS = 3200
/** Laser cursor: a small glowing dot. */
const LASER_CURSOR = `url("data:image/svg+xml;utf8,${encodeURIComponent(
  "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'><defs><radialGradient id='g'><stop offset='0' stop-color='#ff5a36' stop-opacity='0.55'/><stop offset='1' stop-color='#ff5a36' stop-opacity='0'/></radialGradient></defs><circle cx='12' cy='12' r='12' fill='url(#g)'/><circle cx='12' cy='12' r='3.5' fill='#ff5a36'/><circle cx='12' cy='12' r='2' fill='white' fill-opacity='0.9'/></svg>"
)}") 12 12, crosshair`

const isTextField = (el: EventTarget | null) =>
  el instanceof HTMLElement && (el.isContentEditable || el.closest('input, textarea, select') !== null)

const NO_USERS: readonly FrameUser[] = []

/** A checklist as plain text for the clipboard: its title, then each row, its pick and its comment. */
const copyChecklist = (s: Shape | undefined) => (s ? checklistText(s.title, s.rows ?? [], s.picks ?? {}, s.columns ?? [], s.notes ?? {}) : '')

const sortZ = (a: Shape, b: Shape) => a.z - b.z || a.createdAt - b.createdAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)

export function Board({ session }: { session: Session }) {
  countRender('boardRenders')
  const { store, awareness, cfg } = session
  const readOnly = cfg.readOnly
  const me = cfg.me
  const shapes = useSyncExternalStore(store.subscribe, store.getShapes)
  const selectionList = useSyncExternalStore(controller.subscribeSelection, controller.getSelection)
  const selection = useMemo(() => new Set(selectionList), [selectionList])
  const sync = useSyncExternalStore(controller.subscribe, () => session.status)
  const hostStatus = useSyncExternalStore(controller.subscribe, controller.getHostStatus)
  const share = useSyncExternalStore(controller.subscribe, controller.getShare)
  const status = useMemo(
    () => statusView({ kind: cfg.kind, online: cfg.online, sync, host: hostStatus, readOnly }),
    [cfg.kind, cfg.online, sync, hostStatus, readOnly]
  )
  const peers = usePeers(awareness)
  const agents = useLiveAgents(store.agents)
  /** Laser strokes, ours and everyone else's (from awareness); never in the doc. */
  const trails = useMemo(() => new LaserTrails(), [])
  useRemoteLasers(awareness, trails)
  const laserSent = useRef(0)
  const laserLinger = useRef<ReturnType<typeof setTimeout> | null>(null)

  const viewport = useRef<HTMLDivElement>(null)
  /** The viewport's page rect, read once and dropped when it can change: pointer and wheel events never force layout. */
  const rectCache = useRef<DOMRect | null>(null)
  const viewportRect = () => (rectCache.current ??= viewport.current!.getBoundingClientRect())
  const layer = useRef<HTMLDivElement>(null)
  const hoverRef = useRef<string | null>(null)
  const [size, setSize] = useState({ w: 0, h: 0 })
  const [view, setView] = useState<View>({ x: 0, y: 0, z: 1 })
  const flight = useViewFlight(view, setView, viewport)
  const [tool, setToolState] = useState<Tool>('select')
  const [noteColor, setNoteColor] = useState<NamedColor>('yellow')
  const [editing, setEditing] = useState<{ id: string; field: EditField } | null>(null)
  const [drag, setDrag] = useState<Map<string, Partial<Shape>> | null>(null)
  const [marquee, setMarquee] = useState<Box | null>(null)
  const [draft, setDraft] = useState<Draft | null>(null)
  const [pendingFrom, setPendingFrom] = useState<Endpoint | null>(null)
  const [frameDraft, setFrameDraft] = useState<Box | null>(null)
  /** The arrow whose end is being dragged: its draft stands in for it. */
  const [reEnding, setReEnding] = useState<string | null>(null)
  const [hover, setHover] = useState<string | null>(null)
  const [arrowHover, setArrowHover] = useState<{ id: string; side?: Side } | null>(null)
  const [space, setSpace] = useState(false)
  const [panning, setPanning] = useState(false)
  const [linkAt, setLinkAt] = useState<Point | null>(null)
  const [help, setHelp] = useState(false)
  const [toasts, setToasts] = useState<Toast[]>([])
  const [history, setHistory] = useState({ undo: false, redo: false })
  /** Comment threads on shapes (`comments.ts`); the open one, the panel, the right-click menu. */
  const threads = useSyncExternalStore(store.comments.subscribe, store.comments.getThreads)
  const [commentsOpen, setCommentsOpen] = useState(false)
  const [commentFocus, setCommentFocus] = useState<CommentFocus | null>(null)
  const [menu, setMenu] = useState<{ at: Point; id: string } | null>(null)
  const author = useMemo<CommentAuthor>(() => ({ id: me.id, name: me.name }), [me.id, me.name])
  const gesture = useRef<Gesture | null>(null)
  const pointer = useRef<Point | null>(null)
  const fileInput = useRef<HTMLInputElement>(null)
  const imageAt = useRef<{ frame: string | null; at: Point; free?: boolean } | null>(null)
  const lastDown = useRef({ id: '', at: 0, p: { x: 0, y: 0 } })
  const lastCursor = useRef(0)
  /** Set when a pointerdown opened an editor: its mousedown must not refocus the board. */
  const keepFocus = useRef(false)
  const clip = useRef<{ text: string; shapes: ClipShape[] } | null>(null)
  const pasteCount = useRef(0)
  const viewRef = useRef(view)
  const sizeRef = useRef(size)
  useEffect(() => {
    viewRef.current = view
    sizeRef.current = size
    controller.setViewInfo({ view, width: size.w, height: size.h })
  }, [view, size])

  const select = useCallback((ids: Iterable<string>) => controller.setSelection([...ids]), [])
  const setTool = useCallback((next: Tool) => {
    setToolState(next)
    setPendingFrom(null)
    setDraft(null)
  }, [])

  const toast = useCallback((text: string, tone: Toast['tone'] = 'info', ms = 2600, action?: Toast['action']) => {
    const id = Date.now() + Math.random()
    const dismiss = () => setToasts(t => t.filter(x => x.id !== id))
    const act = action && { label: action.label, run: () => (dismiss(), action.run()) }
    setToasts(t => [...t.slice(-2), { id, text, tone, ...(act ? { action: act } : {}) }])
    setTimeout(dismiss, ms)
  }, [])

  // ---- live web frames ------------------------------------------------------------

  /** The live frame in use here (its shield is off and it has the keyboard). */
  const [activeFrame, setActiveFrame] = useState<string | null>(null)
  const activeId = activeFrame && shapes.get(activeFrame)?.live ? activeFrame : null
  // Everyone sees who is using which frame (a ring and a name on it).
  useEffect(() => {
    awareness.setLocalStateField('frame', activeId)
  }, [awareness, activeId])
  const activate = useCallback(
    (id: string) => {
      const s = store.get(id)
      if (!s?.live || !frameUrl(s.url)) return
      controller.setSelection([id])
      setActiveFrame(id)
    },
    [store]
  )
  const deactivate = useCallback(() => {
    setActiveFrame(null)
    viewport.current?.focus({ preventScroll: true })
  }, [])
  /** A link as its card, or as the site itself: one undo step, sized for what it has become. */
  const setLive = useCallback(
    (id: string, on: boolean) => {
      const s = store.get(id)
      if (!s || s.type !== 'link' || readOnly) return
      if (on && !frameUrl(s.url)) return
      store.undo.stopCapturing()
      if (on) store.update(id, { live: true, w: Math.max(s.w, LIVE_SIZE.w), h: Math.max(s.h, LIVE_SIZE.h) }, LOCAL)
      else {
        store.update(id, { live: false, w: SHAPE_SIZE.link.w, h: SHAPE_SIZE.link.h }, LOCAL)
        if (activeFrame === id) setActiveFrame(null)
      }
      store.undo.stopCapturing()
    },
    [store, readOnly, activeFrame]
  )

  // ---- laser ------------------------------------------------------------------

  /** Put our stroke in awareness, at most ~30 times a second (peers draw it). */
  const publishLaser = useCallback(
    (force = false) => {
      const now = performance.now()
      if (!force && now - laserSent.current < 33) return
      laserSent.current = now
      awareness.setLocalStateField('laser', trails.localWire())
    },
    [awareness, trails]
  )

  // Leaving the laser mid-stroke drops the stroke; leaving the board forgets it.
  useEffect(() => {
    if (tool === 'laser' || gesture.current?.kind !== 'laser') return
    gesture.current = null
    trails.cancel()
    awareness.setLocalStateField('laser', null)
  }, [tool, trails, awareness])
  useEffect(
    () => () => {
      if (laserLinger.current) clearTimeout(laserLinger.current)
    },
    []
  )

  // ---- geometry of what is on the board --------------------------------------

  /** A shape with the local drag/resize applied, so it moves at frame rate. */
  const placed = useCallback(
    (shape: Shape): Shape => {
      const o = drag?.get(shape.id)
      return o ? { ...shape, ...o } : shape
    },
    [drag]
  )

  const live = useMemo(() => {
    const list = [...shapes.values()].map(placed).sort(sortZ)
    const byId = new Map(list.map(s => [s.id, s] as const))
    const boxOf = (id: string): Box | null => {
      const s = byId.get(id)
      return s && s.type !== 'arrow' ? s : null
    }
    const arrows: DrawnArrow[] = []
    for (const s of list) {
      if (s.type !== 'arrow') continue
      const path = arrowPath(s, boxOf)
      if (path) arrows.push({ shape: s, path })
    }
    return { list, byId, boxOf, arrows, arrowById: new Map(arrows.map(a => [a.shape.id, a.path] as const)) }
  }, [shapes, placed])

  /** The box a shape occupies: its own, or its path's bounds for an arrow. */
  const boundsOf = useCallback(
    (id: string): Box | null => {
      const s = live.byId.get(id)
      if (!s) return null
      if (s.type !== 'arrow') return s
      const path = live.arrowById.get(id)
      return path ? arrowBox(path) : null
    },
    [live]
  )

  const center0 = (): Point => {
    const v = viewRef.current
    const { w, h } = sizeRef.current
    return screenToWorld(v, { x: w / 2, y: h / 2 })
  }

  // ---- size, first fit, controller handle -----------------------------------

  const fitted = useRef(false)
  useLayoutEffect(() => {
    const el = viewport.current
    if (!el) return
    const measure = () => {
      rectCache.current = null
      const w = el.clientWidth
      const h = el.clientHeight
      setSize(prev => (prev.w === w && prev.h === h ? prev : { w, h }))
      if (!fitted.current && w > 0 && h > 0) {
        fitted.current = true
        const boxes = [...store.getShapes().values()].filter(s => s.type !== 'arrow')
        setView(boxes.length ? fitBoxes(boxes, w, h, 96, 1) : { x: w / 2, y: h / 2, z: 1 })
      }
    }
    measure()
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    el.focus({ preventScroll: true })
    return () => ro.disconnect()
  }, [store])

  useEffect(() => {
    const drop = () => {
      rectCache.current = null
    }
    window.addEventListener('resize', drop)
    window.addEventListener('scroll', drop, true)
    return () => {
      window.removeEventListener('resize', drop)
      window.removeEventListener('scroll', drop, true)
    }
  }, [])

  // While the view moves the layer is promoted (will-change), so a pan or zoom
  // composites instead of repainting every note; it settles back once the
  // view has rested, so text is drawn crisp at the new zoom.
  const settled = useRef(true)
  useLayoutEffect(() => {
    const el = layer.current
    if (!el) return
    if (settled.current) {
      settled.current = false
      return
    }
    el.style.willChange = 'transform'
    const timer = setTimeout(() => {
      el.style.willChange = ''
    }, SETTLE_MS)
    return () => clearTimeout(timer)
  }, [view])

  const fitAll = useCallback(() => {
    const boxes = [...live.list.filter(s => s.type !== 'arrow'), ...live.arrows.map(a => arrowBox(a.path))]
    const { w, h } = sizeRef.current
    flight.fly(boxes.length ? fitBoxes(boxes, w, h, 96, 1) : { x: w / 2, y: h / 2, z: 1 })
  }, [live, flight])

  const zoomToIds = useCallback(
    (ids: readonly string[]) => {
      // Shapes written a moment ago (an import, an agent's ops) may not be rendered yet: read the doc.
      const boxes = ids
        .map(id => {
          const b = boundsOf(id)
          if (b) return b
          const s = store.live(id)
          return s && s.type !== 'arrow' ? s : null
        })
        .filter((b): b is Box => !!b)
      const u = unionBox(boxes)
      if (!u) return false
      const { w, h } = sizeRef.current
      const target = ids.length === 1 ? revealView(u, viewRef.current, w, h, { padding: 96 }) : fitBoxes([u], w, h, 96, 1.5)
      flight.fly(target)
      return true
    },
    [boundsOf, flight, store]
  )

  const zoomRef = useRef(zoomToIds)
  useEffect(() => {
    zoomRef.current = zoomToIds
  })
  useEffect(() => {
    controller.attachBoard({ zoomTo: ids => zoomRef.current(ids) })
    return () => controller.attachBoard(null)
  }, [])

  // ---- undo state -------------------------------------------------------------

  useEffect(() => {
    const u = store.undo
    const sync = () => setHistory({ undo: u.canUndo(), redo: u.canRedo() })
    u.on('stack-item-added', sync)
    u.on('stack-item-popped', sync)
    u.on('stack-cleared', sync)
    sync()
    return () => {
      u.off('stack-item-added', sync)
      u.off('stack-item-popped', sync)
      u.off('stack-cleared', sync)
    }
  }, [store])

  const undo = useCallback(() => {
    setEditing(null)
    store.undo.undo()
    controller.setSelection(controller.getSelection())
  }, [store])
  const redo = useCallback(() => {
    setEditing(null)
    store.undo.redo()
    controller.setSelection(controller.getSelection())
  }, [store])

  // ---- creating things --------------------------------------------------------

  const takenBoxes = useCallback(
    (except?: string) => [...store.getShapes().values()].filter(s => s.type !== 'arrow' && s.id !== except).map(occupied),
    [store]
  )

  const createAt = useCallback(
    (input: ShapeInput, at: Point, { centered = true, free = false } = {}): string => {
      const w = input.w ?? SHAPE_SIZE[input.type].w
      const h = input.h ?? SHAPE_SIZE[input.type].h
      let pos = centered ? { x: at.x - w / 2, y: at.y - h / 2 } : at
      if (free) pos = findFreeSpot(takenBoxes(), { w, h }, { x: pos.x + w / 2, y: pos.y + h / 2 }, { gap: 20, step: 24 })
      store.undo.stopCapturing()
      const id = store.create({ by: me.name, ...input, x: pos.x, y: pos.y, w, h }, LOCAL)
      store.undo.stopCapturing()
      return id
    },
    [store, me.name, takenBoxes]
  )

  const startEdit = useCallback(
    (id: string) => {
      if (readOnly) return
      const s = store.get(id)
      if (!s) return
      const field: EditField =
        s.type === 'frame'
          ? 'title'
          : s.type === 'arrow'
            ? 'label'
            : isChecklist(s)
              ? checklistEditField(null)
              : isTimeline(s)
                ? 'part:tl-title'
                : 'text'
      if (s.type === 'image' || s.type === 'link') return
      select([id])
      setEditing({ id, field })
    },
    [store, readOnly, select]
  )

  const openUrl = useCallback((url: string) => {
    postToHost({ type: 'openUrl', url })
    if (!hasNativeHost()) window.open(url, '_blank', 'noopener,noreferrer')
  }, [])

  const placeImage = useCallback(
    async (file: Blob, into: string | null, at: Point, free = false) => {
      const slow = setTimeout(() => toast('Adding the image…'), 400)
      try {
        const img = await imageFromFile(file)
        store.undo.stopCapturing()
        if (into && store.get(into)?.type === 'frame') {
          store.update(into, { image: img }, LOCAL)
          select([into])
        } else {
          const { w, h } = imageSizeFor(img.naturalW, img.naturalH)
          const id = createAt({ type: 'image', src: img.src, naturalW: img.naturalW, naturalH: img.naturalH, w, h }, at, { free })
          select([id])
        }
      } catch (error) {
        toast(error instanceof Error ? error.message : 'The image could not be added.', 'error', 4000)
      } finally {
        clearTimeout(slow)
      }
    },
    [store, createAt, select, toast]
  )

  const addLink = useCallback(
    (url: string, at: Point, title?: string, { live = false, offer = false }: { live?: boolean; offer?: boolean } = {}) => {
      const canLive = !!frameUrl(url)
      const size = live && canLive ? LIVE_SIZE : SHAPE_SIZE.link
      const id = createAt(
        { type: 'link', url, title: title?.trim() || hostOf(url), color: 'white', w: size.w, h: size.h, ...(live && canLive ? { live: true } : {}) },
        at,
        { free: true }
      )
      select([id])
      // A dropped or pasted address lands as a card; the site itself is one click away.
      if (offer && canLive && !live && !readOnly)
        toast('Link added', 'info', 5000, {
          label: 'Show live',
          run: () => {
            setLive(id, true)
            zoomRef.current([id])
          },
        })
      return id
    },
    [createAt, select, toast, readOnly, setLive]
  )

  const addImageUrl = useCallback(
    async (url: string, at: Point) => {
      try {
        const img = await imageFromUrl(url)
        const { w, h } = imageSizeFor(img.naturalW, img.naturalH)
        select([createAt({ type: 'image', src: url, naturalW: img.naturalW, naturalH: img.naturalH, w, h }, at)])
      } catch {
        addLink(url, at)
      }
    },
    [createAt, select, addLink]
  )

  const addText = useCallback(
    (text: string, at: Point) => {
      const trimmed = text.trim()
      if (!trimmed) return
      if (isUrlText(trimmed)) {
        if (looksLikeImageUrl(trimmed)) void addImageUrl(trimmed, at)
        else addLink(trimmed, at, undefined, { offer: true })
        return
      }
      const long = trimmed.length > 160
      const id = createAt({ type: 'sticky', text: trimmed, color: noteColor, ...(long ? { w: 280, h: 280 } : {}) }, at, { free: true })
      select([id])
    },
    [createAt, select, noteColor, addLink, addImageUrl]
  )

  /** ⌘Enter in a sticky: a fresh one beside it (or below), same colour, editing. */
  const sibling = useCallback(
    (id: string, dir: 'right' | 'down') => {
      const s = store.get(id)
      if (!s) return
      const gap = 24
      const want = dir === 'right' ? { x: s.x + s.w + gap, y: s.y } : { x: s.x, y: s.y + s.h + gap }
      const spot = findFreeSpot(takenBoxes(), { w: s.w, h: s.h }, { x: want.x + s.w / 2, y: want.y + s.h / 2 }, { gap: 16, step: 16 })
      const next = createAt({ type: s.type === 'text' ? 'text' : 'sticky', color: s.color, w: s.w, h: s.h, fontSize: s.fontSize }, spot, {
        centered: false,
      })
      select([next])
      setEditing({ id: next, field: 'text' })
      const { w, h } = sizeRef.current
      const box = { x: spot.x, y: spot.y, w: s.w, h: s.h }
      const v = viewRef.current
      const vis = visibleWorld(v, w, h)
      if (!containsBox(vis, box)) flight.fly(revealView(box, v, w, h, { padding: 120 }))
    },
    [store, takenBoxes, createAt, select, flight]
  )

  const endEdit = useCallback(
    (id: string) => {
      setEditing(e => (e?.id === id ? null : e))
      // An empty text shape left behind is noise: drop it.
      const s = store.get(id)
      if (s?.type === 'text' && !s.text.trim()) {
        store.remove([id], LOCAL)
        controller.setSelection([])
      }
      viewport.current?.focus({ preventScroll: true })
    },
    [store]
  )

  const autoHeight = useCallback(
    (id: string, h: number) => {
      const s = store.get(id)
      if (!s || s.type !== 'text') return
      const next = Math.max(MIN_SIZE.text.h, Math.ceil(h))
      if (Math.abs(next - s.h) > 1) store.update(id, { h: next }, LOCAL, false)
    },
    [store]
  )

  const growSticky = useCallback(
    (id: string, contentPx: number, { open = false }: { open?: boolean } = {}) => {
      const s = store.get(id)
      if (!s || s.type !== 'sticky' || readOnly) return false
      const { h, fits } = growFor(s.h, contentPx)
      if (h !== null) {
        // Typing grows the note in the same undo step as the typing; a click is a step of its own.
        if (open) store.undo.stopCapturing()
        store.update(id, { h }, LOCAL, open)
        if (open) store.undo.stopCapturing()
      }
      if (open && !fits) startEdit(id)
      return fits
    },
    [store, readOnly, startEdit]
  )

  const editPart = useCallback(
    (id: string, part: string | null) => {
      if (part === null) endEdit(id)
      else if (!readOnly) setEditing({ id, field: `part:${part}` })
    },
    [endEdit, readOnly]
  )

  const actions = useMemo<BoardActions>(
    () => ({ store, me, readOnly, openUrl, endEdit, sibling, autoHeight, growSticky, editPart }),
    [store, me, readOnly, openUrl, endEdit, sibling, autoHeight, growSticky, editPart]
  )

  // ---- acting on the selection ------------------------------------------------

  const selected = useMemo(() => selectionList.map(id => live.byId.get(id)).filter((s): s is Shape => !!s), [selectionList, live])

  const removeSelected = useCallback(() => {
    if (readOnly || selectionList.length === 0) return
    store.undo.stopCapturing()
    store.remove(selectionList, LOCAL)
    store.undo.stopCapturing()
    setEditing(null)
    select([])
  }, [store, selectionList, select, readOnly])

  const recolor = useCallback(
    (color: ShapeColor) => {
      store.undo.stopCapturing()
      store.transact(() => {
        for (const s of selected) if (s.type !== 'image') store.update(s.id, { color })
      })
      if (selected.some(s => s.type === 'sticky' && !isChecklist(s) && !isTimeline(s)) && typeof color === 'string' && !color.startsWith('#'))
        setNoteColor(color as NamedColor)
    },
    [store, selected]
  )

  const restack = useCallback(
    (front: boolean) => {
      const ordered = [...selected].sort(sortZ)
      store.transact(() => {
        const base = front ? store.maxZ() + 1 : store.minZ() - ordered.length
        ordered.forEach((s, i) => store.update(s.id, { z: base + i }, LOCAL, false))
      })
    },
    [store, selected]
  )

  /** Everything that travels with the selection: frames carry what sits inside them. */
  const moving = useCallback(
    (ids: Iterable<string>): Map<string, Shape> => {
      const out = new Map<string, Shape>()
      const all = live.list
      for (const id of ids) {
        const s = live.byId.get(id)
        if (!s) continue
        out.set(id, s)
        if (s.type === 'frame') for (const c of frameChildren(all, s)) out.set(c.id, c)
      }
      return out
    },
    [live]
  )

  const shifted = (s: Shape, dx: number, dy: number): Partial<Shape> => {
    if (s.type !== 'arrow') return { x: Math.round(s.x + dx), y: Math.round(s.y + dy) }
    const move = (e: Endpoint | undefined) => (e && !isRefEndpoint(e) ? { x: Math.round(e.x + dx), y: Math.round(e.y + dy) } : e)
    return { from: move(s.from), to: move(s.to) }
  }

  const nudge = useCallback(
    (dx: number, dy: number) => {
      const set = moving(selectionList)
      store.moveMany([...set.values()].map(s => [s.id, shifted(s, dx, dy)] as [string, Point]), LOCAL)
    },
    [moving, selectionList, store]
  )

  const clipFor = useCallback(
    (ids: readonly string[]): ClipShape[] => {
      const set = new Set(moving(ids).keys())
      for (const id of store.arrowsTouching(set)) {
        const a = store.get(id)
        if (a && isRefEndpoint(a.from) && isRefEndpoint(a.to) && set.has(a.from.ref) && set.has(a.to.ref)) set.add(id)
      }
      return [...set].map(id => store.toJSON(id)).filter((s): s is ClipShape => !!s)
    },
    [moving, store]
  )

  /** Paste shapes with fresh ids, arrows rewired to the copies, centred on `at` (or offset). */
  const pasteShapes = useCallback(
    (items: ClipShape[], at: Point | null) => {
      if (readOnly || items.length === 0) return
      const boxes = items.filter(s => s.type !== 'arrow' && typeof s.x === 'number')
      const u = unionBox(boxes.map(s => ({ x: s.x ?? 0, y: s.y ?? 0, w: s.w ?? 0, h: s.h ?? 0 })))
      pasteCount.current++
      const off = at && u ? { x: at.x - (u.x + u.w / 2), y: at.y - (u.y + u.h / 2) } : { x: 24 * pasteCount.current, y: 24 * pasteCount.current }
      const ids = new Map(items.map(s => [s.id, newId()] as const))
      const remap = (e: unknown): Endpoint | undefined => {
        if (!e || typeof e !== 'object') return undefined
        const end = e as Endpoint
        if (isRefEndpoint(end)) {
          const to = ids.get(end.ref)
          if (to) return { ...end, ref: to }
          return store.get(end.ref) ? end : undefined
        }
        return { x: end.x + off.x, y: end.y + off.y }
      }
      const z = store.maxZ() + 1
      store.undo.stopCapturing()
      store.transact(() => {
        items.forEach((s, i) => {
          const { id: oldId, createdAt: _c, updatedAt: _u, ...rest } = s as ClipShape & { createdAt?: number; updatedAt?: number }
          void _c
          void _u
          const input: ShapeInput = { ...rest, id: ids.get(oldId), z: z + i, by: me.name }
          if (s.type === 'arrow') {
            const from = remap(s.from)
            const to = remap(s.to)
            if (!from || !to) return
            input.from = from
            input.to = to
          } else {
            input.x = (s.x ?? 0) + off.x
            input.y = (s.y ?? 0) + off.y
          }
          store.create(input, LOCAL)
        })
      })
      store.undo.stopCapturing()
      select([...ids.values()].filter(id => store.shapes.has(id)))
    },
    [readOnly, store, me.name, select]
  )

  const duplicate = useCallback(() => {
    pasteCount.current = 0
    pasteShapes(clipFor(selectionList), null)
  }, [clipFor, pasteShapes, selectionList])

  // ---- hit testing --------------------------------------------------------------

  /** The topmost box under a world point (not arrows); frames only when nothing else is there. */
  const shapeAt = useCallback(
    (p: Point, except?: string): Shape | null => {
      const pad = 6 / viewRef.current.z
      const hit = (s: Shape) => containsPoint({ x: s.x - pad, y: s.y - pad, w: s.w + pad * 2, h: s.h + pad * 2 }, p)
      for (let i = live.list.length - 1; i >= 0; i--) {
        const s = live.list[i]!
        if (s.type === 'arrow' || s.type === 'frame' || s.id === except) continue
        if (hit(s)) return s
      }
      let best: Shape | null = null
      for (const s of live.list)
        if (s.type === 'frame' && s.id !== except && hit(s) && (!best || s.w * s.h < best.w * best.h)) best = s
      return best
    },
    [live]
  )

  /** Where an arrow end lands at `p`: a shape's side (near its midpoint), the shape, or the point. */
  const endAt = useCallback(
    (p: Point, except?: string): { end: Endpoint; hover: Draft['hover'] } => {
      const s = shapeAt(p, except)
      if (!s) return { end: { x: Math.round(p.x), y: Math.round(p.y) }, hover: null }
      const near = nearestSide(s, p)
      const snap = near.distance < Math.max(18, 22 / viewRef.current.z)
      return snap ? { end: { ref: s.id, side: near.side }, hover: { id: s.id, side: near.side } } : { end: { ref: s.id }, hover: { id: s.id } }
    },
    [shapeAt]
  )

  const draftPath = useCallback(
    (d: Draft): ArrowPath | null => arrowPath({ from: d.from, to: d.to }, live.boxOf),
    [live]
  )

  const localPoint = (e: { clientX: number; clientY: number }): Point => {
    const rect = viewportRect()
    return { x: e.clientX - rect.left, y: e.clientY - rect.top }
  }

  // ---- pointer --------------------------------------------------------------------

  const doubleClick = (hitId: string | null, part: string | null, c: Point) => {
    keepFocus.current = true
    if (!hitId) {
      if (readOnly || tool !== 'select') return
      const id = createAt({ type: 'sticky', color: noteColor }, c)
      select([id])
      setEditing({ id, field: 'text' })
      return
    }
    const s = live.byId.get(hitId)
    if (!s) return
    if (s.type === 'link') {
      if (s.live && frameUrl(s.url)) activate(s.id)
      else if (s.url) openUrl(s.url)
      return
    }
    if (s.type === 'frame' && part !== 'frame-title' && s.image) return
    if (isChecklist(s)) {
      if (readOnly) return
      select([hitId])
      setEditing({ id: hitId, field: checklistEditField(part) })
      return
    }
    if (isTimeline(s)) {
      // The card's own parts take their clicks; what reaches the board here is the header or empty room.
      if (readOnly) return
      select([hitId])
      setEditing({ id: hitId, field: 'part:tl-title' })
      return
    }
    startEdit(hitId)
  }

  const createArrow = (from: Endpoint, to: Endpoint) => {
    if (isRefEndpoint(from) && isRefEndpoint(to) && from.ref === to.ref) return
    const id = createAt({ type: 'arrow', from, to, color: 'gray' }, { x: 0, y: 0 }, { centered: false })
    select([id])
    setTool('select')
  }

  const onPointerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (e.button === 2) return
    const target = e.target as Element
    if (!isTextField(target)) viewport.current?.focus({ preventScroll: true })
    const p = localPoint(e)
    const c = screenToWorld(view, p)
    flight.cancel()
    setLinkAt(null)
    setMenu(null)
    if (commentFocus) setCommentFocus(null)
    // A press anywhere but the frame in use (its bar) hands the keyboard back to the board.
    if (activeId && target.closest('[data-id]')?.getAttribute('data-id') !== activeId) setActiveFrame(null)
    if (e.button === 1 || tool === 'hand' || space) {
      e.preventDefault()
      e.currentTarget.setPointerCapture(e.pointerId)
      gesture.current = { kind: 'pan', start: p, view }
      setPanning(true)
      return
    }
    if (e.button !== 0) return
    if (tool === 'laser') {
      e.currentTarget.setPointerCapture(e.pointerId)
      if (laserLinger.current) clearTimeout(laserLinger.current)
      laserLinger.current = null
      trails.begin(c, me.color)
      gesture.current = { kind: 'laser' }
      publishLaser(true)
      return
    }
    const hitId = target.closest('[data-id]')?.getAttribute('data-id') ?? null
    const part = target.closest('[data-part]')?.getAttribute('data-part') ?? null
    if (editing && hitId === editing.id) return

    // Our own double-click: pointer capture would hide the target from dblclick.
    const now = performance.now()
    const prev = lastDown.current
    const twice = now - prev.at < DOUBLE_MS && prev.id === (hitId ?? '') && Math.hypot(prev.p.x - p.x, prev.p.y - p.y) < 8
    lastDown.current = twice ? { id: '', at: 0, p } : { id: hitId ?? '', at: now, p }
    if (twice && tool === 'select') {
      gesture.current = null
      doubleClick(hitId, part, c)
      return
    }

    e.currentTarget.setPointerCapture(e.pointerId)
    gesture.current = null

    if (!readOnly && pendingFrom) {
      const { end } = endAt(c, isRefEndpoint(pendingFrom) ? pendingFrom.ref : undefined)
      createArrow(pendingFrom, end)
      setPendingFrom(null)
      setDraft(null)
      return
    }

    if (!readOnly && (tool === 'sticky' || tool === 'text')) {
      keepFocus.current = true
      const id =
        tool === 'sticky'
          ? createAt({ type: 'sticky', color: noteColor }, c)
          : createAt({ type: 'text', color: 'gray' }, { x: c.x, y: c.y - 16 }, { centered: false })
      setTool('select')
      select([id])
      setEditing({ id, field: 'text' })
      return
    }
    if (!readOnly && tool === 'frame') {
      gesture.current = { kind: 'frame', start: c, startScreen: p }
      return
    }
    if (!readOnly && tool === 'checklist') {
      keepFocus.current = true
      // A note in the checklist view: older Coppers show (and tick) the same text as a note.
      const id = createAt({ type: 'sticky', view: 'checklist', columns: ['Yes', 'No'], text: '', color: 'green', ...SHAPE_SIZE.checklist }, c)
      setTool('select')
      select([id])
      setEditing({ id, field: checklistEditField(null) })
      return
    }
    if (!readOnly && tool === 'timeline') {
      keepFocus.current = true
      // A note in the timeline view: older Coppers show the same text as a readable note.
      const id = createAt({ type: 'sticky', view: 'timeline', text: newTimelineText(), color: 'white', ...TIMELINE_SIZE }, c)
      setTool('select')
      select([id])
      setEditing({ id, field: 'part:tl-title' })
      return
    }
    if (!readOnly && tool === 'arrow') {
      const { end, hover } = endAt(c)
      gesture.current = { kind: 'arrow', from: end, startScreen: p, moved: false }
      setDraft({ from: end, to: { x: c.x, y: c.y }, hover })
      return
    }
    if (!readOnly && tool === 'link') {
      setLinkAt(c)
      setTool('select')
      return
    }
    if (!readOnly && tool === 'image') {
      imageAt.current = { frame: hitId && live.byId.get(hitId)?.type === 'frame' ? hitId : null, at: c }
      fileInput.current?.click()
      setTool('select')
      return
    }

    // Select tool.
    if (hitId && live.byId.has(hitId)) {
      const s = live.byId.get(hitId)!
      if (s.type === 'frame' && part === 'frame-body' && !s.image && !selection.has(hitId)) {
        if (!e.shiftKey) select([])
        gesture.current = { kind: 'marquee', start: c, startScreen: p, base: e.shiftKey ? selectionList.slice() : [], additive: e.shiftKey, frameClick: hitId, moved: false }
        return
      }
      let ids = selectionList.slice()
      if (e.shiftKey) {
        if (selection.has(hitId)) {
          select(ids.filter(id => id !== hitId))
          return
        }
        ids = [...ids, hitId]
      } else if (!selection.has(hitId)) ids = [hitId]
      const shield = part === 'web-shield' && !e.shiftKey && selectionList.length === 1 && selectionList[0] === hitId
      select(ids)
      if (readOnly) {
        if (shield) activate(hitId)
        return
      }
      store.undo.stopCapturing()
      gesture.current = { kind: 'move', start: c, startScreen: p, origins: moving(ids), moved: false, hit: hitId, last: 0, shield }
      return
    }
    if (!e.shiftKey) select([])
    gesture.current = { kind: 'marquee', start: c, startScreen: p, base: e.shiftKey ? selectionList.slice() : [], additive: e.shiftKey, moved: false }
  }

  const startResize = (s: Shape, handle: Handle, e: ReactPointerEvent<HTMLElement>) => {
    if (e.button !== 0 || readOnly || !isResizable(s.type)) return
    e.stopPropagation()
    viewport.current?.setPointerCapture(e.pointerId)
    store.undo.stopCapturing()
    gesture.current = {
      kind: 'resize',
      id: s.id,
      handle,
      type: s.type,
      live: s.live,
      view: s.view,
      start: screenToWorld(view, localPoint(e)),
      box: { x: s.x, y: s.y, w: s.w, h: s.h },
      last: 0,
    }
  }

  const startEndDrag = (s: Shape, end: 'from' | 'to', e: ReactPointerEvent<HTMLElement>) => {
    if (e.button !== 0 || readOnly) return
    e.stopPropagation()
    viewport.current?.setPointerCapture(e.pointerId)
    store.undo.stopCapturing()
    gesture.current = { kind: 'arrow-end', id: s.id, end, other: end === 'from' ? s.to : s.from }
    setReEnding(s.id)
    const p = screenToWorld(view, localPoint(e))
    setDraft({ from: (end === 'from' ? s.to : s.from) ?? p, to: p, hover: null })
  }

  const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    const p = localPoint(e)
    pointer.current = p
    const c = screenToWorld(view, p)
    const now = performance.now()
    if (now - lastCursor.current > 33) {
      lastCursor.current = now
      awareness.setLocalStateField('cursor', { x: Math.round(c.x), y: Math.round(c.y) })
    }
    const g = gesture.current
    if (!g) {
      if (pendingFrom) {
        const { end, hover: h } = endAt(c, isRefEndpoint(pendingFrom) ? pendingFrom.ref : undefined)
        setDraft({ from: pendingFrom, to: end, hover: h })
      } else if (tool === 'arrow' && !readOnly) {
        const s = shapeAt(c)
        if (s) {
          const near = nearestSide(s, c)
          const side = near.distance < Math.max(18, 22 / view.z) ? near.side : undefined
          setArrowHover(prev => (prev?.id === s.id && prev.side === side ? prev : { id: s.id, side }))
        } else setArrowHover(null)
      }
      const id = (e.target as Element).closest?.('[data-id]')?.getAttribute('data-id') ?? null
      // Compared here: even an updater that keeps the value costs the board a render.
      if (hoverRef.current !== id) {
        hoverRef.current = id
        setHover(id)
      }
      return
    }
    switch (g.kind) {
      case 'laser': {
        // A fast circle brings several points per frame: keep them all, so the trail stays round.
        const batch = e.nativeEvent.getCoalescedEvents?.() ?? []
        if (batch.length > 1) for (const ev of batch) trails.move(screenToWorld(view, localPoint(ev)))
        else trails.move(c)
        publishLaser()
        return
      }
      case 'pan':
        setView({ ...g.view, x: g.view.x + p.x - g.start.x, y: g.view.y + p.y - g.start.y })
        return
      case 'move': {
        if (!g.moved && Math.hypot(p.x - g.startScreen.x, p.y - g.startScreen.y) < 3) return
        g.moved = true
        const dx = c.x - g.start.x
        const dy = c.y - g.start.y
        const next = new Map<string, Partial<Shape>>()
        for (const s of g.origins.values()) next.set(s.id, shifted(s, dx, dy))
        g.next = next
        setDrag(next)
        if (now - g.last > SEND_MS) {
          g.last = now
          store.moveMany([...next.entries()] as [string, Record<string, unknown>][], LOCAL)
        }
        return
      }
      case 'resize': {
        const min = minSizeOf({ type: g.type as keyof typeof MIN_SIZE, live: g.live, view: g.view })
        const delta = { x: c.x - g.start.x, y: c.y - g.start.y }
        const keep = g.type === 'image' ? !e.shiftKey : e.shiftKey
        const box = keep ? resizeBoxKeepAspect(g.box, g.handle, delta, min) : resizeBox(g.box, g.handle, delta, min)
        if (g.view === 'timeline') {
          // A timeline is never shorter than its content needs at the new width.
          const need = Math.ceil(neededHeight(store.get(g.id)?.text ?? '', box.w))
          if (box.h < need) {
            if (g.handle.includes('n')) box.y = g.box.y + g.box.h - need
            box.h = need
          }
        }
        g.at = box
        setDrag(new Map([[g.id, box]]))
        if (now - g.last > SEND_MS) {
          g.last = now
          store.update(g.id, box, LOCAL)
        }
        return
      }
      case 'marquee': {
        if (!g.moved && Math.hypot(p.x - g.startScreen.x, p.y - g.startScreen.y) < 3) return
        g.moved = true
        const box = boxFromPoints(g.start, c)
        setMarquee(box)
        const hits: string[] = []
        for (const s of live.list) {
          if (s.type === 'arrow') {
            const path = live.arrowById.get(s.id)
            if (path && containsBox(box, arrowBox(path))) hits.push(s.id)
          } else if (s.type === 'frame' ? containsBox(box, s) : boxesOverlap(box, s)) hits.push(s.id)
        }
        select(g.additive ? [...new Set([...g.base, ...hits])] : hits)
        return
      }
      case 'frame': {
        g.box = boxFromPoints(g.start, c)
        setFrameDraft(g.box)
        return
      }
      case 'arrow': {
        if (!g.moved && Math.hypot(p.x - g.startScreen.x, p.y - g.startScreen.y) < 4) return
        g.moved = true
        const { end, hover: h } = endAt(c, isRefEndpoint(g.from) ? g.from.ref : undefined)
        setDraft({ from: g.from, to: end, hover: h })
        return
      }
      case 'arrow-end': {
        const except = isRefEndpoint(g.other) ? g.other.ref : undefined
        const { end, hover: h } = endAt(c, except)
        setDraft({ from: g.other ?? end, to: end, hover: h })
        return
      }
    }
  }

  const onPointerUp = (e: ReactPointerEvent<HTMLDivElement>) => {
    const g = gesture.current
    gesture.current = null
    if (!g) return
    const c = screenToWorld(view, localPoint(e))
    switch (g.kind) {
      case 'laser':
        trails.end()
        publishLaser(true)
        // Peers keep it through its hold and fade; then it leaves awareness.
        laserLinger.current = setTimeout(() => {
          laserLinger.current = null
          awareness.setLocalStateField('laser', null)
        }, LASER_LINGER_MS)
        return
      case 'pan':
        setPanning(false)
        return
      case 'move':
        if (g.moved && g.next) store.moveMany([...g.next.entries()] as [string, Record<string, unknown>][], LOCAL)
        else if (!g.moved && !e.shiftKey && selectionList.length > 1 && selection.has(g.hit)) select([g.hit])
        else if (!g.moved && g.shield) activate(g.hit)
        store.undo.stopCapturing()
        setDrag(null)
        return
      case 'resize':
        if (g.at) store.update(g.id, g.at, LOCAL)
        store.undo.stopCapturing()
        setDrag(null)
        return
      case 'marquee':
        setMarquee(null)
        if (!g.moved && g.frameClick) select([g.frameClick])
        return
      case 'frame': {
        setFrameDraft(null)
        const small = !g.box || g.box.w * view.z < 12 || g.box.h * view.z < 12
        const box = small ? { ...SHAPE_SIZE.frame, x: g.start.x - SHAPE_SIZE.frame.w / 2, y: g.start.y - SHAPE_SIZE.frame.h / 2 } : g.box!
        const id = createAt(
          { type: 'frame', color: 'gray', w: Math.max(box.w, MIN_SIZE.frame.w), h: Math.max(box.h, MIN_SIZE.frame.h) },
          { x: box.x, y: box.y },
          { centered: false }
        )
        setTool('select')
        select([id])
        setEditing({ id, field: 'title' })
        return
      }
      case 'arrow': {
        if (!g.moved) {
          // A click on a shape: the line follows the pointer until the next click.
          if (isRefEndpoint(g.from)) {
            setPendingFrom(g.from)
            return
          }
          setDraft(null)
          return
        }
        const { end } = endAt(c, isRefEndpoint(g.from) ? g.from.ref : undefined)
        setDraft(null)
        createArrow(g.from, end)
        return
      }
      case 'arrow-end': {
        const except = isRefEndpoint(g.other) ? g.other.ref : undefined
        const { end } = endAt(c, except)
        setDraft(null)
        setReEnding(null)
        store.update(g.id, { [g.end]: end } as Partial<Shape>, LOCAL)
        store.undo.stopCapturing()
        return
      }
    }
  }

  const onPointerLeave = () => {
    pointer.current = null
    hoverRef.current = null
    setHover(null)
    awareness.setLocalStateField('cursor', null)
  }

  // ---- zoom ---------------------------------------------------------------------

  const zoomBy = useCallback(
    (factor: number) => {
      const { w, h } = sizeRef.current
      flight.cancel()
      setView(v => zoomAt(v, factor, { x: w / 2, y: h / 2 }))
    },
    [flight]
  )
  const zoomReset = useCallback(() => {
    const { w, h } = sizeRef.current
    flight.fly(zoomTo(viewRef.current, 1, { x: w / 2, y: h / 2 }))
  }, [flight])

  // Wheel and pinch must be non-passive to keep the page from scrolling or zooming.
  useEffect(() => {
    const el = viewport.current
    if (!el) return
    // A trackpad sends up to 120 wheel events a second: they move the view
    // once per frame, however many arrive.
    let pending: ((v: View) => View)[] = []
    let frame = 0
    const move = (fn: (v: View) => View) => {
      pending.push(fn)
      if (frame) return
      frame = requestAnimationFrame(() => {
        frame = 0
        const steps = pending
        pending = []
        setView(v => steps.reduce((acc, step) => step(acc), v))
      })
    }
    const onWheel = (e: WheelEvent) => {
      const t = e.target as HTMLElement | null
      if (t?.closest('textarea') && t.scrollHeight > t.clientHeight) return
      e.preventDefault()
      flight.cancel()
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1
      const dx = e.deltaX * unit
      const dy = e.deltaY * unit
      const rect = viewportRect()
      const p = { x: e.clientX - rect.left, y: e.clientY - rect.top }
      if (e.ctrlKey || e.metaKey) {
        const step = Math.max(-60, Math.min(60, dy))
        move(v => zoomAt(v, Math.exp(-step * 0.009), p))
      } else move(v => ({ ...v, x: v.x - dx, y: v.y - dy }))
    }
    let gestureZoom = 1
    const onGestureStart = (e: Event) => {
      e.preventDefault()
      gestureZoom = viewRef.current.z
    }
    const onGestureChange = (e: Event) => {
      e.preventDefault()
      const g = e as Event & { scale: number; clientX: number; clientY: number }
      const rect = viewportRect()
      const p = { x: g.clientX - rect.left, y: g.clientY - rect.top }
      const z = gestureZoom * g.scale
      move(v => zoomTo(v, z, p))
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    el.addEventListener('gesturestart', onGestureStart)
    el.addEventListener('gesturechange', onGestureChange)
    el.addEventListener('gestureend', onGestureStart)
    return () => {
      cancelAnimationFrame(frame)
      el.removeEventListener('wheel', onWheel)
      el.removeEventListener('gesturestart', onGestureStart)
      el.removeEventListener('gesturechange', onGestureChange)
      el.removeEventListener('gestureend', onGestureStart)
    }
  }, [flight])

  const openImagePicker = (at: Point | null) => {
    const frame = selected.length === 1 && selected[0]!.type === 'frame' ? selected[0]!.id : null
    imageAt.current = { frame, at: at ?? center0(), free: !at }
    fileInput.current?.click()
  }

  // ---- keyboard -------------------------------------------------------------------

  const keyHandler = useRef<(e: KeyboardEvent) => void>(() => {})
  useEffect(() => {
    keyHandler.current = (e: KeyboardEvent) => {
      if (e.defaultPrevented || isTextField(e.target) || help) return
      if ((e.target as Element | null)?.closest?.('[role="dialog"]')) return
      const key = e.key.toLowerCase()
      const mod = e.metaKey || e.ctrlKey
      if (mod && !e.altKey && (key === 'z' || key === 'y')) {
        e.preventDefault()
        if (readOnly) return
        if (key === 'y' || e.shiftKey) redo()
        else undo()
        return
      }
      if (mod && key === 'a') {
        e.preventDefault()
        select(live.list.map(s => s.id))
        return
      }
      if (mod && key === 'd') {
        e.preventDefault()
        if (!readOnly) duplicate()
        return
      }
      if (mod && (key === ']' || key === '[')) {
        e.preventDefault()
        if (!readOnly) restack(key === ']')
        return
      }
      if (mod && (key === '=' || key === '+' || key === '-')) {
        e.preventDefault()
        zoomBy(key === '-' ? 1 / 1.25 : 1.25)
        return
      }
      if (mod && key === '0') {
        e.preventDefault()
        zoomReset()
        return
      }
      if (mod || e.altKey) return
      if (e.key === ' ') {
        e.preventDefault()
        setSpace(true)
        return
      }
      if (e.key === 'Escape') {
        if (commentFocus) setCommentFocus(null)
        else if (menu) setMenu(null)
        else if (activeId) deactivate()
        else if (pendingFrom || draft) {
          setPendingFrom(null)
          setDraft(null)
        } else if (linkAt) setLinkAt(null)
        else if (tool !== 'select') setTool('select')
        else select([])
        return
      }
      if (e.key === 'Delete' || e.key === 'Backspace') {
        e.preventDefault()
        removeSelected()
        return
      }
      if (e.key === 'Enter') {
        const only = selected.length === 1 ? selected[0]! : null
        if (!only) return
        e.preventDefault()
        if (only.type === 'link') {
          if (only.live && frameUrl(only.url)) activate(only.id)
          else if (only.url) openUrl(only.url)
        } else startEdit(only.id)
        return
      }
      if (e.key.startsWith('Arrow') && selectionList.length && !readOnly) {
        e.preventDefault()
        const d = e.shiftKey ? 10 : 1
        nudge(e.key === 'ArrowLeft' ? -d : e.key === 'ArrowRight' ? d : 0, e.key === 'ArrowUp' ? -d : e.key === 'ArrowDown' ? d : 0)
        return
      }
      if (e.shiftKey && (e.code === 'Digit1' || e.key === '!')) {
        e.preventDefault()
        fitAll()
        return
      }
      if (e.shiftKey && (e.code === 'Digit2' || e.key === '@')) {
        e.preventDefault()
        if (selectionList.length) zoomToIds(selectionList)
        return
      }
      if (e.shiftKey && (e.code === 'Digit0' || e.key === ')')) {
        e.preventDefault()
        zoomReset()
        return
      }
      if (e.key === '?') {
        e.preventDefault()
        setHelp(true)
        return
      }
      if (e.key === '+' || e.key === '=') {
        zoomBy(1.25)
        return
      }
      if (e.key === '-' || e.key === '_') {
        zoomBy(1 / 1.25)
        return
      }
      const next = TOOL_KEYS[key]
      if (next && !e.shiftKey) {
        if (readOnly && next !== 'select' && next !== 'hand' && next !== 'laser') return
        e.preventDefault()
        if (next === 'image') openImagePicker(null)
        else if (next === 'link') setLinkAt(center0())
        else setTool(next)
      }
    }
  })
  useEffect(() => {
    const down = (e: KeyboardEvent) => keyHandler.current(e)
    const up = (e: KeyboardEvent) => {
      if (e.key === ' ') setSpace(false)
    }
    const blur = () => {
      setSpace(false)
      awareness.setLocalStateField('cursor', null)
    }
    window.addEventListener('keydown', down)
    window.addEventListener('keyup', up)
    window.addEventListener('blur', blur)
    return () => {
      window.removeEventListener('keydown', down)
      window.removeEventListener('keyup', up)
      window.removeEventListener('blur', blur)
    }
  }, [awareness])

  // ---- clipboard and drops ---------------------------------------------------------

  const clipHandler = useRef<{ copy: (e: ClipboardEvent, cut: boolean) => void; paste: (e: ClipboardEvent) => void }>({
    copy: () => {},
    paste: () => {},
  })
  useEffect(() => {
    const where = (): Point => (pointer.current ? screenToWorld(viewRef.current, pointer.current) : center0())
    clipHandler.current = {
      copy: (e, cut) => {
        if (isTextField(e.target) || isTextField(document.activeElement) || selectionList.length === 0) return
        const items = clipFor(selectionList)
        if (items.length === 0) return
        const text = items
          .map(s =>
            s.type === 'link'
              ? s.url
              : s.type === 'frame'
                ? s.title
                : s.type === 'arrow'
                  ? s.label
                  : s.type === 'checklist'
                    ? copyChecklist(live.byId.get(s.id))
                    : s.text
          )
          .filter((t): t is string => typeof t === 'string' && !!t)
          .join('\n\n')
        clip.current = { text, shapes: items }
        pasteCount.current = 0
        e.preventDefault()
        try {
          e.clipboardData?.setData('text/plain', text || ' ')
          e.clipboardData?.setData(CLIP_TYPE, JSON.stringify({ shapes: items }))
        } catch {
          // custom types refused: the in-page copy still works
        }
        if (cut && !readOnly) removeSelected()
      },
      paste: e => {
        if (readOnly) return
        const data = e.clipboardData
        const titledFrame = (() => {
          const el = e.target instanceof Element ? e.target.closest('[data-kind="frame"]') : null
          return el?.getAttribute('data-id') ?? null
        })()
        if (isTextField(e.target) && !(titledFrame && imageFile(data))) return
        const at = where()
        const file = imageFile(data)
        if (file) {
          e.preventDefault()
          const frame = titledFrame ?? (selected.length === 1 && selected[0]!.type === 'frame' ? selected[0]!.id : null)
          void placeImage(file, frame, at)
          return
        }
        const raw = (() => {
          try {
            return data?.getData(CLIP_TYPE) ?? ''
          } catch {
            return ''
          }
        })()
        const text = data?.getData('text/plain') ?? ''
        if (raw) {
          try {
            const parsed = JSON.parse(raw) as { shapes?: ClipShape[] }
            if (Array.isArray(parsed.shapes)) {
              e.preventDefault()
              pasteShapes(parsed.shapes, pointer.current ? at : null)
              return
            }
          } catch {
            // not ours after all
          }
        }
        if (clip.current && (text === clip.current.text || (!text && clip.current.text === ' '))) {
          e.preventDefault()
          pasteShapes(clip.current.shapes, pointer.current ? at : null)
          return
        }
        const link = urlFrom(data)
        if (link) {
          e.preventDefault()
          if (looksLikeImageUrl(link.url)) void addImageUrl(link.url, at)
          else addLink(link.url, at, link.title, { offer: true })
          return
        }
        if (text.trim()) {
          e.preventDefault()
          addText(text, at)
        }
      },
    }
  })
  useEffect(() => {
    const copy = (e: ClipboardEvent) => clipHandler.current.copy(e, false)
    const cut = (e: ClipboardEvent) => clipHandler.current.copy(e, true)
    const paste = (e: ClipboardEvent) => clipHandler.current.paste(e)
    // Never let a drop navigate the page away from the board.
    const block = (e: DragEvent) => e.preventDefault()
    document.addEventListener('copy', copy)
    document.addEventListener('cut', cut)
    document.addEventListener('paste', paste)
    window.addEventListener('dragover', block)
    window.addEventListener('drop', block)
    return () => {
      document.removeEventListener('copy', copy)
      document.removeEventListener('cut', cut)
      document.removeEventListener('paste', paste)
      window.removeEventListener('dragover', block)
      window.removeEventListener('drop', block)
    }
  }, [])

  const [dropping, setDropping] = useState(false)
  const onDragOver = (e: ReactDragEvent<HTMLDivElement>) => {
    if (readOnly || isTextField(e.target)) return
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
    if (!dropping) setDropping(true)
  }
  const onDrop = (e: ReactDragEvent<HTMLDivElement>) => {
    setDropping(false)
    if (readOnly || isTextField(e.target)) return
    e.preventDefault()
    const at = screenToWorld(view, localPoint(e))
    const file = imageFile(e.dataTransfer)
    if (file) {
      const frame = [...live.list].reverse().find(s => s.type === 'frame' && containsPoint(s, at))
      void placeImage(file, frame?.id ?? null, at)
      return
    }
    const link = urlFrom(e.dataTransfer)
    if (link) {
      if (looksLikeImageUrl(link.url)) void addImageUrl(link.url, at)
      else addLink(link.url, at, link.title, { offer: true })
      return
    }
    const text = e.dataTransfer.getData('text/plain')
    if (text.trim()) addText(text, at)
  }

  // ---- search ---------------------------------------------------------------------

  const search = useBoardSearch({ shapes, threads, viewport })
  const locate = useCallback(
    (ref: string): { box: Box; seg?: RingPlace['seg'] } | null => {
      const path = live.arrowById.get(ref)
      if (path) return { box: arrowLabelBox(path.seg), seg: path.seg }
      const s = live.byId.get(ref)
      return s && s.type !== 'arrow' ? { box: s } : null
    },
    [live]
  )
  const revealHit = (hit: SearchResult) => {
    if (revealComment(hit.ref)) return
    const at = locate(hit.ref)
    if (!at) return
    const { w, h } = sizeRef.current
    // Centred in what the search box above and the tool bar below leave free.
    flight.fly(revealView(at.box, view, w, h, { top: search.coveredTop(), bottom: TOOLBAR_PX }), () => select([hit.ref]))
  }

  // ---- comments ------------------------------------------------------------------

  /** What the popover and the panel leave free on the right (screen px). */
  const commentRight = size.w - (commentsOpen ? Math.min(PANEL_W, size.w - 24) + 24 : 0)

  /**
   * Bring a shape's pin corner into view, unless it is already showing left of
   * the panel: then the board stays put. Otherwise fly to fit the shape in what
   * the panel and the popover leave free.
   */
  const showForComment = useCallback(
    (id: string) => {
      const b = boundsOf(id) ?? (() => {
        const s = store.live(id)
        return s && s.type !== 'arrow' ? s : null
      })()
      if (!b) return
      const { w, h } = sizeRef.current
      const v = viewRef.current
      const panel = commentsOpen ? Math.min(PANEL_W, w - 24) + 24 : 0
      const popover = w - panel > POP_W * 2 + 120 ? POP_W + 24 : 0
      const room = { w: Math.max(240, w - panel - popover), h }
      const right = (b.x + b.w) * v.z + v.x
      const top = b.y * v.z + v.y
      if (right >= 40 && right <= w - panel - 8 && top >= 56 && top <= h - 160) return
      flight.fly(fitBoxes([b], room.w, room.h, 72, Math.max(v.z, 1)))
    },
    [boundsOf, store, commentsOpen, flight]
  )

  /** A new thread on `id`, composer focused. */
  const startComment = useCallback(
    (id: string) => {
      if (readOnly || !store.live(id)) return
      setMenu(null)
      setEditing(null)
      showForComment(id)
      setCommentFocus({ kind: 'new', anchor: id })
    },
    [readOnly, store, showForComment]
  )

  /** Open a thread (from the panel, a search hit, a pin): its shape flown into view first. */
  const openThread = useCallback(
    (threadId: string, at?: Point) => {
      const t = store.comments.get(threadId)
      if (!t) return
      setMenu(null)
      if (store.live(t.anchor)) {
        showForComment(t.anchor)
        select([t.anchor])
      }
      setCommentFocus({ kind: 'thread', id: threadId, ...(at ? { at } : {}) })
    },
    [store, showForComment, select]
  )

  const closeComment = useCallback(() => {
    setCommentFocus(null)
    viewport.current?.focus({ preventScroll: true })
  }, [])

  const pins = useMemo(
    () =>
      pinPlaces({
        threads,
        boundsOf,
        toScreen: p => ({ x: p.x * view.z + view.x, y: p.y * view.z + view.y }),
        size,
        focus: commentFocus,
      }),
    [threads, boundsOf, view, size, commentFocus]
  )
  const focusAnchor = commentFocus?.kind === 'thread' ? (threads.find(t => t.id === commentFocus.id)?.anchor ?? null) : (commentFocus?.anchor ?? null)
  const focusPin = focusAnchor ? pins.find(p => p.anchor === focusAnchor) : undefined
  const openCount = useMemo(() => threads.filter(t => !t.resolved && isShown(t)).length, [threads])

  // ⌥⌘M comments on the selection — or on the shape being typed in — from anywhere but a comment.
  const commentKey = useRef<(e: KeyboardEvent) => void>(() => {})
  useEffect(() => {
    commentKey.current = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey) || !e.altKey || e.shiftKey || (e.code !== 'KeyM' && e.key.toLowerCase() !== 'm')) return
      const t = e.target as Element | null
      if (t?.closest?.('[data-testid="comment-popover"], [data-testid="comments-panel"], [role="dialog"]') || help) return
      // A field that is not the shape being edited (search, a link's address) keeps its keys.
      if (isTextField(t) && !editing) return
      const id = editing?.id ?? (selected.length === 1 ? selected[0]!.id : null)
      if (!id || readOnly) return
      e.preventDefault()
      e.stopPropagation()
      if (editing) endEdit(editing.id)
      startComment(id)
    }
  })
  useEffect(() => {
    const down = (e: KeyboardEvent) => commentKey.current(e)
    window.addEventListener('keydown', down, true)
    return () => window.removeEventListener('keydown', down, true)
  }, [])

  // A thread asked for by a search hit (`comment:<id>`).
  const revealComment = (ref: string) => {
    if (!ref.startsWith(COMMENT_REF)) return false
    openThread(ref.slice(COMMENT_REF.length))
    return true
  }

  const menuItems = (id: string): (MenuItem | 'divider')[] => [
    { label: 'Comment', keys: COMMENT_KEYS, run: () => startComment(id) },
    'divider',
    { label: 'Duplicate', keys: `${MOD}D`, run: duplicate },
    { label: 'Bring to front', keys: `${MOD}]`, run: () => restack(true) },
    { label: 'Send to back', keys: `${MOD}[`, run: () => restack(false) },
    'divider',
    { label: 'Delete', keys: '⌫', danger: true, run: removeSelected },
  ]

  const onContextMenu = (e: ReactMouseEvent<HTMLDivElement>) => {
    e.preventDefault()
    const target = e.target as Element
    if (readOnly || isTextField(target) || target.closest('[data-testid="comment-popover"], [data-testid="comments-panel"], [data-testid="board-menu"]')) return
    const id = target.closest('[data-id]')?.getAttribute('data-id') ?? null
    if (!id || !live.byId.has(id)) {
      setMenu(null)
      return
    }
    if (!selection.has(id)) select([id])
    setCommentFocus(null)
    setMenu({ at: localPoint(e), id })
  }

  // ---- what to draw -----------------------------------------------------------------

  const vis = useMemo(() => {
    const b = visibleWorld(view, size.w || 1, size.h || 1)
    const m = 300 / view.z
    return { x: b.x - m, y: b.y - m, w: b.w + m * 2, h: b.h + m * 2 }
  }, [view, size])
  const onScreen = (s: Shape) => boxesOverlap(vis, s) || selection.has(s.id) || editing?.id === s.id
  const frames = live.list.filter(s => s.type === 'frame' && onScreen(s))
  const boxes = live.list.filter(s => s.type !== 'frame' && s.type !== 'arrow' && onScreen(s))
  const arrows = live.arrows.filter(
    a => a.shape.id !== reEnding && (boxesOverlap(vis, arrowBox(a.path)) || selection.has(a.shape.id))
  )
  const editId = editing?.id ?? null

  // Which live frames get a real iframe: on screen, big enough to read, a few at most.
  const [mountedFrames, setMountedFrames] = useState<ReadonlySet<string>>(() => new Set())
  const liveFrames = boxes.filter(s => s.type === 'link' && s.live)
  const wantMounted = framesToMount(liveFrames, {
    visible: visibleWorld(view, size.w || 1, size.h || 1),
    zoom: view.z,
    active: activeId,
    mounted: mountedFrames,
  })
  if (wantMounted.size !== mountedFrames.size || [...wantMounted].some(id => !mountedFrames.has(id))) setMountedFrames(wantMounted)
  const frameUsers = new Map<string, FrameUser[]>()
  for (const p of peers) {
    if (!p.frame) continue
    const list = frameUsers.get(p.frame) ?? []
    list.push({ clientId: p.clientId, name: p.name, color: p.color })
    frameUsers.set(p.frame, list)
  }

  const single = selected.length === 1 ? selected[0]! : null
  const busy = !!(drag || draft || frameDraft || panning)
  const frameBusy = busy || !!marquee
  const resizable = tool === 'select' && single && !readOnly && isResizable(single.type) && editId !== single.id ? single : null
  const selectedBoxes = selected.filter(s => s.type !== 'arrow' && s.id !== editId)
  const editShape = editId ? live.byId.get(editId) : undefined
  const editBox = editShape && (editShape.type === 'sticky' || editShape.type === 'text' || isChecklist(editShape)) ? editShape : null
  const group = selected.length > 1 ? unionBox(selected.map(s => boundsOf(s.id)).filter((b): b is Box => !!b)) : null

  const toScreen = (p: Point) => ({ x: view.x + p.x * view.z, y: view.y + p.y * view.z })
  const barAt = (() => {
    if (selected.length === 0 || drag || marquee || draft || readOnly || size.w === 0) return null
    // A comment open on the board has the stage; the bar comes back when it closes.
    if (commentFocus || menu) return null
    if (editId && single?.type === 'sticky' && !isChecklist(single) && !isTimeline(single)) return null
    const u = unionBox(selected.map(s => boundsOf(s.id)).filter((b): b is Box => !!b))
    if (!u) return null
    const top = toScreen({ x: u.x + u.w / 2, y: u.y })
    const bottom = toScreen({ x: u.x, y: u.y + u.h })
    if (bottom.y < 0 || top.y > size.h || top.x < -200 || top.x > size.w + 200) return null
    const frameLabel = single?.type === 'frame' ? labelPx(view.z) * 2 : 0
    const below = top.y - frameLabel < 112
    const x = Math.min(Math.max(top.x, 220), Math.max(220, size.w - 220))
    return { x, y: below ? bottom.y + 14 : top.y - 14 - frameLabel, below }
  })()

  // The editing hint goes under the note, or over it when the bottom (or the
  // selection bar) has the space below; always on screen.
  const hintAt = (() => {
    // A checklist's fields are one line each, not markdown: no hint.
    if (!editBox || size.w === 0 || isChecklist(editBox) || isTimeline(editBox)) return null
    const top = toScreen({ x: editBox.x, y: editBox.y })
    const bottom = toScreen({ x: editBox.x, y: editBox.y + editBox.h })
    const floor = size.h - 84
    const roomBelow = floor - (bottom.y + 8) >= 26 && !barAt?.below
    const above = !roomBelow && top.y - 8 - 26 >= 60
    const y = above ? top.y - 8 : Math.min(Math.max(bottom.y + 8, 60), floor - 26)
    const x = Math.min(Math.max(top.x, 12), Math.max(12, size.w - 330))
    return { x, y, above }
  })()

  const hovered = hover && !busy ? live.byId.get(hover) : undefined
  const chip =
    hovered && hovered.by && hovered.by !== me.name && hovered.type !== 'arrow' && editId !== hovered.id
      ? {
          at: toScreen({ x: hovered.x, y: hovered.y + hovered.h }),
          name: hovered.by,
          agent: readAgents(store.agents).some(a => a.name === hovered.by),
        }
      : null

  const peerSelections = peers
    .filter(p => p.selection.length > 0)
    .map(p => ({ peer: p, boxes: p.selection.map(id => boundsOf(id)).filter((b): b is Box => !!b) }))

  const rings: RingPlace[] = search.open
    ? search.results.flatMap((hit, i) => {
        const at = locate(hit.ref)
        return at ? [{ ref: hit.ref, on: i === search.active, ...at }] : []
      })
    : []

  const draftD = draft ? draftPath(draft)?.d : null
  const anchorTarget = draft?.hover ?? (tool === 'arrow' ? arrowHover : null)
  const anchorBox = anchorTarget ? live.boxOf(anchorTarget.id) : null
  const selectedArrowPath = single?.type === 'arrow' && !draft ? live.arrowById.get(single.id) : undefined

  const cursor = panning
    ? 'grabbing'
    : tool === 'hand' || space
      ? 'grab'
      : tool === 'laser'
        ? LASER_CURSOR
        : tool === 'select'
          ? 'default'
          : 'crosshair'
  const grid = gridBackground(view)

  return (
    <BoardContext.Provider value={actions}>
      <div
        ref={viewport}
        role="application"
        aria-label={`${cfg.name} canvas`}
        tabIndex={0}
        className={cn('relative h-full w-full touch-none overflow-hidden outline-none', dropping && 'ring-4 ring-inset ring-accent/40')}
        style={{
          cursor,
          backgroundColor: 'var(--bg)',
          ...grid,
        }}
        onPointerDown={onPointerDown}
        onMouseDown={e => {
          if (keepFocus.current) {
            keepFocus.current = false
            e.preventDefault()
          }
        }}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
        onPointerLeave={onPointerLeave}
        onContextMenu={onContextMenu}
        onDragOver={onDragOver}
        onDragLeave={() => setDropping(false)}
        onDrop={onDrop}
      >
        <div
          ref={layer}
          className="absolute left-0 top-0 origin-top-left"
          style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.z})`, '--z': view.z } as CSSProperties}
        >
          {frames.map(s => (
            <FrameView key={s.id} shape={s} editing={editId === s.id} selected={selection.has(s.id)} zoom={view.z} />
          ))}
          {boxes.map(s =>
            isTimeline(s) ? (
              <TimelineView key={s.id} shape={s} editing={editId === s.id ? (editing?.field ?? null) : null} selected={selection.has(s.id)} />
            ) : s.type === 'sticky' && !isChecklist(s) ? (
              <StickyView key={s.id} shape={s} editing={editId === s.id} />
            ) : s.type === 'text' ? (
              <TextView key={s.id} shape={s} editing={editId === s.id} />
            ) : s.type === 'image' ? (
              <ImageView key={s.id} shape={s} />
            ) : isChecklist(s) ? (
              <ChecklistView
                key={s.id}
                shape={s}
                editing={editId === s.id ? (editing?.field ?? null) : null}
                selected={selection.has(s.id)}
              />
            ) : s.live ? (
              <WebFrame
                key={s.id}
                shape={s}
                selected={selection.has(s.id)}
                active={activeId === s.id}
                mounted={wantMounted.has(s.id)}
                busy={frameBusy}
                zoom={view.z}
                users={frameUsers.get(s.id) ?? NO_USERS}
                onDeactivate={deactivate}
                onLive={setLive}
              />
            ) : (
              <LinkView key={s.id} shape={s} selected={selection.has(s.id)} />
            )
          )}
          <ArrowLayer arrows={arrows} selected={selection} zoom={view.z} />
          {arrows.map(({ shape, path }) => (
            <ArrowLabel key={shape.id} shape={shape} path={path} editing={editId === shape.id} selected={selection.has(shape.id)} />
          ))}

          {peerSelections.map(({ peer, boxes: b }) => (
            <SelectionOutlines key={peer.clientId} boxes={b} group={null} zoom={view.z} color={peer.color} dashed />
          ))}
          <SelectionOutlines boxes={selectedBoxes} group={group} zoom={view.z} />
          {editBox && <EditingOutline box={editBox} zoom={view.z} />}
          {rings.length > 0 && <SearchRings places={rings} zoom={view.z} />}
          {resizable && (
            <ResizeHandles
              box={resizable}
              zoom={view.z}
              edges={resizable.type !== 'image'}
              widthOnly={isChecklist(resizable)}
              onStart={(handle, e) => startResize(resizable, handle, e)}
            />
          )}
          {selectedArrowPath && single && !readOnly && (
            <ArrowEndHandles path={selectedArrowPath} zoom={view.z} onStart={(end, e) => startEndDrag(single, end, e)} />
          )}
          {anchorBox && <AnchorDots box={anchorBox} hot={anchorTarget?.side ?? null} zoom={view.z} />}
          {draftD && <ArrowDraft d={draftD} zoom={view.z} />}
          {frameDraft && (
            <div
              className="pointer-events-none absolute left-0 top-0 rounded-[10px] border-accent bg-accent-soft"
              style={{
                width: frameDraft.w,
                height: frameDraft.h,
                transform: `translate(${frameDraft.x}px, ${frameDraft.y}px)`,
                borderWidth: 1.5 / view.z,
              }}
            />
          )}
          {marquee && <Marquee box={marquee} zoom={view.z} />}
          <PeerCursors peers={peers} zoom={view.z} />
          <AgentCursors agents={agents} zoom={view.z} />
        </div>
        <LaserCanvas trails={trails} view={view} />
        <CommentPins
          pins={pins}
          focus={commentFocus}
          onOpen={pin => {
            setMenu(null)
            // The pin of what is open closes it, as in Figma.
            if (commentFocus && focusAnchor === pin.anchor) closeComment()
            else if (pin.threads.length === 1) setCommentFocus({ kind: 'thread', id: pin.threads[0]!.id })
            else if (pin.threads.length > 1) setCommentFocus({ kind: 'shape', anchor: pin.anchor })
          }}
        />

        {shapes.size === 0 && !editId && <EmptyHint readOnly={readOnly} />}
        {hintAt && <EditHint at={hintAt} above={hintAt.above} />}
        {chip && <AuthorChip at={{ x: chip.at.x, y: chip.at.y + 6 }} name={chip.name} agent={chip.agent} />}

        {barAt && (
          <SelectionBar
            at={barAt}
            below={barAt.below}
            shapes={selected}
            onColor={recolor}
            onFont={size => store.transact(() => selected.forEach(s => store.update(s.id, { fontSize: size })))}
            onAlign={align => single && store.update(single.id, { align })}
            onFront={() => restack(true)}
            onBack={() => restack(false)}
            onDuplicate={duplicate}
            onDelete={removeSelected}
            onRemoveImage={() => single && store.update(single.id, { image: null } as unknown as Partial<Shape>)}
            onOpen={() => single?.url && openUrl(single.url)}
            onLive={single?.type === 'link' && frameUrl(single.url) ? on => setLive(single.id, on) : undefined}
            onComment={single && !readOnly ? () => startComment(single.id) : undefined}
          />
        )}

        <TitleBar name={cfg.name} kind={cfg.kind} status={status} readOnly={readOnly} />
        <TopRight
          onSearch={() => (search.open ? search.close() : search.show())}
          searchOpen={search.open}
          comments={{
            open: commentsOpen,
            count: openCount,
            onToggle: () => {
              setCommentsOpen(o => !o)
              setMenu(null)
            },
          }}
          onHelp={() => setHelp(true)}
          share={share}
          peers={peers}
          agents={agents}
          onPeer={peer => {
            const { w, h } = sizeRef.current
            if (peer.cursor) flight.fly(revealView({ ...peer.cursor, w: 1, h: 1 }, view, w, h))
            else if (peer.selection.length) zoomToIds(peer.selection)
          }}
          onAgent={agent => {
            if (!agent.cursor) return
            const { w, h } = sizeRef.current
            flight.fly(revealView({ ...agent.cursor, w: 1, h: 1 }, view, w, h))
          }}
          onShare={() => postToHost({ type: 'share' })}
        />
        <SearchBox search={search} onReveal={revealHit} />
        {commentsOpen && (
          <CommentsPanel
            threads={threads}
            shapes={shapes}
            focus={commentFocus}
            readOnly={readOnly}
            onPick={(t, at) => openThread(t.id, at)}
            onClose={() => {
              setCommentsOpen(false)
              viewport.current?.focus({ preventScroll: true })
            }}
          />
        )}
        {commentFocus && (
          <CommentPopover
            key={commentFocus.kind === 'thread' ? commentFocus.id : `${commentFocus.kind}:${commentFocus.anchor}`}
            focus={commentFocus}
            threads={threads}
            shapes={shapes}
            store={store.comments}
            me={author}
            readOnly={readOnly}
            pin={focusPin ? { x: focusPin.x, y: focusPin.y, w: PIN_H, h: PIN_H } : null}
            area={{ w: size.w, h: size.h, right: commentRight }}
            onFocus={setCommentFocus}
            onClose={closeComment}
            onResolved={id =>
              toast('Comment resolved', 'info', 4000, { label: 'Undo', run: () => store.comments.setResolved(id, false, author) })
            }
            onDeleted={(thread, message, text) =>
              toast('Comment deleted', 'info', 8000, { label: 'Undo', run: () => store.comments.restore(thread, message, text, author) })
            }
          />
        )}
        {menu && <BoardMenu at={menu.at} area={size} items={menuItems(menu.id)} onClose={() => setMenu(null)} />}

        <Toolbar
          tool={tool}
          onTool={next => {
            if (next === 'image') openImagePicker(null)
            else if (next === 'link') setLinkAt(center0())
            else setTool(next)
            viewport.current?.focus({ preventScroll: true })
          }}
          color={noteColor}
          onColor={c => {
            setNoteColor(c)
            if (selected.some(s => s.type === 'sticky' && !isChecklist(s) && !isTimeline(s))) recolor(c)
          }}
          readOnly={readOnly}
        />
        <ZoomBar
          zoom={view.z}
          onZoom={zoomBy}
          onFit={fitAll}
          onReset={zoomReset}
          canUndo={history.undo}
          canRedo={history.redo}
          onUndo={undo}
          onRedo={redo}
          readOnly={readOnly}
        />
        <CompactBar
          zoom={view.z}
          onZoom={zoomBy}
          onFit={fitAll}
          onReset={zoomReset}
          canUndo={history.undo}
          canRedo={history.redo}
          onUndo={undo}
          onRedo={redo}
          readOnly={readOnly}
        />
        {linkAt && (
          <LinkPrompt
            onSubmit={(url, live) => {
              addLink(url, linkAt, undefined, { live })
              setLinkAt(null)
              viewport.current?.focus({ preventScroll: true })
            }}
            onClose={() => {
              setLinkAt(null)
              viewport.current?.focus({ preventScroll: true })
            }}
          />
        )}
        <Toasts toasts={toasts} />
        {help && <ShortcutsSheet onClose={() => setHelp(false)} />}
        <input
          ref={fileInput}
          type="file"
          accept="image/*"
          className="hidden"
          aria-hidden="true"
          tabIndex={-1}
          onChange={e => {
            const file = e.currentTarget.files?.[0]
            const target = imageAt.current
            e.currentTarget.value = ''
            if (file) void placeImage(file, target?.frame ?? null, target?.at ?? center0(), target?.free ?? true)
          }}
        />
      </div>
    </BoardContext.Provider>
  )
}

/** Frame label size on screen (mirrors FrameView). */
const labelPx = (zoom: number) => 13 / Math.min(1, zoom) * zoom
