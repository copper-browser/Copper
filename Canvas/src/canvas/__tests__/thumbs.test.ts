import { describe, expect, it } from 'vitest'
import { ThumbCache } from '../thumbs'

const thumb = (url: string, bytes = 100) => ({ url, bytes })

describe('downscaled copies of images', () => {
  it('answers undefined until made, the copy once made, and null for a source that can’t be copied', () => {
    const c = new ThumbCache()
    expect(c.get('data:a', 96)).toBeUndefined()
    c.set('data:a', 96, thumb('blob:a96'))
    expect(c.get('data:a', 96)).toEqual(thumb('blob:a96'))
    c.set('data:b', 96, null)
    expect(c.get('data:b', 96)).toBeNull()
    expect(c.failed('data:b')).toBe(true)
    expect(c.failed('data:a')).toBe(false)
  })

  it('uses the smallest copy at least as wide as asked for', () => {
    const c = new ThumbCache()
    c.set('s', 384, thumb('blob:384'))
    c.set('s', 768, thumb('blob:768'))
    expect(c.best('s', 96)).toBe('blob:384')
    expect(c.best('s', 384)).toBe('blob:384')
    expect(c.best('s', 768)).toBe('blob:768')
    c.set('t', 96, thumb('blob:t96'))
    expect(c.best('t', 192)).toBeNull()
    expect(c.best('nope', 96)).toBeNull()
  })

  it('keeps decoded bytes under budget, oldest first, revoking what it lets go and telling the views', () => {
    const revoked: string[] = []
    const c = new ThumbCache(250, url => revoked.push(url))
    let told = 0
    c.subscribe('a', () => told++)
    c.set('a', 96, thumb('blob:a'))
    c.set('b', 96, thumb('blob:b'))
    c.touch('a', 96)
    c.set('c', 96, thumb('blob:c'))
    expect(revoked).toEqual(['blob:b'])
    expect(c.get('b', 96)).toBeUndefined()
    expect(c.bytes).toBe(200)
    c.set('d', 96, thumb('blob:d'))
    expect(revoked).toEqual(['blob:b', 'blob:a'])
    expect(told).toBe(2)
  })

  it('replacing a copy revokes the old one', () => {
    const revoked: string[] = []
    const c = new ThumbCache(1000, url => revoked.push(url))
    c.set('a', 96, thumb('blob:1'))
    c.set('a', 96, thumb('blob:2'))
    expect(revoked).toEqual(['blob:1'])
    expect(c.bytes).toBe(100)
  })

  it('stands a smaller copy in for a vector image being zoomed into', () => {
    const c = new ThumbCache()
    c.set('v', 384, thumb('blob:384'))
    c.set('v', 1024, thumb('blob:1024'))
    expect(c.bestOrSmaller('v', 768)).toBe('blob:1024')
    expect(c.bestOrSmaller('v', 2048)).toBe('blob:1024')
    expect(c.bestOrSmaller('v', 96)).toBe('blob:384')
    expect(c.bestOrSmaller('none', 96)).toBeNull()
    expect(c.has('v', 384)).toBe(true)
    expect(c.has('v', 768)).toBe(false)
  })

  it('marks the copy a view shows as recently used, by its URL', () => {
    const revoked: string[] = []
    const c = new ThumbCache(250, url => revoked.push(url))
    c.set('a', 96, thumb('blob:a'))
    c.set('b', 96, thumb('blob:b'))
    c.touchUrl('a', 'blob:a')
    c.set('c', 96, thumb('blob:c'))
    expect(revoked).toEqual(['blob:b'])
  })
})
