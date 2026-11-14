// ux-ocr: every line of text Vision finds in each PNG, with its box (pixels,
// top-left origin), and the WCAG contrast of its ink against its ground.
//   swiftc -O ocr.swift -o ux-ocr && ux-ocr a.png b.png > ocr.jsonl
// Ground = the commonest colour in the line's box (text covers far less than
// half of it); ink = the mean of the 10% of pixels furthest from that ground
// in luminance. Approximate on gradients and glass, exact on flat fills.
import AppKit
import Vision

func lum(_ r: Double, _ g: Double, _ b: Double) -> Double {
    func c(_ v: Double) -> Double { let s = v / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
    return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b)
}
func hex(_ p: (Double, Double, Double)) -> String { String(format: "#%02x%02x%02x", Int(p.0), Int(p.1), Int(p.2)) }

for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("unreadable \(path)\n".data(using: .utf8)!); continue
    }
    let W = image.width, H = image.height
    var px = [UInt8](repeating: 0, count: W * H * 4)
    let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.004
    try? VNImageRequestHandler(cgImage: image).perform([request])
    var lines: [[String: Any]] = []
    for o in request.results ?? [] {
        guard let top = o.topCandidates(1).first else { continue }
        let b = o.boundingBox  // normalised, bottom-left origin
        let x0 = max(0, Int(b.minX * Double(W))), x1 = min(W, Int(b.maxX * Double(W)))
        let y0 = max(0, Int((1 - b.maxY) * Double(H))), y1 = min(H, Int((1 - b.minY) * Double(H)))
        guard x1 > x0 + 1, y1 > y0 + 1 else { continue }
        var counts: [Int: Int] = [:]
        var pixels: [(Double, Double, Double)] = []
        pixels.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { for x in x0..<x1 {
            let i = (y * W + x) * 4  // the context's row 0 is the image's top row
            let p = (Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
            pixels.append(p)
            counts[(Int(p.0) >> 3) << 10 | (Int(p.1) >> 3) << 5 | (Int(p.2) >> 3), default: 0] += 1
        } }
        let mode = counts.max { $0.value < $1.value }!.key
        let bgSet = pixels.filter { ((Int($0.0) >> 3) << 10 | (Int($0.1) >> 3) << 5 | (Int($0.2) >> 3)) == mode }
        let bg = bgSet.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
        let n = Double(bgSet.count)
        let bgc = (bg.0 / n, bg.1 / n, bg.2 / n)
        let lb = lum(bgc.0, bgc.1, bgc.2)
        let far = pixels.map { (p: $0, d: abs(lum($0.0, $0.1, $0.2) - lb)) }.sorted { $0.d > $1.d }.prefix(max(1, pixels.count / 10))
        let ink = far.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.p.0, $0.1 + $1.p.1, $0.2 + $1.p.2) }
        let m = Double(far.count)
        let fg = (ink.0 / m, ink.1 / m, ink.2 / m)
        let lf = lum(fg.0, fg.1, fg.2)
        let ratio = (max(lf, lb) + 0.05) / (min(lf, lb) + 0.05)
        lines.append(["t": top.string, "c": (Double(top.confidence) * 100).rounded() / 100,
                      "x": x0, "y": y0, "w": x1 - x0, "h": y1 - y0,
                      "fg": hex(fg), "bg": hex(bgc), "cr": (ratio * 100).rounded() / 100])
    }
    let row: [String: Any] = ["file": (path as NSString).lastPathComponent, "w": W, "h": H, "lines": lines]
    print(String(data: try! JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
}
