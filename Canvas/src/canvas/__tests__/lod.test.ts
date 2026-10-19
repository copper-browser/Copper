import { describe, expect, it } from 'vitest'
import { LOD_BAR_PX, LOD_STEP, LOD_TEXT_PX, THUMB_BUCKETS, VECTOR_BUCKETS, VECTOR_MAX_PIXELS, barWidth, drawnWidth, headingLine, imageBucket, isBarText, isLowText, isVectorSrc, nextLodZoom } from '../lod'
import { STICKY_FONT, TEXT_FONT } from '../types'

describe('text LOD', () => {
  it('simplifies text under 4 screen px, and only then', () => {
    expect(LOD_TEXT_PX).toBe(4)
    // A 16 px note: legible at 0.25 and above.
    expect(isLowText(STICKY_FONT, 0.25)).toBe(false)
    expect(isLowText(STICKY_FONT, 0.24)).toBe(true)
    expect(isLowText(STICKY_FONT, 1)).toBe(false)
    // Bigger text stays itself further out.
    expect(isLowText(TEXT_FONT, 0.21)).toBe(false)
    expect(isLowText(48, 0.1)).toBe(false)
  })

  it('draws lines as bars once even a heading line could not be read', () => {
    expect(LOD_BAR_PX).toBeLessThan(LOD_TEXT_PX)
    // A 16 px note: its heading line from 0.25 down to ≈ 0.156, bars below.
    expect(isBarText(STICKY_FONT, 0.2)).toBe(false)
    expect(isBarText(STICKY_FONT, 0.15)).toBe(true)
    expect(barWidth('abcd', 16, 1000)).toBe(32)
    expect(barWidth('x'.repeat(400), 16, 170)).toBe(170)
    expect(barWidth('', 16, 170)).toBe(0)
  })

  it('moves the LOD zoom down in steps while the view moves, up only once it settles', () => {
    const z = 0.3
    expect(nextLodZoom(z, z * 1.05, false)).toBe(z)
    expect(nextLodZoom(z, z / 1.05, false)).toBe(z)
    const out = z * Math.exp(-LOD_STEP * 1.5)
    expect(nextLodZoom(z, out, false)).toBe(out)
    // Zooming in keeps the cheaper drawing until the gesture ends, or the zoom has doubled.
    expect(nextLodZoom(z, z * 1.9, false)).toBe(z)
    expect(nextLodZoom(z, z * 2.1, false)).toBe(z * 2.1)
    expect(nextLodZoom(z, z * 1.05, true)).toBe(z * 1.05)
    expect(nextLodZoom(z, z * 3, true)).toBe(z * 3)
    expect(nextLodZoom(0, 0.5, false)).toBe(0.5)
  })
})

describe('image LOD', () => {
  it('uses the source until it is drawn at under half its size', () => {
    expect(imageBucket(480, 1600, 1, 2)).toBeNull()
    expect(imageBucket(480, 1600, 0.9, 2)).toBeNull()
  })

  it('picks the smallest bucket that covers the device pixels drawn', () => {
    // 480 world px at 0.1 on a 2x screen: 96 device px.
    expect(imageBucket(480, 1600, 0.1, 2)).toBe(96)
    expect(imageBucket(480, 1600, 0.15, 2)).toBe(192)
    expect(imageBucket(480, 1600, 0.3, 2)).toBe(384)
    expect(imageBucket(480, 4000, 0.75, 2)).toBe(768)
    expect([...THUMB_BUCKETS]).toEqual([96, 192, 384, 768])
  })

  it('never makes a copy that is not much smaller than the source', () => {
    // 384 is needed but the source is 500 wide: not worth a copy.
    expect(imageBucket(480, 500, 0.45, 1)).toBeNull()
    expect(imageBucket(480, 0, 0.1, 2)).toBeNull()
    expect(imageBucket(0, 1000, 0.1, 2)).toBeNull()
  })

  it('knows how wide cover and contain lay an image out', () => {
    // A square picture in a wide box: cover fills the width, contain the height.
    expect(drawnWidth(400, 200, 1000, 1000, 'cover')).toBe(400)
    expect(drawnWidth(400, 200, 1000, 1000, 'contain')).toBe(200)
    // A wide picture in a square box: cover is wider than the box.
    expect(drawnWidth(200, 200, 2000, 1000, 'cover')).toBe(400)
    expect(drawnWidth(200, 200, 0, 0, 'cover')).toBe(200)
  })
})

describe('the heading line', () => {
  it('is the first line with text, markdown marks off', () => {
    expect(headingLine('# Q3 plan\n- ship')).toEqual({ text: 'Q3 plan', heading: true })
    expect(headingLine('\n\n**Launch** checklist\n- [ ] bridge')).toEqual({ text: 'Launch checklist', heading: false })
    expect(headingLine('- [x] done thing')).toEqual({ text: 'done thing', heading: false })
    expect(headingLine('1. sketch')).toEqual({ text: 'sketch', heading: false })
    expect(headingLine('see [the docs](https://x.y) _now_')).toEqual({ text: 'see the docs now', heading: false })
    expect(headingLine('   \n')).toEqual({ text: '', heading: false })
    expect(headingLine('x'.repeat(500)).text).toHaveLength(140)
  })
})

describe('vector images', () => {
  it('knows an SVG source from its head or its path, without reading a whole data: URL', () => {
    expect(isVectorSrc('data:image/svg+xml;base64,PHN2Zz4=')).toBe(true)
    expect(isVectorSrc('data:image/svg+xml,%3Csvg%3E')).toBe(true)
    expect(isVectorSrc('data:image/png;base64,' + 'A'.repeat(100) + '.svg')).toBe(false)
    expect(isVectorSrc('https://example.com/art/card.svg?v=2')).toBe(true)
    expect(isVectorSrc('https://example.com/svg/photo.jpg')).toBe(false)
    expect(isVectorSrc(undefined)).toBe(false)
  })

  it('always draws a bitmap copy, at the smallest bucket covering the device pixels shown', () => {
    // A 447-wide card at 1× zoom on a 2× screen: 894 device px → the 1024 copy.
    expect(imageBucket(447, 447, 1, 2, true, 1.5)).toBe(1024)
    // Even when shown at its own size or bigger (a bitmap would draw its source).
    expect(imageBucket(447, 447, 2, 2, true, 1.5)).toBe(2048)
    expect(imageBucket(447, 447, 0.1, 2, true, 1.5)).toBe(96)
    // Steps of about √2: 390 px wanted is a 512 copy, not 768.
    expect(imageBucket(447, 447, 0.436, 2, true, 1.5)).toBe(512)
    for (let i = 1; i < VECTOR_BUCKETS.length; i++) expect(VECTOR_BUCKETS[i]! / VECTOR_BUCKETS[i - 1]!).toBeLessThanOrEqual(1.5)
    for (const b of THUMB_BUCKETS) expect(VECTOR_BUCKETS).toContain(b)
  })

  it('keeps a copy under the pixel cap; a card is stretched at most 1.5× before its source is drawn', () => {
    // A 4000×8400 backdrop at 0.44× on 2×: 3520 px wanted, but 16 MP caps it at ≈ 2760 → the 2048 copy is too soft.
    const tall = 8400 / 4000
    expect(Math.floor(Math.sqrt(VECTOR_MAX_PIXELS / tall))).toBeLessThan(3072)
    // Held back by the pixel cap, it stays a (softer) bitmap rather than megapixels of vector.
    expect(imageBucket(4000, 4000, 0.44, 2, true, tall)).toBe(2048)
    expect(imageBucket(4000, 4000, 1, 2, true, tall)).toBe(2048)
    expect(imageBucket(4000, 4000, 0.25, 2, true, tall)).toBe(2048)
    // A 1384-wide hero at 2.5× zoom on 2×: 6920 px wanted, 4096 is the biggest copy → the source.
    expect(imageBucket(1384, 1384, 2.5, 2, true, 0.4)).toBeNull()
    expect(imageBucket(1384, 1384, 2, 2, true, 0.4)).toBe(4096)
    expect(imageBucket(1384, 1384, 1.4, 2, true, 0.4)).toBe(4096)
  })
})

