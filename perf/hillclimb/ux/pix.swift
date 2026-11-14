// ux-pix: the few picture sums the key-window run needs, without ImageMagick.
//   swiftc -O pix.swift -o ux-pix
//   ux-pix diff A B [X Y W H [BAND]]   → {"changed": f}  share of pixels moved > 8% (in pixels of A, top-left
//                                        origin; with BAND only the ring BAND px either side of the box's edge)
//   ux-pix seq A B C …                 → [{"prev": f, "last": f}]  each frame against the one before and the last
//   ux-pix sheet OUT COLS WIDTH A B …  → one PNG: the frames in a grid, each WIDTH px wide, numbered
//   --fuzz N (any command): a channel must move more than N/255 to count (default 20, ~8%)
import AppKit

struct Pic { let w: Int, h: Int, px: [UInt8] }

func load(_ path: String) -> Pic? {
    guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let W = image.width, H = image.height
    var px = [UInt8](repeating: 0, count: W * H * 4)
    let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
    return Pic(w: W, h: H, px: px)
}

var fuzz = 20

func changed(_ a: Pic, _ b: Pic, box: (Int, Int, Int, Int)? = nil, band: Int = 0) -> Double {
    guard a.w == b.w, a.h == b.h else { return 1 }
    let (x0, y0, bw, bh) = box ?? (0, 0, a.w, a.h)
    let ox0 = max(0, x0 - band), oy0 = max(0, y0 - band), ox1 = min(a.w, x0 + bw + band), oy1 = min(a.h, y0 + bh + band)
    var n = 0, moved = 0
    for y in stride(from: oy0, to: oy1, by: 1) {
        for x in stride(from: ox0, to: ox1, by: 1) {
            // BAND: skip the box's inside, keep its edge zone (a focus ring sits on or just outside it).
            if band > 0, x >= x0 + band, x < x0 + bw - band, y >= y0 + band, y < y0 + bh - band { continue }
            let i = (y * a.w + x) * 4
            n += 1
            if max(abs(Int(a.px[i]) - Int(b.px[i])), abs(Int(a.px[i + 1]) - Int(b.px[i + 1])), abs(Int(a.px[i + 2]) - Int(b.px[i + 2]))) > fuzz { moved += 1 }
        }
    }
    return n == 0 ? 0 : Double(moved) / Double(n)
}

func r(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
func out(_ any: Any) {
    let data = try! JSONSerialization.data(withJSONObject: any)
    print(String(data: data, encoding: .utf8)!)
}

var args = Array(CommandLine.arguments.dropFirst())
if let at = args.firstIndex(of: "--fuzz"), at + 1 < args.count {
    fuzz = Int(args[at + 1]) ?? fuzz
    args.removeSubrange(at...(at + 1))
}
switch args.first {
case "diff":
    guard args.count >= 3, let a = load(args[1]), let b = load(args[2]) else { out(["error": "unreadable"]); exit(1) }
    let n = args.dropFirst(3).compactMap { Int($0) }
    out(["changed": r(n.count >= 4 ? changed(a, b, box: (n[0], n[1], n[2], n[3]), band: n.count > 4 ? n[4] : 0) : changed(a, b))])
case "seq":
    let pics = args.dropFirst().map { load($0) }
    guard let last = pics.last ?? nil else { out([]); exit(0) }
    out(pics.enumerated().map { i, p -> [String: Double] in
        guard let p else { return ["prev": 1, "last": 1] }
        let prev = i > 0 ? (pics[i - 1].map { changed($0, p) } ?? 1) : 0
        return ["prev": r(prev), "last": r(changed(p, last))]
    })
case "sheet":
    guard args.count > 4, let cols = Int(args[2]), let width = Int(args[3]) else { print("ux-pix sheet OUT COLS WIDTH A B …"); exit(1) }
    let images = args.dropFirst(4).compactMap { NSImage(contentsOfFile: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    guard let first = images.first else { exit(1) }
    let cellH = width * first.height / max(1, first.width), gap = 6
    let rows = (images.count + cols - 1) / cols
    let W = cols * (width + gap) + gap, H = rows * (cellH + gap) + gap
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (i, image) in images.enumerated() {
        let x = gap + (i % cols) * (width + gap), y = H - (i / cols + 1) * (cellH + gap)
        ctx.draw(image, in: CGRect(x: x, y: y, width: width, height: cellH))
        let label = NSAttributedString(string: " \(i) ", attributes: [.font: NSFont.boldSystemFont(ofSize: 14),
                                                                     .foregroundColor: NSColor.white, .backgroundColor: NSColor.black])
        label.draw(at: NSPoint(x: x + 4, y: y + 4))
    }
    guard let made = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: made).representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: URL(fileURLWithPath: args[1]))
default:
    print("ux-pix diff|seq|sheet — see the top of pix.swift")
    exit(1)
}
