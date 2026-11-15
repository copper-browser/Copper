import AppKit
import CryptoKit
import ImageIO

// Fork (covers, hill-climb r5): a page's last picture, kept on disk.
//
// A tab that wakes shows the picture it went to sleep with while its page is
// rebuilt underneath (Tab.wake, "wake-cover"). That picture lived in memory
// only, so it never outlived a launch: every space's page after a launch —
// and every pin, every restored tab — came back as a blank card until the
// page painted, half a second and more on a real site (B3/B14: "space switch
// lands white").
//
// So the picture is kept: when a tab sleeps (Tab.sleep) and, for every page
// still awake, when Copper quits (`flush`; not in a headless run), as a JPEG of at most 150 KB in
// `covers/` in the world's folder. A tab waking with no picture in memory
// takes the one on disk. Pictures are filed by the page's address, not the
// tab — a tab gets a new id every launch, its address is what the session
// keeps — so two tabs on one page share one. Council R6 (privacy): filed by
// the page's cookie jar too (`Tab.jar`: the shared one or a space's profile),
// so a profile signed in as someone else never opens on your inbox's picture;
// pictures from before that (no jar in the name) are deleted at launch
// (`Covers.start`). A tab closed for good takes its
// picture with it (unless another tab is on that page); past 100 MB the
// pictures not looked at longest go first. Private (shy) and bench tabs never
// leave one.
struct CoverStore {
    let folder: URL
    /// What every picture together may take on disk.
    var cap = 100 * 1_048_576
    /// What one picture may take.
    var most = 150 * 1024

    /// What came off disk: the picture at the size in points it was taken
    /// at, and the page's ground colour read off it (Tab.ground).
    struct Kept: @unchecked Sendable { // made on the read queue, then only read on main
        let image: NSImage
        let ground: NSColor?
    }

    /// `<jar>-<page>.jpg`: hashes of the cookie jar and of the address.
    func file(for url: URL, jar: String) -> URL {
        func hex(_ text: String, _ n: Int) -> String {
            SHA256.hash(data: Data(text.utf8)).prefix(n).map { String(format: "%02x", $0) }.joined()
        }
        return folder.appendingPathComponent(hex(jar, 6) + "-" + hex(url.absoluteString, 16) + ".jpg")
    }

    /// The pictures filed before they carried their jar: anyone's, so gone.
    func purgeUnscoped() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "jpg" && !url.lastPathComponent.contains("-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// `jpeg` (any size, any quality) kept for `url`: made to fit `most`,
    /// written, and the oldest pictures let go past `cap`. Synchronous: the
    /// shared store runs it on its own queue (`Covers.save`).
    @discardableResult
    func write(_ jpeg: Data, size: CGSize, ground: NSColor?, for url: URL, jar: String) -> Bool {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return write(image, size: size, ground: ground, for: url, jar: jar)
    }

    @discardableResult
    func write(_ image: CGImage, size: CGSize, ground: NSColor?, for url: URL, jar: String) -> Bool {
        guard let data = CoverStore.fit(image, size: size, ground: ground, most: most) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? data.write(to: file(for: url, jar: jar), options: .atomic)) != nil else { return false }
        evict()
        return true
    }

    /// The picture kept for `url`, marked as just used (the eviction's clock),
    /// decoded here and now (`ShouldCacheImmediately`): the covers' read
    /// queue runs it, so a wake's main thread only attaches what came back.
    func read(for url: URL, jar: String) -> Kept? {
        let path = file(for: url, jar: jar)
        guard let data = try? Data(contentsOf: path), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
        let said = CoverStore.said(in: source)
        let size = said.size.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: image.width, height: image.height)
        return Kept(image: NSImage(cgImage: image, size: size), ground: said.ground)
    }

    func remove(for url: URL, jar: String) {
        try? FileManager.default.removeItem(at: file(for: url, jar: jar))
    }

    /// Everything, for Clear browsing data.
    func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Past `cap`, the pictures used longest ago go until the rest fit.
    func evict() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var rows = files.compactMap { url -> (url: URL, at: Date, bytes: Int)? in
            guard url.pathExtension == "jpg", let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = rows.reduce(0) { $0 + $1.bytes }
        guard total > cap else { return }
        rows.sort { $0.at < $1.at }
        for row in rows where total > cap {
            try? FileManager.default.removeItem(at: row.url)
            total -= row.bytes
        }
    }

    /// The bytes on disk now.
    var bytes: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: - the file

    /// A JPEG of at most `most` bytes, with the picture's size in points and
    /// its ground written into its Exif comment. Full size first; then, on a
    /// Retina picture, at one pixel a point; then plainer, until it fits.
    static func fit(_ image: CGImage, size: CGSize, ground: NSColor?, most: Int) -> Data? {
        let points = size.width > 0 && size.height > 0 ? size : CGSize(width: image.width, height: image.height)
        let note = describe(size: points, ground: ground)
        let small = scaled(image, to: points)
        for (picture, quality) in [(image, 0.55), (small, 0.6), (small, 0.4), (small, 0.25)] {
            guard let picture, let data = encode(picture, quality: quality, note: note) else { continue }
            if data.count <= most { return data }
        }
        return nil
    }

    /// "copper-cover 1280x800 #ffffff": the size in points and the ground.
    static func describe(size: CGSize, ground: NSColor?) -> String {
        var note = "copper-cover \(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
        if let rgb = ground?.usingColorSpace(.sRGB) {
            note += String(format: " #%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        }
        return note
    }

    static func said(in data: Data) -> (size: CGSize?, ground: NSColor?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return (nil, nil) }
        return said(in: source)
    }

    static func said(in source: CGImageSource) -> (size: CGSize?, ground: NSColor?) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let note = exif[kCGImagePropertyExifUserComment] as? String, note.hasPrefix("copper-cover ") else { return (nil, nil) }
        let parts = note.split(separator: " ")
        var size: CGSize?
        var ground: NSColor?
        if parts.count > 1 {
            let wh = parts[1].split(separator: "x").compactMap { Double($0) }
            if wh.count == 2 { size = CGSize(width: wh[0], height: wh[1]) }
        }
        if parts.count > 2, parts[2].hasPrefix("#"), let value = Int(parts[2].dropFirst(), radix: 16) {
            ground = NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                             blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        return (size, ground)
    }

    private static func scaled(_ image: CGImage, to points: CGSize) -> CGImage? {
        let width = Int(points.width.rounded()), height = Int(points.height.rounded())
        guard width > 0, height > 0 else { return nil }
        guard width < image.width else { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, quality: Double, note: String) -> Data? {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // The JPEG writer keeps an Exif comment (a TIFF description it drops).
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: note],
        ]
        CGImageDestinationAddImage(out, image, properties as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }
}

/// The world's store, written on a queue of its own.
@MainActor
enum Covers {
    nonisolated static let store = CoverStore(folder: Store.file("covers"))
    nonisolated private static let queue = DispatchQueue(label: "copper.covers", qos: .utility)

    /// Off for `defaults write <domain> covers -bool false`.
    static var on: Bool { Store.settings.object(forKey: "covers") as? Bool ?? true }

    /// Private (shy), bench and non-persistent-jar tabs never leave one.
    static func keeps(_ tab: Tab) -> Bool { on && !tab.shy && !tab.bench && tab.jar != nil }

    static func save(_ jpeg: Data, size: CGSize, ground: NSColor?, for url: URL, jar: String) {
        guard on else { return }
        queue.async { store.write(jpeg, size: size, ground: ground, for: url, jar: jar) }
    }

    /// A picture straight from WebKit (the quit's pass): its ground is read
    /// and it is encoded here, on the covers queue.
    nonisolated static func save(_ image: CGImage, size: CGSize, for url: URL, jar: String) {
        queue.async { store.write(image, size: size, ground: Tab.ground(of: image), for: url, jar: jar) }
    }

    /// Reads (file, decode, the eviction clock) go on a queue of their own,
    /// ahead of the writes: a wake is waiting. A write lands whole (atomic),
    /// so this reads the last picture or the one before, never half of one.
    nonisolated private static let reads = DispatchQueue(label: "copper.covers.read", qos: .userInitiated)

    /// The picture kept for `url` in `jar`, decoded off the main thread;
    /// `done` on main, nil when there is none.
    static func load(for url: URL, jar: String, _ done: @escaping @MainActor (CoverStore.Kept?) -> Void) {
        guard on else { return done(nil) }
        reads.async {
            let kept = store.read(for: url, jar: jar)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(kept) } }
        }
    }

    /// A tab closed for good: its picture goes, unless another tab is on
    /// that page in the same jar.
    static func closed(_ tab: Tab) {
        guard let jar = tab.jar, let url = tab.pending ?? tab.address,
              !AgentTabs.all.contains(where: { $0 !== tab && $0.jar == jar && ($0.pending ?? $0.address) == url }) else { return }
        queue.async { store.remove(for: url, jar: jar) }
    }

    static func clear() { queue.async { store.removeAll() } }

    /// Quitting: every page still awake leaves its picture, so the next
    /// launch opens on it. At most 0.6 s, then whatever is written is what
    /// there is.
    static func flush() {
        guard on else { return }
        let awake = Spaces.shared.everyTab.filter { keeps($0) && $0.built != nil && !$0.asleep && !$0.isBlank }
        var left = awake.count
        for tab in awake { tab.keepCover { left -= 1 } }
        let deadline = Date().addingTimeInterval(0.6)
        while left > 0, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        queue.sync {}
    }

    private static var watching: NSObjectProtocol?

    /// Once, at launch (SpaceWarm.start). Not headless: nobody looks at a
    /// headless window, and the probes that run one take a SIGTERM as ⌘Q and
    /// wipe the world's folder straight after (the pass raced their `rm`).
    static func start() {
        guard watching == nil else { return }
        queue.async { store.purgeUnscoped() } // council R6: pictures from before the jar was in the name
        guard !Headless.on else { return }
        watching = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { flush() }
        }
    }

    /// `bench covers` — how many pictures, how big; `covers flush` the quit's
    /// pass now; `covers clear` (test worlds only).
    static func bench(_ request: [String: Any]) -> [String: Any] {
        switch request["op"] as? String ?? "status" {
        case "flush":
            let started = Date()
            flush()
            return ["flushed": true, "ms": Int(Date().timeIntervalSince(started) * 1000), "bytes": store.bytes]
        case "clear":
            guard Store.testing else { return ["error": "covers clear only works in a test world"] }
            queue.sync { store.removeAll() }
            return ["cleared": true]
        default:
            let files = (try? FileManager.default.contentsOfDirectory(atPath: store.folder.path))?.filter { $0.hasSuffix(".jpg") } ?? []
            return ["on": on, "files": files.count, "bytes": store.bytes, "folder": store.folder.path]
        }
    }
}
