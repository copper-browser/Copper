import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import UniformTypeIdentifiers

// The Recovery Kit: the 24 words on one US Letter page with a QR code of
// them, or as plain text. Losing every Mac and the kit loses the synced data
// — there is no reset by email, because there is no one to email.

enum SyncKit {
    static let fileName = "Copper Recovery Kit"

    static func text(_ words: [String], folder: URL, date: Date = Date()) -> String {
        var out = "Copper Recovery Kit\n\n"
        out += "Your recovery phrase for Copper's iCloud sync. Enter it on another Mac in Settings › Cloud › iCloud sync › Enter Recovery Phrase.\n"
        out += "Anyone with these words can read what Copper syncs. Keep them somewhere safe and private.\n\n"
        for (i, word) in words.enumerated() { out += "\(i + 1). \(word)\n" }
        out += "\nSync folder: \(folder.path)\nMade: \(date.formatted(date: .long, time: .omitted))\n"
        return out
    }

    /// A QR code of the words, `side` points square.
    static func qr(_ words: [String], side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(words.joined(separator: " ").utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let scaled = code.transformed(by: CGAffineTransform(scaleX: side / code.extent.width * 2, y: side / code.extent.height * 2))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    /// One US Letter page.
    static func pdf(_ words: [String], folder: URL, date: Date = Date()) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: fileName] as CFDictionary) else { return Data() }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.translateBy(x: 0, y: box.height)
        context.scaleBy(x: 1, y: -1)

        func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black, width: CGFloat = 512) {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
            ])
            attributed.draw(with: CGRect(x: point.x, y: point.y, width: width, height: 400), options: [.usesLineFragmentOrigin])
        }

        draw("Copper Recovery Kit", at: CGPoint(x: 50, y: 56), size: 26, weight: .semibold)
        draw("Your Recovery Kit contains all you need to recover your synced data should you lose access to this Mac. Enter the words on another Mac in Settings › Cloud › iCloud sync › Enter Recovery Phrase, or scan the code.",
             at: CGPoint(x: 50, y: 100), size: 11.5, color: .darkGray)
        draw("Anyone with these words can read what Copper syncs. Keep this page somewhere safe and private.",
             at: CGPoint(x: 50, y: 150), size: 11.5, weight: .medium, color: .black)

        let top: CGFloat = 196
        for (i, word) in words.enumerated() {
            let column = CGFloat(i / 8), row = CGFloat(i % 8)
            let x = 50 + column * 120, y = top + row * 30
            draw(String(format: "%2d", i + 1), at: CGPoint(x: x, y: y + 2), size: 10, color: .gray, width: 24)
            draw(word, at: CGPoint(x: x + 24, y: y), size: 14, weight: .medium, width: 100)
        }
        if let code = qr(words, side: 150) {
            code.draw(in: CGRect(x: 412, y: top, width: 150, height: 150), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        draw("Sync folder: \(folder.path)", at: CGPoint(x: 50, y: top + 260), size: 10, color: .darkGray)
        draw("Made \(date.formatted(date: .long, time: .shortened))", at: CGPoint(x: 50, y: top + 280), size: 10, color: .darkGray)

        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Save…: a PDF (or, as text, a .txt) wherever the person says.
    @MainActor
    static func save(_ words: [String], folder: URL, asText: Bool = false) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName + (asText ? ".txt" : ".pdf")
        panel.allowedContentTypes = [asText ? UTType.plainText : UTType.pdf]
        panel.message = "Save a copy somewhere other than this Mac — you'll need it if you lose access to this Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = asText ? Data(text(words, folder: folder).utf8) : pdf(words, folder: folder)
        try? data.write(to: url, options: .atomic)
    }

    /// Copy Words: marked concealed, so clipboard managers leave it out.
    @MainActor
    static func copy(_ words: [String]) {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString(words.joined(separator: " "), forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}
