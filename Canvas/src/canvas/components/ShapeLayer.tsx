/**
 * Every mounted shape, in world coordinates, inside the board's one
 * transformed layer. Memoised as a whole: a pan or zoom changes the layer's
 * transform and `--z` (both set by the board, outside this component) and
 * re-renders nothing here. What does re-render it — the culled set, the
 * selection, the editor, the live frames, the LOD zoom step — changes rarely,
 * and each shape view is memoised on its own plain shape, so only what
 * changed draws again.
 */
import { memo } from 'react'
import { isChecklist } from '../checklist'
import { countRender } from '../debug'
import { CHECKLIST_TEXT_PX, TIMELINE_TEXT_PX, drawnWidth, imageBucket, isBarText, isLowText, isVectorSrc } from '../lod'
import { isTimeline } from '../timeline'
import { STICKY_FONT, TEXT_FONT, type Shape } from '../types'
import { ChecklistView } from './Checklist'
import type { EditField } from './context'
import { LowNotes, LowShape } from './Lod'
import { ArrowLabel, ArrowLayer, FrameView, ImageView, LinkView, StickyView, TextView, type DrawnArrow } from './Shapes'
import { TimelineView } from './Timeline'
import { WebFrame, type FrameUser } from './WebFrame'

const NO_USERS: readonly FrameUser[] = []

export interface ShapeLayerProps {
  frames: readonly Shape[]
  boxes: readonly Shape[]
  arrows: readonly DrawnArrow[]
  selection: ReadonlySet<string>
  editId: string | null
  editField: EditField | null
  activeId: string | null
  /** Live frames that have their page now (`frames.ts`, `planLiveFrames`). */
  live: ReadonlySet<string>
  /** A board gesture is under way: frames' pages must not take the pointer. */
  busy: boolean
  /** The zoom in LOD steps (`lod.ts`). */
  lodZoom: number
  dpr: number
  frameUsers: ReadonlyMap<string, readonly FrameUser[]>
  onDeactivate: () => void
  onLive: (id: string, live: boolean) => void
}

export const ShapeLayer = memo(function ShapeLayer({
  frames,
  boxes,
  arrows,
  selection,
  editId,
  editField,
  activeId,
  live,
  busy,
  lodZoom,
  dpr,
  frameUsers,
  onDeactivate,
  onLive,
}: ShapeLayerProps) {
  countRender('layerRenders')
  // Simplified notes are drawn together, above the other boxes (`Lod.tsx`).
  const lowNotes: Shape[] = []
  const barNotes = new Set<string>()
  return (
    <>
      {frames.map(s => {
        const img = s.image
        const bucket = img
          ? imageBucket(drawnWidth(s.w, s.h, img.naturalW, img.naturalH, 'contain'), img.naturalW, lodZoom, dpr, isVectorSrc(img.src), s.h / Math.max(s.w, 1))
          : null
        return <FrameView key={s.id} shape={s} editing={editId === s.id} selected={selection.has(s.id)} imageBucket={bucket} />
      })}
      {boxes.map(s => {
        const editing = editId === s.id
        if (isTimeline(s)) {
          if (!editing && isLowText(TIMELINE_TEXT_PX, lodZoom)) return <LowShape key={s.id} shape={s} kind="timeline" bars={isBarText(TIMELINE_TEXT_PX, lodZoom)} />
          return <TimelineView key={s.id} shape={s} editing={editing ? editField : null} selected={selection.has(s.id)} />
        }
        if (isChecklist(s)) {
          if (!editing && isLowText(CHECKLIST_TEXT_PX, lodZoom)) return <LowShape key={s.id} shape={s} kind="checklist" bars={isBarText(CHECKLIST_TEXT_PX, lodZoom)} />
          return <ChecklistView key={s.id} shape={s} editing={editing ? editField : null} selected={selection.has(s.id)} />
        }
        if (s.type === 'sticky') {
          if (!editing && isLowText(s.fontSize ?? STICKY_FONT, lodZoom)) {
            lowNotes.push(s)
            if (isBarText(s.fontSize ?? STICKY_FONT, lodZoom)) barNotes.add(s.id)
            return null
          }
          return <StickyView key={s.id} shape={s} editing={editing} />
        }
        if (s.type === 'text') {
          if (!editing && isLowText(s.fontSize ?? TEXT_FONT, lodZoom)) return <LowShape key={s.id} shape={s} kind="text" bars={isBarText(s.fontSize ?? TEXT_FONT, lodZoom)} />
          return <TextView key={s.id} shape={s} editing={editing} />
        }
        if (s.type === 'image') {
          const natW = s.naturalW ?? 0
          const bucket = imageBucket(drawnWidth(s.w, s.h, natW, s.naturalH ?? 0, 'cover'), natW, lodZoom, dpr, isVectorSrc(s.src), s.h / Math.max(s.w, 1))
          return <ImageView key={s.id} shape={s} bucket={bucket} />
        }
        if (s.live)
          return (
            <WebFrame
              key={s.id}
              shape={s}
              selected={selection.has(s.id)}
              active={activeId === s.id}
              mounted={live.has(s.id)}
              busy={busy}
              lodZoom={lodZoom}
              dpr={dpr}
              users={frameUsers.get(s.id) ?? NO_USERS}
              onDeactivate={onDeactivate}
              onLive={onLive}
            />
          )
        return <LinkView key={s.id} shape={s} selected={selection.has(s.id)} />
      })}
      <LowNotes notes={lowNotes} bars={barNotes} />
      <ArrowLayer arrows={arrows} selected={selection} />
      {arrows.map(({ shape, path }) => (
        <ArrowLabel key={shape.id} shape={shape} path={path} editing={editId === shape.id} selected={selection.has(shape.id)} />
      ))}
    </>
  )
})
