/**
 * Who a checklist row can be assigned to, as the picker lists them: the
 * people on the canvas (the same list chat's @ picker shows — you among them,
 * first), then names already used on this board's checklists that are nobody
 * on it (a canvas on this Mac has only those), then, while you type a name
 * nobody has, that name itself. Pure: the picker and its tests share it.
 */
import { assigneeName } from './checklist-text'
import { samePerson } from './checklist'
import { stableColor } from './chat/model'
import type { ChecklistAssignee, Shape } from './types'

export interface AssignOption {
  /** Unique in the list. */
  key: string
  name: string
  id?: string
  email?: string
  color: string
  /** You. */
  me?: boolean
  /** A name being typed that nobody has yet. */
  fresh?: boolean
}

const fold = (s: string) => s.trim().toLowerCase()

/** An avatar's colour: Copper's colour for the person (their id), else for the name. */
export const personColor = (p: { id?: string; name: string }) => stableColor(p.id || fold(p.name) || '?')

/** Everyone named on this board's checklists, each once (by id, else name), in board order. */
export function boardAssignees(shapes: Iterable<Shape>): ChecklistAssignee[] {
  const out: ChecklistAssignee[] = []
  for (const s of shapes) {
    for (const list of Object.values(s.assignees ?? {}))
      for (const p of list) if (!out.some(o => samePerson(o, p))) out.push({ name: p.name, ...(p.id ? { id: p.id } : {}), ...(p.email ? { email: p.email } : {}) })
  }
  return out
}

/** How well a person matches what is typed: name start, word start, email start, anywhere; -1 for not at all. */
function score(p: { name: string; email?: string }, q: string): number {
  if (!q) return 1
  const name = p.name.toLowerCase()
  const email = (p.email ?? '').toLowerCase()
  if (name.startsWith(q)) return 5
  if (name.split(/[\s._-]+/).some(w => w.startsWith(q))) return 4
  if (email.startsWith(q)) return 3
  if (name.includes(q)) return 2
  if (email.includes(q)) return 1
  return -1
}

/**
 * The picker's list for `query`: people on the canvas (you first when
 * nothing is typed), then other names from the board, best match first;
 * then the typed name itself when nobody listed has it. At most `limit`.
 */
export function assignOptions(
  people: readonly { id: string; name: string; email?: string; color?: string }[],
  board: readonly ChecklistAssignee[],
  query: string,
  me: string | null,
  limit = 8
): AssignOption[] {
  const q = fold(query.replace(/^@+/, ''))
  const all: (AssignOption & { score: number; rank: number })[] = []
  people.forEach((p, i) => {
    const s = score(p, q)
    if (s < 0) return
    const mine = !!me && p.id === me
    all.push({
      key: `id:${p.id}`,
      name: p.name,
      id: p.id,
      ...(p.email ? { email: p.email } : {}),
      color: p.color || personColor(p),
      ...(mine ? { me: true } : {}),
      score: s,
      // You lead the list until something is typed; then the best match does.
      rank: !q && mine ? -1 : i,
    })
  })
  board.forEach((p, i) => {
    if (all.some(o => samePerson(o, p)) || people.some(o => samePerson(o, p))) return
    const s = score(p, q)
    if (s < 0) return
    all.push({ key: p.id ? `id:${p.id}` : `name:${fold(p.name)}`, ...p, color: personColor(p), score: s - 0.5, rank: people.length + i })
  })
  all.sort((a, b) => (q ? b.score - a.score : 0) || a.rank - b.rank)
  const out: AssignOption[] = all.slice(0, limit).map(({ score: _s, rank: _r, ...o }) => o)
  const typed = assigneeName(query)
  if (typed && !all.some(o => fold(o.name) === fold(typed) || (!!o.email && fold(o.email) === fold(typed))))
    out.push({ key: `new:${fold(typed)}`, name: typed, color: personColor({ name: typed }), fresh: true, ...(typed.includes('@') && !/\s/.test(typed) ? { email: typed } : {}) })
  return out
}
