import Foundation

// What was open last time. A list of addresses and their names, and which one
// you were looking at — nothing else, because everything else is either on the
// page or in the history file next door.

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
        var space: UUID? = nil
        var active: Bool? = nil
        var group: UUID? = nil // Fork: tab groups
        var saved: Bool? = nil // Fork: sections — nil means saved, so upstream's files restore whole
        var seen: Double? = nil // Fork: sections — when it was last looked at, Unix seconds
        var split: UUID? = nil // Fork: split view — both halves of a kept split carry the same token
        var mb: Int? = nil // Fork (covers): a pin's page's last weight, MB — whether it may stay asleep next launch
        var dozed: Bool? = nil // Fork (covers): a pin asleep under "Let big pins sleep" when the session was written
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
        var spaces: [Space]? = nil
        var space: UUID? = nil
        /// Fork: global pins — one ordered set shown in every space, not
        /// part of any row. Optional, so a file from an older build reads.
        var pins: [Entry]? = nil

        /// How many tabs this is. With `pins`, the pinned entries in `tabs`
        /// are only the older builds' copy of them (Spaces.shape), so they
        /// are not counted twice.
        var tabCount: Int { pins.map { $0.count + tabs.filter { $0.pin == nil }.count } ?? tabs.count }
    }

    private static var file: URL { Store.file("session.json") }

    static func read() -> Shape {
        guard let data = try? Data(contentsOf: file) else { return Shape(tabs: [], active: 0) }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else {
            // A file that's there but won't decode is not the same as no
            // file: something wrote it, and overwriting it on the next save
            // without a trace is how yesterday's tabs actually disappear.
            Store.quarantine(file)
            return Shape(tabs: [], active: 0)
        }
        return shape
    }

    /// `now` writes on the calling thread. Quitting doesn't wait for a
    /// background queue, and a session handed to one on the way out is a
    /// session that may never reach the disk.
    static func write(now: Bool = false, _ shape: Shape) {
        let file = Session.file
        let put = {
            guard let data = try? JSONEncoder().encode(shape) else { return }
            _ = SessionGuard.write(data, tabCount: shape.tabCount, file: file)
        }
        if now {
            put()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: put)
        }
    }
}
