import { beforeEach, describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { CanvasStore, LOCAL } from '../doc'
import {
  COMMENTS_KEY,
  CommentStore,
  MAX_COMMENT,
  agoLabel,
  isShown,
  liveMessages,
  readThread,
  replyCount,
  shapeLabel,
} from '../comments'
import { pinPlaces } from '../components/Comments'
import { commentSearchItems, indexSearchItems, searchIndex } from '../search'

const ADA = { id: 'aaaa-1', name: 'Ada Lovelace' }
const BOB = { id: 'bbbb-2', name: 'Bob Builder' }

let doc: Y.Doc
let store: CanvasStore
let c: CommentStore

beforeEach(() => {
  doc = new Y.Doc()
  store = new CanvasStore(doc)
  c = store.comments
  store.create({ type: 'frame', id: 'slide1', x: 0, y: 0, w: 1600, h: 900, title: 'Slide 1 — Why now' }, LOCAL)
  store.create({ type: 'sticky', id: 'n1', x: 2000, y: 0, text: '## Risks\nsupply' }, LOCAL)
})

/** Two Coppers on one board: every update one makes is handed to the other. */
function pair() {
  const a = new Y.Doc()
  const b = new Y.Doc()
  a.on('update', (u: Uint8Array, origin: unknown) => origin !== 'peer' && Y.applyUpdate(b, u, 'peer'))
  b.on('update', (u: Uint8Array, origin: unknown) => origin !== 'peer' && Y.applyUpdate(a, u, 'peer'))
  return { a: new CanvasStore(a), b: new CanvasStore(b) }
}

/** Two Coppers that are offline from each other until `sync()`. */
function apart() {
  const a = new CanvasStore(new Y.Doc())
  const b = new CanvasStore(new Y.Doc())
  const sync = () => {
    const ua = Y.encodeStateAsUpdate(a.doc, Y.encodeStateVector(b.doc))
    const ub = Y.encodeStateAsUpdate(b.doc, Y.encodeStateVector(a.doc))
    Y.applyUpdate(b.doc, ua)
    Y.applyUpdate(a.doc, ub)
  }
  return { a, b, sync }
}

describe('comment threads', () => {
  it('starts a thread on a shape, in its own top-level map', () => {
    const id = c.create('slide1', '  Is this slide still true?\r\n', ADA, { anchorName: 'Slide 1', now: 1000 })
    const t = c.get(id)!
    expect(t).toMatchObject({ id, anchor: 'slide1', anchorName: 'Slide 1', by: 'Ada Lovelace', byId: 'aaaa-1', at: 1000, resolved: false, lastAt: 1000 })
    expect(t.messages).toHaveLength(1)
    expect(t.messages[0]).toMatchObject({ by: 'Ada Lovelace', byId: 'aaaa-1', at: 1000, text: 'Is this slide still true?' })
    // Nothing about the shape changed: the thread lives beside it.
    expect(doc.getMap(COMMENTS_KEY).get(id)).toBeInstanceOf(Y.Map)
    expect(store.shapes.get('slide1')!.has('comments')).toBe(false)
    expect(c.getThreads().map(x => x.id)).toEqual([id])
  })

  it('takes replies from anyone, in order', () => {
    const id = c.create('slide1', 'First', ADA, { now: 1 })
    c.reply(id, 'Second', BOB, { now: 2 })
    c.reply(id, 'Third', ADA, { now: 3 })
    const t = c.get(id)!
    expect(t.messages.map(m => [m.by, m.text])).toEqual([
      ['Ada Lovelace', 'First'],
      ['Bob Builder', 'Second'],
      ['Ada Lovelace', 'Third'],
    ])
    expect(replyCount(t)).toBe(2)
    expect(t.lastAt).toBe(3)
  })

  it('resolves and reopens, with who and when', () => {
    const id = c.create('slide1', 'Fix the chart', ADA)
    expect(c.setResolved(id, true, BOB, { now: 50 })).toBe(true)
    expect(c.get(id)).toMatchObject({ resolved: true, resolvedBy: 'Bob Builder', resolvedById: 'bbbb-2', resolvedAt: 50 })
    expect(c.setResolved(id, false, ADA)).toBe(true)
    const t = c.get(id)!
    expect(t.resolved).toBe(false)
    expect(t.resolvedBy).toBeUndefined()
    expect(doc.getMap(COMMENTS_KEY).get(id)).toBeInstanceOf(Y.Map)
    expect((doc.getMap(COMMENTS_KEY).get(id) as Y.Map<unknown>).has('resolvedAt')).toBe(false)
    expect(c.setResolved('nope', true, ADA)).toBe(false)
  })

  it('a reply opens a resolved thread again', () => {
    const id = c.create('slide1', 'Fix the chart', ADA)
    c.setResolved(id, true, BOB)
    c.reply(id, 'Not quite — the axis is still off', ADA)
    expect(c.get(id)!.resolved).toBe(false)
  })

  it('lets authors edit their own messages only', () => {
    const id = c.create('slide1', 'Typo hree', ADA, { now: 1 })
    const first = c.get(id)!.messages[0]!.id
    expect(c.edit(id, first, 'Typo here', BOB)).toBe(false)
    expect(c.get(id)!.messages[0]!.text).toBe('Typo hree')
    // Ids compare case-insensitively (cloud uuids come in either case).
    expect(c.edit(id, first, 'Typo here', { id: 'AAAA-1', name: 'Ada' }, { now: 9 })).toBe(true)
    expect(c.get(id)!.messages[0]).toMatchObject({ text: 'Typo here', editedAt: 9 })
    expect(c.get(id)!.lastAt).toBe(9)
    expect(() => c.edit(id, first, '   ', ADA)).toThrow(/empty/)
  })

  it('lets authors delete their own messages, leaving a tombstone', () => {
    const id = c.create('slide1', 'Opening', ADA)
    const reply = c.reply(id, 'Mine', BOB)
    expect(c.remove(id, reply, ADA)).toBe(false)
    expect(c.remove(id, reply, BOB)).toBe(true)
    const t = c.get(id)!
    expect(t.messages).toHaveLength(2)
    expect(t.messages[1]).toMatchObject({ id: reply, deleted: true, text: '' })
    expect(liveMessages(t).map(m => m.text)).toEqual(['Opening'])
    expect(replyCount(t)).toBe(0)
    expect(isShown(t)).toBe(true)
    // The first message gone too: the thread stops showing but stays in the doc.
    c.remove(id, t.messages[0]!.id, ADA)
    expect(isShown(c.get(id)!)).toBe(false)
    expect(c.getThreads()).toHaveLength(1)
  })

  it('refuses empty and overlong messages', () => {
    expect(() => c.create('slide1', '  \n ', ADA)).toThrow(/empty/)
    expect(() => c.create('slide1', 'x'.repeat(MAX_COMMENT + 1), ADA)).toThrow(/at most/)
    expect(() => c.reply('missing', 'hi', ADA)).toThrow(/no comment thread/)
  })

  it('outlives the shape it is on, and finds it again when an undo brings it back', () => {
    const id = c.create('slide1', 'Keep this', ADA, { anchorName: 'Slide 1 — Why now' })
    store.undo.stopCapturing()
    store.remove(['slide1'], LOCAL)
    expect(store.live('slide1')).toBeNull()
    const t = c.get(id)!
    expect(t.anchor).toBe('slide1')
    expect(t.anchorName).toBe('Slide 1 — Why now')
    expect(isShown(t)).toBe(true)
    store.undo.undo()
    expect(store.live('slide1')).not.toBeNull()
    expect(c.get(id)!.messages[0]!.text).toBe('Keep this')
  })

  it('is never undone: ⌘Z takes back the shape edit, not the comment', () => {
    store.undo.clear()
    store.update('slide1', { title: 'Renamed' }, LOCAL)
    store.undo.stopCapturing()
    const id = c.create('slide1', 'Love the new title', BOB)
    store.undo.stopCapturing()
    c.reply(id, 'Thanks', ADA)
    store.undo.undo()
    expect(store.get('slide1')!.title).toBe('Slide 1 — Why now')
    expect(c.get(id)!.messages).toHaveLength(2)
    expect(store.undo.canUndo()).toBe(false)
  })

  it('tells subscribers only when a thread changes, with a new list each time', () => {
    let calls = 0
    const off = c.subscribe(() => calls++)
    const before = c.getThreads()
    const id = c.create('slide1', 'One', ADA)
    expect(calls).toBe(1)
    const afterCreate = c.getThreads()
    expect(afterCreate).not.toBe(before)
    c.reply(id, 'Two', BOB)
    expect(calls).toBe(2)
    expect(c.getThreads()[0]!.messages).toHaveLength(2)
    store.update('slide1', { title: 'Shape edits are not comment changes' }, LOCAL)
    expect(calls).toBe(2)
    off()
  })

  it('reads threads tolerantly (plain message lists, junk, missing fields)', () => {
    const map = doc.getMap<unknown>(COMMENTS_KEY)
    doc.transact(() => {
      const t = new Y.Map<unknown>()
      t.set('anchor', 'n1')
      t.set('messages', [{ id: 'm1', by: 'Agent', at: 5, text: 'plain' }, { nope: true }, { id: 'm1', text: 'dup' }])
      map.set('t-plain', t)
      map.set('junk', 'not a thread')
      const noAnchor = new Y.Map<unknown>()
      noAnchor.set('messages', new Y.Array())
      map.set('no-anchor', noAnchor)
    })
    const t = c.get('t-plain')!
    expect(t).toMatchObject({ anchor: 'n1', by: 'Agent', at: 5, resolved: false })
    expect(t.messages.map(m => m.text)).toEqual(['plain'])
    expect(readThread('junk', map.get('junk'))).toBeNull()
    expect(c.get('no-anchor')).toBeNull()
    expect(c.getThreads().map(x => x.id)).toEqual(['t-plain'])
    // A reply converts the plain list once, keeping what was there.
    c.reply('t-plain', 'converted', ADA)
    expect(c.get('t-plain')!.messages.map(m => m.text)).toEqual(['plain', 'converted'])
  })

  it('names shapes the way a heading would', () => {
    expect(shapeLabel(store.get('slide1')!)).toBe('Slide 1 — Why now')
    expect(shapeLabel(store.get('n1')!)).toBe('Risks')
    expect(shapeLabel({ type: 'frame', title: '', text: '', label: '', url: '' })).toBe('Frame')
    expect(shapeLabel({ type: 'image', title: '', text: '', label: '', url: '' })).toBe('Image')
    expect(shapeLabel({ type: 'link', title: '', text: '', label: '', url: 'https://a.dev/' })).toBe('https://a.dev/')
  })

  it('says how long ago briefly', () => {
    const now = new Date(2026, 9, 12, 15, 0).getTime()
    expect(agoLabel(now - 10_000, now)).toBe('now')
    expect(agoLabel(now - 5 * 60_000, now)).toBe('5 min')
    expect(agoLabel(now - 3 * 3_600_000, now)).toBe('3 h')
    expect(agoLabel(new Date(2026, 9, 11, 9, 0).getTime(), now)).toBe('Yesterday')
  })
})

describe('two Coppers at once', () => {
  it('a thread started on one shows on the other', () => {
    const { a, b } = pair()
    a.create({ type: 'frame', id: 'f', x: 0, y: 0, w: 1600, h: 900, title: 'The Orb' }, LOCAL)
    const id = a.comments.create('f', 'Thoughts?', ADA)
    expect(b.comments.get(id)!.messages[0]!.text).toBe('Thoughts?')
    expect(b.comments.getThreads().map(t => t.id)).toEqual([id])
  })

  it('two people replying at the same moment both land, in the same order everywhere', () => {
    const { a, b, sync } = apart()
    const id = a.comments.create('f', 'Opening', ADA, { now: 1 })
    sync()
    a.comments.reply(id, 'Ada again', ADA, { now: 2 })
    b.comments.reply(id, 'Bob here', BOB, { now: 2 })
    sync()
    const ta = a.comments.get(id)!.messages.map(m => m.text)
    const tb = b.comments.get(id)!.messages.map(m => m.text)
    expect(ta).toHaveLength(3)
    expect(ta).toEqual(tb)
    expect(new Set(ta)).toEqual(new Set(['Opening', 'Ada again', 'Bob here']))
  })

  it('resolving while someone replies keeps both', () => {
    const { a, b, sync } = apart()
    const id = a.comments.create('f', 'Fix', ADA)
    sync()
    a.comments.setResolved(id, true, ADA, { now: 10 })
    b.comments.reply(id, 'Done on my side', BOB, { now: 10, reopen: false })
    sync()
    for (const s of [a, b]) {
      const t = s.comments.get(id)!
      expect(t.resolved).toBe(true)
      expect(t.messages.map(m => m.text)).toEqual(['Fix', 'Done on my side'])
    }
  })

  it('a reply that reopens and a resolve at the same moment agree everywhere, and the reply stays', () => {
    const { a, b, sync } = apart()
    const id = a.comments.create('f', 'Fix', ADA)
    sync()
    a.comments.setResolved(id, true, ADA)
    b.comments.reply(id, 'One more thing', BOB)
    sync()
    expect(a.comments.get(id)!.resolved).toBe(b.comments.get(id)!.resolved)
    expect(a.comments.get(id)!.messages.map(m => m.text)).toEqual(['Fix', 'One more thing'])
  })

  it('an edit and a reply at once both land; a delete racing a reply keeps the reply', () => {
    const { a, b, sync } = apart()
    const id = a.comments.create('f', 'Draft', ADA)
    const first = a.comments.get(id)!.messages[0]!.id
    sync()
    a.comments.edit(id, first, 'Final', ADA)
    b.comments.reply(id, 'Reply', BOB)
    sync()
    expect(b.comments.get(id)!.messages.map(m => m.text)).toEqual(['Final', 'Reply'])
    a.comments.remove(id, first, ADA)
    b.comments.reply(id, 'Another', BOB)
    sync()
    const t = a.comments.get(id)!
    expect(t.messages.map(m => (m.deleted ? '∅' : m.text))).toEqual(['∅', 'Reply', 'Another'])
    expect(isShown(t)).toBe(true)
  })

  it('comment writes and shape edits never collide', () => {
    const { a, b, sync } = apart()
    a.create({ type: 'frame', id: 'f', x: 0, y: 0, w: 1600, h: 900, title: 'Before' }, LOCAL)
    sync()
    const id = a.comments.create('f', 'On the frame', ADA)
    b.update('f', { title: 'After', x: 40 }, LOCAL)
    sync()
    expect(a.get('f')).toMatchObject({ title: 'After', x: 40 })
    expect(b.comments.get(id)!.anchor).toBe('f')
  })

  it('travels in a stored state: what the host keeps and the cloud snapshots', () => {
    const id = c.create('slide1', 'Persist me', ADA)
    c.reply(id, 'And me', BOB)
    c.setResolved(id, true, BOB)
    const copy = new CanvasStore(new Y.Doc())
    Y.applyUpdate(copy.doc, Y.encodeStateAsUpdate(doc))
    const t = copy.comments.get(id)!
    expect(t.resolved).toBe(true)
    expect(t.messages.map(m => m.text)).toEqual(['Persist me', 'And me'])
  })
})

describe('pins and search', () => {
  it('puts one pin per shape with open threads, at its top-right corner, the same size at any zoom', () => {
    const t1 = c.create('slide1', 'a', ADA, { now: 1 })
    c.create('slide1', 'b', BOB, { now: 2 })
    const t3 = c.create('n1', 'c', ADA, { now: 3 })
    c.setResolved(t3, true, ADA)
    const boundsOf = (id: string) => store.get(id) ?? null
    const at = (z: number) =>
      pinPlaces({ threads: c.getThreads(), boundsOf, toScreen: p => ({ x: p.x * z, y: p.y * z + 100 }), size: { w: 4000, h: 2000 }, focus: null })
    const pins = at(0.5)
    expect(pins).toHaveLength(1)
    expect(pins[0]).toMatchObject({ anchor: 'slide1', x: 803, y: 100 - 3 - 22 })
    expect(pins[0]!.threads.map(t => t.id)[0]).toBe(t1)
    expect(at(1)[0]).toMatchObject({ x: 1603, y: 75 })
    // The resolved one shows while it is the open thread.
    const open = pinPlaces({ threads: c.getThreads(), boundsOf, toScreen: p => p, size: { w: 4000, h: 2000 }, focus: { kind: 'thread', id: t3 } })
    expect(open.map(p => p.anchor).sort()).toEqual(['n1', 'slide1'])
    // A shape being commented on for the first time gets a pin of its own.
    const fresh = pinPlaces({ threads: [], boundsOf, toScreen: p => p, size: { w: 4000, h: 2000 }, focus: { kind: 'new', anchor: 'n1' } })
    expect(fresh).toMatchObject([{ anchor: 'n1', threads: [] }])
    // Deleted shapes have no pin.
    store.remove(['slide1'], LOCAL)
    expect(pinPlaces({ threads: c.getThreads(), boundsOf: id => store.get(id) ?? null, toScreen: p => p, size: { w: 4000, h: 2000 }, focus: null })).toEqual([])
  })

  it('finds comments by what was said, ranked after shapes', () => {
    const id = c.create('slide1', 'The supply numbers are stale', ADA)
    const reply = c.reply(id, 'Updated from InvenTree', BOB)
    const items = commentSearchItems(c.getThreads(), store.getShapes())
    expect(items).toEqual([{ ref: `comment:${id}`, kind: 'comment', text: 'The supply numbers are stale\nUpdated from InvenTree', by: 'Ada Lovelace', at: { x: 0, y: 0 } }])
    const hits = searchIndex(indexSearchItems([{ ref: 'n1', kind: 'sticky', text: '## Risks\nsupply' }, ...items]), 'supply')
    expect(hits.map(h => h.ref)).toEqual(['n1', `comment:${id}`])
    c.remove(id, reply, BOB)
    expect(searchIndex(indexSearchItems(commentSearchItems(c.getThreads(), store.getShapes())), 'inventree')).toEqual([])
  })
})

describe('undoing a delete', () => {
  it('brings your own message back in its place, and only yours', () => {
    const id = c.create('slide1', 'Opening', ADA, { now: 1 })
    const reply = c.reply(id, 'Oops, not this', BOB, { now: 2 })
    c.reply(id, 'After', ADA, { now: 3 })
    c.remove(id, reply, BOB)
    expect(c.get(id)!.lastAt).toBe(3)
    expect(c.restore(id, reply, 'Oops, not this', ADA)).toBe(false)
    expect(c.restore(id, reply, 'Oops, not this', BOB)).toBe(true)
    expect(c.get(id)!.messages.map(m => [m.text, !!m.deleted])).toEqual([
      ['Opening', false],
      ['Oops, not this', false],
      ['After', false],
    ])
  })
})
