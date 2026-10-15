/**
 * Screen-space chrome: the tool bar, zoom and history cluster, the title
 * pill with sync status and who is here, the selection bar, the link prompt,
 * the shortcuts sheet, the empty-board hint and toasts.
 */
import { useEffect, useRef, useState, type ReactNode } from 'react'
import {
  AlignCenter,
  AlignLeft,
  AlignRight,
  ArrowUpRight,
  BringToFront,
  CalendarRange,
  ChevronUp,
  Copy,
  ExternalLink,
  Frame as FrameIcon,
  Hand,
  ImageIcon,
  ImageOff,
  Keyboard,
  Link2,
  ListChecks,
  Lock,
  Maximize,
  MessageSquarePlus,
  Minus,
  MonitorPlay,
  MousePointer2,
  PencilLine,
  Plus,
  RectangleHorizontal,
  Redo2,
  Search,
  SendToBack,
  Sparkles,
  StickyNote,
  Trash2,
  Type,
  Undo2,
  UsersRound,
  X,
} from 'lucide-react'
import { COLOR_LABEL, SHAPE_COLORS, initials, swatchOf } from '../colors'
import type { StatusView } from '../status'
import { facepilePeople, mergePresence } from '../presence'
import type { CanvasAgent, NamedColor, Shape, ShapeColor } from '../types'
import { ChatButton } from '../chat/ChatButton'
import { chat } from '../chat'
import type { PeerView } from './Overlays'
import { AgentDot } from './Overlays'
import { COMMENT_KEYS, CommentsButton } from './Comments'
import { Divider, EDIT_HINT_ID, IconButton, Kbd, MOD, Panel, Tip, cn } from './ui'

export type Tool = 'select' | 'hand' | 'sticky' | 'text' | 'frame' | 'arrow' | 'image' | 'link' | 'checklist' | 'timeline' | 'laser'

export const TOOL_KEYS: Record<string, Tool> = {
  v: 'select',
  h: 'hand',
  s: 'sticky',
  n: 'sticky',
  t: 'text',
  f: 'frame',
  a: 'arrow',
  x: 'arrow',
  i: 'image',
  l: 'link',
  r: 'checklist',
  g: 'timeline',
  k: 'laser',
}

/** The laser pointer: a beam with a spark at its tip. */
function LaserIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth={1.4} strokeLinecap="round" className={className} aria-hidden="true">
      <path d="M3 13L9.5 6.5M11.5 4.5l.01-.01M11.5 1.5v1.5M14.5 4.5H13M13.6 2.4l-1.1 1.1M13.6 6.6l-1.1-1.1M9.4 2.4l1.1 1.1" />
    </svg>
  )
}

const TOOLS: { tool: Tool; label: string; key: string; icon: ReactNode; edit?: boolean }[] = [
  { tool: 'select', label: 'Select', key: 'V', icon: <MousePointer2 className="h-[18px] w-[18px]" /> },
  { tool: 'hand', label: 'Hand', key: 'H', icon: <Hand className="h-[18px] w-[18px]" /> },
  { tool: 'sticky', label: 'Sticky note', key: 'S', icon: <StickyNote className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'text', label: 'Text', key: 'T', icon: <Type className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'frame', label: 'Frame', key: 'F', icon: <FrameIcon className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'arrow', label: 'Arrow', key: 'A', icon: <ArrowUpRight className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'image', label: 'Image', key: 'I', icon: <ImageIcon className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'link', label: 'Link', key: 'L', icon: <Link2 className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'checklist', label: 'Checklist', key: 'R', icon: <ListChecks className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'timeline', label: 'Timeline', key: 'G', icon: <CalendarRange className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'laser', label: 'Laser pointer', key: 'K', icon: <LaserIcon className="h-[18px] w-[18px]" /> },
]

/** Tool buttons narrow with the window, so the whole bar fits down to 320 px. */
const NARROW_TOOL = 'max-[479px]:w-8 max-[399px]:w-7'

function Swatch({
  color,
  active,
  onPick,
  size = 'md',
}: {
  color: NamedColor
  active: boolean
  onPick: (c: NamedColor) => void
  size?: 'sm' | 'md'
}) {
  return (
    <button
      type="button"
      aria-label={COLOR_LABEL[color]}
      aria-pressed={active}
      className={cn(
        'tip-host shrink-0 rounded-full border border-black/10 outline-none transition-transform hover:scale-110 focus-visible:ring-2 focus-visible:ring-accent dark:border-white/20',
        size === 'md' ? 'h-[22px] w-[22px]' : 'h-[18px] w-[18px]',
        active && 'ring-2 ring-accent ring-offset-2 ring-offset-surface'
      )}
      style={{ background: swatchOf(color) }}
      onClick={() => onPick(color)}
    />
  )
}

export function Toolbar({
  tool,
  onTool,
  color,
  onColor,
  readOnly,
}: {
  tool: Tool
  onTool: (tool: Tool) => void
  color: NamedColor
  onColor: (c: NamedColor) => void
  readOnly: boolean
}) {
  const [palette, setPalette] = useState(false)
  const tools = readOnly ? TOOLS.filter(t => !t.edit) : TOOLS
  return (
    <div className="pointer-events-none absolute inset-x-0 bottom-3 flex justify-center px-3">
      <Panel role="toolbar" aria-label="Tools" className="pointer-events-auto relative flex max-w-full items-center gap-0.5 p-1 max-[399px]:gap-0">
        {tools.map((t, i) => (
          <span key={t.tool} className="contents">
            {(i === 2 || (t.tool === 'laser' && i > 2)) && <Divider className="max-[399px]:hidden" />}
            <IconButton label={t.label} keys={t.key} active={tool === t.tool} onClick={() => onTool(t.tool)} className={NARROW_TOOL}>
              {t.icon}
            </IconButton>
          </span>
        ))}
        {!readOnly && (
          <>
            <Divider className="max-[399px]:hidden" />
            <button
              type="button"
              aria-label="Note colour"
              aria-expanded={palette}
              className={cn('tip-host flex h-9 w-9 shrink-0 items-center justify-center rounded-[10px] hover:bg-surface-2', NARROW_TOOL)}
              onClick={() => setPalette(p => !p)}
            >
              <span className="h-[20px] w-[20px] rounded-full border border-black/10 dark:border-white/20" style={{ background: swatchOf(color) }} />
              {!palette && (
                <span className="tip flex items-center gap-1.5 rounded-lg bg-[#1d1d1f] px-2 py-1 text-[11.5px] font-medium text-white shadow-2 dark:bg-[#f2f2ef] dark:text-[#1d1d1f]">
                  Colour for new notes
                </span>
              )}
            </button>
            {palette && (
              <Panel className="pop-in absolute bottom-[calc(100%+8px)] right-0 flex items-center gap-2 px-2.5 py-2">
                {SHAPE_COLORS.map(c => (
                  <Swatch
                    key={c}
                    color={c}
                    active={color === c}
                    onPick={next => {
                      onColor(next)
                      setPalette(false)
                    }}
                  />
                ))}
              </Panel>
            )}
          </>
        )}
      </Panel>
    </div>
  )
}

export function ZoomBar({
  zoom,
  onZoom,
  onFit,
  onReset,
  canUndo,
  canRedo,
  onUndo,
  onRedo,
  readOnly,
}: {
  zoom: number
  onZoom: (factor: number) => void
  onFit: () => void
  onReset: () => void
  canUndo: boolean
  canRedo: boolean
  onUndo: () => void
  onRedo: () => void
  readOnly: boolean
}) {
  return (
    <Panel className="pointer-events-auto absolute bottom-3 right-3 hidden items-center gap-0.5 p-1 min-[880px]:flex">
      {!readOnly && (
        <>
          <IconButton size="sm" label="Undo" keys={`${MOD}Z`} disabled={!canUndo} onClick={onUndo}>
            <Undo2 className="h-4 w-4" />
          </IconButton>
          <IconButton size="sm" label="Redo" keys={`⇧${MOD}Z`} disabled={!canRedo} onClick={onRedo}>
            <Redo2 className="h-4 w-4" />
          </IconButton>
          <Divider />
        </>
      )}
      <IconButton size="sm" label="Zoom out" keys="−" onClick={() => onZoom(1 / 1.25)}>
        <Minus className="h-4 w-4" />
      </IconButton>
      <button
        type="button"
        aria-label="Zoom to 100%"
        className="tip-host h-7 w-12 rounded-lg text-center text-[12px] font-medium tabular-nums text-ink-2 hover:bg-surface-2"
        onClick={onReset}
      >
        {Math.round(zoom * 100)}%
        <span className="tip flex items-center gap-1.5 rounded-lg bg-[#1d1d1f] px-2 py-1 text-[11.5px] font-medium text-white shadow-2 dark:bg-[#f2f2ef] dark:text-[#1d1d1f]">
          Zoom to 100% <span className="rounded bg-white/15 px-1 text-[10.5px] dark:bg-black/10">⇧0</span>
        </span>
      </button>
      <IconButton size="sm" label="Zoom in" keys="+" onClick={() => onZoom(1.25)}>
        <Plus className="h-4 w-4" />
      </IconButton>
      <IconButton size="sm" label="Zoom to fit" keys="⇧1" tipEnd onClick={onFit}>
        <Maximize className="h-[15px] w-[15px]" />
      </IconButton>
    </Panel>
  )
}

/**
 * The compact cluster for narrow windows, above the tools: history, and the
 * zoom percentage, which opens − / + / 100% / fit.
 */
export function CompactBar({
  onZoom,
  onFit,
  onReset,
  canUndo,
  canRedo,
  onUndo,
  onRedo,
  zoom,
  readOnly,
}: {
  onZoom: (factor: number) => void
  onFit: () => void
  onReset: () => void
  canUndo: boolean
  canRedo: boolean
  onUndo: () => void
  onRedo: () => void
  zoom: number
  readOnly: boolean
}) {
  const [open, setOpen] = useState(false)
  const root = useRef<HTMLDivElement>(null)
  const trigger = useRef<HTMLButtonElement>(null)
  const first = useRef<HTMLButtonElement>(null)
  const byKeyboard = useRef(false)
  const pct = Math.round(zoom * 100)

  useEffect(() => {
    if (!open) return
    if (byKeyboard.current) first.current?.focus({ preventScroll: true })
    const away = (e: PointerEvent) => {
      if (!root.current?.contains(e.target as Node)) setOpen(false)
    }
    // Esc closes it wherever focus is (WebKit leaves clicked buttons unfocused).
    const esc = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      e.stopPropagation()
      setOpen(false)
      if (root.current?.contains(document.activeElement)) trigger.current?.focus({ preventScroll: true })
    }
    window.addEventListener('pointerdown', away, true)
    window.addEventListener('keydown', esc, true)
    return () => {
      window.removeEventListener('pointerdown', away, true)
      window.removeEventListener('keydown', esc, true)
    }
  }, [open])

  return (
    <div
      ref={root}
      className="pointer-events-auto absolute bottom-[68px] right-3 min-[880px]:hidden"
      onKeyDown={e => {
        // Enter and Space on these buttons press them; they are not the board's shortcuts.
        if (e.key === 'Enter' || e.key === ' ') e.stopPropagation()
      }}
    >
      {open && (
        <Panel
          role="group"
          aria-label="Zoom"
          id="canvas-zoom-menu"
          className="pop-in absolute bottom-[calc(100%+8px)] right-0 flex items-center gap-0.5 p-1"
        >
          <IconButton ref={first} size="sm" label="Zoom out" keys="−" onClick={() => onZoom(1 / 1.25)}>
            <Minus className="h-4 w-4" />
          </IconButton>
          <IconButton size="sm" label="Zoom in" keys="+" onClick={() => onZoom(1.25)}>
            <Plus className="h-4 w-4" />
          </IconButton>
          <Divider />
          <button
            type="button"
            aria-label="Zoom to 100% (⇧0)"
            className="tip-host h-7 min-w-[48px] rounded-lg px-1.5 text-center text-[12px] font-medium tabular-nums text-ink-2 outline-none hover:bg-surface-2 hover:text-ink focus-visible:ring-2 focus-visible:ring-accent/60"
            onClick={onReset}
          >
            100%
            <Tip label="Zoom to 100%" keys="⇧0" />
          </button>
          <IconButton size="sm" label="Zoom to fit" keys="⇧1" tipEnd onClick={onFit}>
            <Maximize className="h-[15px] w-[15px]" />
          </IconButton>
        </Panel>
      )}
      <Panel className="flex items-center gap-0.5 p-1">
        {!readOnly && (
          <>
            <IconButton size="sm" label="Undo" keys={`${MOD}Z`} disabled={!canUndo} onClick={onUndo}>
              <Undo2 className="h-4 w-4" />
            </IconButton>
            <IconButton size="sm" label="Redo" keys={`⇧${MOD}Z`} disabled={!canRedo} onClick={onRedo}>
              <Redo2 className="h-4 w-4" />
            </IconButton>
            <Divider />
          </>
        )}
        <button
          ref={trigger}
          type="button"
          aria-label={`Zoom ${pct}%: zoom in, out, to 100% or to fit`}
          aria-haspopup="true"
          aria-expanded={open}
          aria-controls={open ? 'canvas-zoom-menu' : undefined}
          className={cn(
            'tip-host tip-end flex h-7 min-w-[56px] items-center justify-center gap-0.5 rounded-lg pl-2 pr-1 text-[12px] font-medium tabular-nums text-ink-2 outline-none hover:bg-surface-2 hover:text-ink focus-visible:ring-2 focus-visible:ring-accent/60',
            open && 'bg-surface-2 text-ink'
          )}
          onPointerDown={() => {
            byKeyboard.current = false
          }}
          onKeyDown={e => {
            if (e.key === 'Enter' || e.key === ' ' || e.key === 'ArrowUp') byKeyboard.current = true
            if (e.key === 'ArrowUp' && !open) {
              e.preventDefault()
              setOpen(true)
            }
          }}
          onClick={() => setOpen(o => !o)}
        >
          {pct}%
          <ChevronUp className={cn('h-3.5 w-3.5 opacity-60 transition-transform', open && 'rotate-180')} aria-hidden="true" />
          {!open && <Tip label="Zoom" />}
        </button>
      </Panel>
    </div>
  )
}

const TONE_DOT: Record<StatusView['tone'], string> = {
  muted: 'bg-ink-4',
  success: 'bg-success',
  warning: 'bg-warning',
}

function Avatar({
  name,
  color,
  ring,
  agent,
  onClick,
}: {
  name: string
  color: string
  ring?: boolean
  agent?: CanvasAgent
  onClick?: () => void
}) {
  return (
    <button
      type="button"
      aria-label={agent ? `${name}, agent, ${agent.status}` : name}
      onClick={onClick}
      className="tip-host tip-below relative -ml-1.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full border-2 border-surface text-[11px] font-semibold text-white first:ml-0 outline-none focus-visible:ring-2 focus-visible:ring-accent/60"
      style={{ background: color }}
    >
      {agent ? <Sparkles className="h-3.5 w-3.5" aria-hidden="true" /> : initials(name)}
      {ring && <span className="absolute -inset-[3px] rounded-full border-2" style={{ borderColor: color }} />}
      {agent && <AgentDot agent={agent} className="absolute -bottom-0.5 -right-0.5 rounded-full ring-2 ring-surface" />}
      <span className="tip tip-below flex items-center gap-1.5 rounded-lg bg-[#1d1d1f] px-2 py-1 text-[11.5px] font-medium text-white shadow-2 dark:bg-[#f2f2ef] dark:text-[#1d1d1f]">
        {name}
        {agent && <span className="opacity-70">agent</span>}
        {agent && agent.status !== 'idle' && <span className="opacity-70">{agent.status}…</span>}
      </span>
    </button>
  )
}

export function TitleBar({
  name,
  kind,
  status,
  readOnly,
}: {
  name: string
  kind: string
  status: StatusView
  readOnly: boolean
}) {
  const s = status
  const dot = TONE_DOT[s.tone]
  const warn = s.tone === 'warning' && !s.pulse
  return (
    <div className="pointer-events-none absolute left-3 right-[120px] top-3 flex min-w-0 items-center gap-2">
      <Panel className="pointer-events-auto flex min-w-0 items-center gap-2.5 py-1.5 pl-3 pr-3" data-testid="canvas-status" data-status={s.key}>
        <span className="relative flex h-2 w-2 shrink-0" aria-hidden="true">
          {s.pulse && <span className={cn('pulse-ring absolute h-full w-full rounded-full', dot)} />}
          <span className={cn('relative h-2 w-2 rounded-full', dot)} />
        </span>
        <h1 className="min-w-0 truncate text-[13.5px] font-semibold tracking-[-0.005em] text-ink">{name}</h1>
        {kind === 'personal' && (
          <span className="tip-host tip-below flex shrink-0 items-center gap-1 rounded-md bg-surface-2 px-1.5 py-0.5 text-[11px] font-medium text-ink-3">
            <Lock className="h-3 w-3" aria-hidden="true" />
            Private
            <span className="tip tip-below rounded-lg bg-[#1d1d1f] px-2 py-1 text-[11.5px] font-medium text-white shadow-2 dark:bg-[#f2f2ef] dark:text-[#1d1d1f]">
              Only you can see this canvas
            </span>
          </span>
        )}
        {readOnly && <span className="shrink-0 rounded-md bg-surface-2 px-1.5 py-0.5 text-[11px] font-medium text-ink-3">View only</span>}
        <span
          tabIndex={0}
          aria-label={`${s.label}. ${s.hint}`}
          className={cn(
            'tip-host tip-below tip-start tip-wrap shrink-0 whitespace-nowrap rounded text-[12px] outline-none focus-visible:ring-2 focus-visible:ring-accent/60',
            warn ? 'font-medium text-[color:var(--warning-ink)]' : 'text-ink-3'
          )}
        >
          <span aria-hidden="true" className="min-[640px]:hidden">
            {s.short}
          </span>
          <span aria-hidden="true" className="hidden min-[640px]:inline">
            {s.label}
          </span>
          <span role="status" className="sr-only">
            {s.label}
          </span>
          <span className="tip rounded-lg bg-[#1d1d1f] px-2 py-1 text-[11.5px] font-medium leading-snug text-white shadow-2 dark:bg-[#f2f2ef] dark:text-[#1d1d1f]">
            {s.hint}
          </span>
        </span>
      </Panel>
    </div>
  )
}

/** One avatar per person, however many windows they have open. */
export function dedupePeers(peers: readonly PeerView[]): PeerView[] {
  const seen = new Map<string, PeerView>()
  for (const p of peers) if (!seen.has(p.id) || (p.cursor && !seen.get(p.id)!.cursor)) seen.set(p.id, p)
  return [...seen.values()]
}

export interface ShareButtonState {
  canShare: boolean
  members?: number
  reason?: string
}

export function Facepile({
  peers,
  agents,
  onPeer,
  onAgent,
}: {
  peers: readonly PeerView[]
  agents: readonly CanvasAgent[]
  onPeer: (peer: PeerView) => void
  onAgent: (agent: CanvasAgent) => void
}) {
  const all = mergePresence(
    dedupePeers(peers).map(peer => ({ ...peer, kind: 'human' as const })),
    agents
  )
  const { shown, overflow } = facepilePeople(all, 4)
  if (all.length === 0) return null
  return (
    <div className="hidden max-w-[148px] shrink-0 items-center px-0.5 min-[640px]:flex" data-testid="canvas-facepile">
      {shown.map(person => {
        const agent = person.kind === 'agent' ? agents.find(candidate => candidate.id === person.id) : undefined
        const peer = person.kind === 'human' ? peers.find(candidate => candidate.id === person.id && candidate.clientId === person.clientId) : undefined
        return (
          <Avatar
            key={`${person.kind}:${person.id}:${person.clientId ?? ''}`}
            name={person.name}
            color={person.color}
            ring={person.kind === 'human'}
            agent={agent}
            onClick={() => (peer ? onPeer(peer) : agent ? onAgent(agent) : undefined)}
          />
        )
      })}
      {overflow > 0 && (
        <span className="-ml-1.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full border-2 border-surface bg-surface-3 text-[10.5px] font-semibold text-ink-2">
          +{overflow}
        </span>
      )}
    </div>
  )
}

export function ShareButton({ share, onShare }: { share: ShareButtonState | null; onShare: () => void }) {
  if (!share) return null
  const disabled = !share.canShare
  return (
    <button
      type="button"
      aria-label="Share canvas"
      disabled={disabled}
      title={disabled ? share.reason || 'Sharing is unavailable' : 'Share canvas'}
      onClick={onShare}
      className="inline-flex h-7 shrink-0 items-center gap-1.5 rounded-lg bg-accent px-2.5 text-[12px] font-semibold text-accent-ink outline-none transition-colors hover:bg-accent-strong focus-visible:ring-2 focus-visible:ring-accent/60 disabled:opacity-45"
    >
      <UsersRound className="h-3.5 w-3.5" aria-hidden="true" />
      <span>Share</span>
      {typeof share.members === 'number' && share.members > 1 && <span className="rounded-full bg-accent-ink/15 px-1.5 text-[10.5px] tabular-nums">{share.members}</span>}
    </button>
  )
}

export function TopRight({
  onSearch,
  searchOpen,
  comments,
  onHelp,
  share,
  peers,
  agents,
  onPeer,
  onAgent,
  onShare,
}: {
  onSearch: () => void
  searchOpen: boolean
  /** The Comments panel: shown or not, how many threads are open, the toggle. */
  comments: { open: boolean; count: number; onToggle: () => void }
  onHelp: () => void
  share: ShareButtonState | null
  peers: readonly PeerView[]
  agents: readonly CanvasAgent[]
  onPeer: (peer: PeerView) => void
  onAgent: (agent: CanvasAgent) => void
  onShare: () => void
}) {
  return (
    <Panel className="pointer-events-auto absolute right-3 top-3 flex max-w-[calc(100vw-24px)] items-center gap-0.5 p-1">
      <Facepile peers={peers} agents={agents} onPeer={onPeer} onAgent={onAgent} />
      <ShareButton share={share} onShare={onShare} />
      <ChatButton hub={chat} />
      <CommentsButton open={comments.open} count={comments.count} onToggle={comments.onToggle} />
      <IconButton size="sm" label="Search" keys={`${MOD}F`} tipBelow tipEnd active={searchOpen} onClick={onSearch}>
        <Search className="h-4 w-4" />
      </IconButton>
      <IconButton size="sm" label="Keyboard shortcuts" keys="?" tipBelow tipEnd onClick={onHelp}>
        <Keyboard className="h-4 w-4" />
      </IconButton>
    </Panel>
  )
}

/** Colours, text size and order for the selection, floating above it. */
export function SelectionBar({
  at,
  shapes,
  onColor,
  onFont,
  onAlign,
  onFront,
  onBack,
  onDuplicate,
  onDelete,
  onRemoveImage,
  onOpen,
  onLive,
  onComment,
  below,
}: {
  at: { x: number; y: number }
  shapes: readonly Shape[]
  onColor: (c: ShapeColor) => void
  onFont: (size: number) => void
  onAlign: (a: 'left' | 'center' | 'right') => void
  onFront: () => void
  onBack: () => void
  onDuplicate: () => void
  onDelete: () => void
  onRemoveImage: () => void
  onOpen: () => void
  /** A link: show the site live (true) or as its card (false); absent when it can't be live. */
  onLive?: (live: boolean) => void
  /** Start a comment thread on the one selected shape; absent when several are selected. */
  onComment?: () => void
  below: boolean
}) {
  const single = shapes.length === 1 ? shapes[0]! : null
  const colorable = shapes.some(s => s.type !== 'image')
  const current = single?.color
  const texty = shapes.length > 0 && shapes.every(s => (s.type === 'sticky' && !s.view) || s.type === 'text')
  const font = single?.fontSize ?? (single?.type === 'text' ? 20 : 16)
  const sizes = single?.type === 'text' ? [16, 20, 28, 40] : [12, 16, 22, 30]
  return (
    <Panel
      role="toolbar"
      aria-label="Selection"
      data-testid="selection-bar"
      className="pop-in absolute z-30 flex items-center gap-1 rounded-full px-1.5 py-1"
      style={{ left: at.x, top: at.y, translate: below ? '-50% 0' : '-50% -100%' }}
    >
      {colorable && (
        <div className="flex items-center gap-1.5 px-1">
          {SHAPE_COLORS.map(c => (
            <Swatch key={c} size="sm" color={c} active={current === c} onPick={onColor} />
          ))}
        </div>
      )}
      {texty && (
        <>
          <Divider />
          <div className="flex items-center" role="group" aria-label="Text size">
            {sizes.map((s, i) => (
              <button
                key={s}
                type="button"
                aria-pressed={single ? font === s : undefined}
                aria-label={`Text size ${['small', 'medium', 'large', 'extra large'][i]}`}
                className={cn(
                  'flex h-7 w-7 items-center justify-center rounded-full font-semibold text-ink-2 hover:bg-surface-2',
                  single && font === s && 'bg-surface-3 text-ink'
                )}
                style={{ fontSize: 10 + i * 2 }}
                onClick={() => onFont(s)}
              >
                {['S', 'M', 'L', 'XL'][i]}
              </button>
            ))}
          </div>
        </>
      )}
      {single?.type === 'text' && (
        <>
          <Divider />
          {(['left', 'center', 'right'] as const).map(a => (
            <IconButton
              key={a}
              size="sm"
              label={`Align ${a}`}
              active={(single.align ?? 'left') === a}
              className="rounded-full"
              onClick={() => onAlign(a)}
            >
              {a === 'left' ? <AlignLeft className="h-4 w-4" /> : a === 'center' ? <AlignCenter className="h-4 w-4" /> : <AlignRight className="h-4 w-4" />}
            </IconButton>
          ))}
        </>
      )}
      {single?.type === 'link' && (
        <>
          <Divider />
          {onLive &&
            (single.live ? (
              <IconButton size="sm" label="Show as card" className="rounded-full" onClick={() => onLive(false)}>
                <RectangleHorizontal className="h-4 w-4" />
              </IconButton>
            ) : (
              <IconButton size="sm" label="Show live" className="rounded-full" onClick={() => onLive(true)}>
                <MonitorPlay className="h-4 w-4" />
              </IconButton>
            ))}
          <IconButton size="sm" label={single.live ? 'Open in a tab' : 'Open link'} keys={single.live ? undefined : '↵'} className="rounded-full" onClick={onOpen}>
            <ExternalLink className="h-4 w-4" />
          </IconButton>
        </>
      )}
      {single?.type === 'frame' && single.image && (
        <>
          <Divider />
          <IconButton size="sm" label="Remove image" className="rounded-full" onClick={onRemoveImage}>
            <ImageOff className="h-4 w-4" />
          </IconButton>
        </>
      )}
      {single && onComment && (
        <>
          <Divider />
          <button
            type="button"
            aria-label={`Comment (${COMMENT_KEYS})`}
            data-testid="selection-comment"
            className="tip-host inline-flex h-7 shrink-0 items-center gap-1.5 rounded-full pl-2 pr-2.5 text-[12.5px] font-medium text-ink-2 outline-none transition-colors duration-100 hover:bg-surface-2 hover:text-ink focus-visible:ring-2 focus-visible:ring-accent/60"
            onClick={onComment}
          >
            <MessageSquarePlus className="h-4 w-4" aria-hidden="true" />
            Comment
            <Tip label="Comment" keys={COMMENT_KEYS} />
          </button>
        </>
      )}
      <Divider />
      <IconButton size="sm" label="Bring to front" keys={`${MOD}]`} className="rounded-full" onClick={onFront}>
        <BringToFront className="h-4 w-4" />
      </IconButton>
      <IconButton size="sm" label="Send to back" keys={`${MOD}[`} className="rounded-full" onClick={onBack}>
        <SendToBack className="h-4 w-4" />
      </IconButton>
      <IconButton size="sm" label="Duplicate" keys={`${MOD}D`} className="rounded-full" onClick={onDuplicate}>
        <Copy className="h-4 w-4" />
      </IconButton>
      <IconButton
        size="sm"
        label="Delete"
        keys="⌫"
        className="rounded-full hover:!bg-danger/10 hover:!text-danger"
        onClick={onDelete}
      >
        <Trash2 className="h-4 w-4" />
      </IconButton>
    </Panel>
  )
}

/** Ask for an address; Enter puts a link card on the board, ⌥Enter (or "Live") the site itself. */
export function LinkPrompt({ onSubmit, onClose }: { onSubmit: (url: string, live: boolean) => void; onClose: () => void }) {
  const ref = useRef<HTMLInputElement>(null)
  const [value, setValue] = useState('')
  const [error, setError] = useState('')
  useEffect(() => ref.current?.focus(), [])
  const submit = (live = false) => {
    const v = value.trim()
    if (!v) return onClose()
    const withScheme = /^[a-z][a-z0-9+.-]*:/i.test(v) ? v : `https://${v}`
    try {
      const u = new URL(withScheme)
      if (!['http:', 'https:', 'mailto:', 'copper:'].includes(u.protocol)) throw new Error('scheme')
      if (live && u.protocol !== 'http:' && u.protocol !== 'https:') {
        setError('Only web pages can be shown live.')
        return
      }
      onSubmit(u.toString(), live)
    } catch {
      setError('That does not look like a web address.')
    }
  }
  return (
    <div className="pointer-events-none absolute inset-x-0 bottom-[72px] flex justify-center px-3">
      <Panel className="pop-in pointer-events-auto w-[min(420px,100%)] p-2">
        <form
          className="flex items-center gap-2"
          onSubmit={e => {
            e.preventDefault()
            submit()
          }}
        >
          <Link2 className="ml-1.5 h-4 w-4 shrink-0 text-ink-3" aria-hidden="true" />
          <input
            ref={ref}
            aria-label="Link address"
            value={value}
            placeholder="Paste a link…"
            spellCheck={false}
            onChange={e => {
              setValue(e.target.value)
              setError('')
            }}
            onKeyDown={e => {
              e.stopPropagation()
              if (e.key === 'Escape') onClose()
              if (e.key === 'Enter' && e.altKey) {
                e.preventDefault()
                submit(true)
              }
            }}
            className="h-8 min-w-0 flex-1 bg-transparent text-[13.5px] text-ink outline-none placeholder:text-ink-4"
          />
          <button
            type="button"
            title="Show the site itself on the board (⌥↵)"
            className="flex h-7 shrink-0 items-center gap-1 rounded-lg px-2 text-[12.5px] font-semibold text-ink-2 hover:bg-surface-2 hover:text-ink"
            onClick={() => submit(true)}
          >
            <MonitorPlay className="h-3.5 w-3.5" aria-hidden="true" />
            Live
          </button>
          <button type="submit" className="h-7 shrink-0 rounded-lg bg-accent px-2.5 text-[12.5px] font-semibold text-accent-ink hover:bg-accent-strong">
            Add
          </button>
          <IconButton size="sm" label="Cancel" keys="Esc" onClick={onClose}>
            <X className="h-4 w-4" />
          </IconButton>
        </form>
        {error && <p className="px-2 pb-0.5 pt-1.5 text-[12px] text-danger">{error}</p>}
      </Panel>
    </div>
  )
}

const SHORTCUTS: [string, string[]][] = [
  ['Select', ['V']],
  ['Hand (or hold Space)', ['H']],
  ['Sticky note', ['S']],
  ['Text', ['T']],
  ['Frame', ['F']],
  ['Arrow', ['A']],
  ['Image', ['I']],
  ['Link', ['L']],
  ['Checklist (RSVP)', ['R']],
  ['Timeline', ['G']],
  ['Laser pointer (everyone sees it)', ['K']],
  ['Edit the selected note', ['↵']],
  ['New note beside / below', [`${MOD}↵`, `⇧${MOD}↵`]],
  ['Delete', ['⌫']],
  ['Duplicate', [`${MOD}D`]],
  ['Select all', [`${MOD}A`]],
  ['Copy, cut, paste', [`${MOD}C`, `${MOD}X`, `${MOD}V`]],
  ['Undo / redo', [`${MOD}Z`, `⇧${MOD}Z`]],
  ['Nudge', ['←↑↓→', '⇧ ×10']],
  ['Bring to front / send to back', [`${MOD}]`, `${MOD}[`]],
  ['Search', [`${MOD}F`]],
  ['Comment on the selected shape', [COMMENT_KEYS]],
  ['Chat (shared canvases)', ['C']],
  ['Zoom in / out', ['+', '−']],
  ['Zoom to fit / selection', ['⇧1', '⇧2']],
  ['Zoom to 100%', ['⇧0']],
  ['Bold / italic in a note', [`${MOD}B`, `${MOD}I`]],
  ['Use a live web frame', ['Double-click', '↵']],
  ['Back to the board from a frame', ['Esc']],
]

export function ShortcutsSheet({ onClose }: { onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' || e.key === '?') {
        e.preventDefault()
        e.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [onClose])
  return (
    <div
      className="absolute inset-0 z-50 flex items-center justify-center bg-black/10 p-4 dark:bg-black/30"
      onPointerDown={e => {
        e.stopPropagation()
        onClose()
      }}
    >
      <Panel role="dialog" aria-label="Keyboard shortcuts" className="pop-in max-h-full w-[min(560px,100%)] overflow-y-auto p-5" onPointerDown={e => e.stopPropagation()}>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-[15px] font-semibold">Keyboard shortcuts</h2>
          <IconButton size="sm" label="Close" keys="Esc" onClick={onClose}>
            <X className="h-4 w-4" />
          </IconButton>
        </div>
        <dl className="grid grid-cols-1 gap-x-6 gap-y-1.5 min-[520px]:grid-cols-2">
          {SHORTCUTS.map(([label, keys]) => (
            <div key={label} className="flex items-center justify-between gap-3 py-0.5">
              <dt className="truncate text-[12.5px] text-ink-2">{label}</dt>
              <dd className="flex shrink-0 gap-1">
                {keys.map(k => (
                  <Kbd key={k}>{k}</Kbd>
                ))}
              </dd>
            </div>
          ))}
        </dl>
        <p className="mt-4 text-[12px] text-ink-3">
          Drop images, links and text onto the board. Double-click empty space for a sticky. Scroll to pan, pinch or {MOD}scroll to zoom.
        </p>
      </Panel>
    </div>
  )
}

export function EmptyHint({ readOnly }: { readOnly: boolean }) {
  return (
    <div className="pointer-events-none absolute inset-0 flex items-center justify-center p-6">
      <div className="pop-in max-w-[360px] text-center">
        <div className="mx-auto mb-4 flex h-12 w-12 rotate-[-4deg] items-center justify-center rounded-[6px] shadow-note" style={{ background: 'var(--paper-yellow)' }}>
          <StickyNote className="h-5 w-5" style={{ color: 'var(--ink-on-yellow)' }} aria-hidden="true" />
        </div>
        <p className="text-[15px] font-semibold text-ink">{readOnly ? 'Nothing here yet' : 'A blank canvas'}</p>
        {!readOnly && (
          <p className="mt-1.5 text-[13px] leading-relaxed text-ink-3">
            Double-click anywhere for a sticky, press <Kbd>S</Kbd> <Kbd>T</Kbd> <Kbd>F</Kbd> for notes, text and frames, or drop
            in images and links.
          </p>
        )}
      </div>
    </div>
  )
}

export interface Toast {
  id: number
  text: string
  tone: 'info' | 'error'
  /** One button on the toast (e.g. "Show live" after a link is dropped). */
  action?: { label: string; run: () => void }
}

export function Toasts({ toasts }: { toasts: readonly Toast[] }) {
  return (
    <div className="pointer-events-none absolute inset-x-0 bottom-[76px] flex flex-col items-center gap-2 px-3" aria-live="polite">
      {toasts.map(t => (
        <div
          key={t.id}
          className={cn(
            'pop-in flex items-center rounded-full px-3.5 py-1.5 text-[12.5px] font-medium shadow-2',
            t.tone === 'error' ? 'bg-danger text-white' : 'bg-[#1d1d1f] text-white dark:bg-[#f2f2ef] dark:text-[#1d1d1f]'
          )}
        >
          {t.text}
          {t.action && (
            <button
              type="button"
              className="pointer-events-auto -my-0.5 -mr-1.5 ml-2.5 rounded-full bg-white/15 px-2.5 py-0.5 text-[12px] font-semibold hover:bg-white/25 dark:bg-black/10 dark:hover:bg-black/20"
              onPointerDown={e => e.stopPropagation()}
              onClick={t.action.run}
            >
              {t.action.label}
            </button>
          )}
        </div>
      ))}
    </div>
  )
}

/** Under (or over) a note being edited: it is markdown now, and how to finish. */
export function EditHint({ at, above }: { at: { x: number; y: number }; above: boolean }) {
  return (
    <div
      id={EDIT_HINT_ID}
      data-testid="edit-hint"
      className="pop-in pointer-events-none absolute z-30 flex items-center gap-1.5 whitespace-nowrap rounded-full border border-line bg-surface py-[3px] pl-2 pr-2.5 text-[11.5px] font-medium text-ink-3 shadow-2"
      style={{ left: at.x, top: at.y, translate: above ? '0 -100%' : undefined }}
    >
      <PencilLine className="h-3 w-3 text-accent" aria-hidden="true" />
      <span className="font-semibold text-ink-2">Markdown</span>
      <span aria-hidden="true">·</span>
      <Kbd>Esc</Kbd>
      <span>or click outside to finish</span>
    </div>
  )
}

/** Small "by …" chip under a hovered shape that someone else made. */
export function AuthorChip({ at, name, agent }: { at: { x: number; y: number }; name: string; agent: boolean }) {
  return (
    <div
      className="pop-in pointer-events-none absolute z-20 flex items-center gap-1 rounded-full bg-surface px-2 py-[3px] text-[11px] font-medium text-ink-2 shadow-2"
      style={{ left: at.x, top: at.y }}
    >
      {agent && <Sparkles className="h-3 w-3 text-accent" aria-hidden="true" />}
      {name}
    </div>
  )
}
