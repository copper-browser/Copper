import Combine
import Foundation

// The first second, given to the page you came back to.
//
// `settled` is true once the first page has drawn (or 1.5 s have passed,
// whichever is first). Work the first frames don't need waits for it instead
// of competing with the restored page (which starts loading during the
// restore, in the Room — Fork/SpaceWarm.swift): the animated backdrop's scene,
// a second content process running three.js and WebGL; Bitwarden's first look
// at the vault, two or three Node processes and then the whole vault decoded
// on the main thread; and the other spaces' pages (SpaceWarm).
//
// `dressed` comes earlier: the column's rows, the space strip and its icons
// wait for the restored page's first paint (or 0.2 s after the window, if
// there is none). Drawn in the launch's first pass they kept the main thread
// ~300 ms, and the page's own first question to the app (whether to load at
// all, Browser.decidePolicyFor) waited behind them; now the window goes up
// with the page and an empty column of the same width, and the page asks
// before the rows are built (ContentView).
@MainActor
final class Launch: ObservableObject {
    static let shared = Launch()

    @Published private(set) var settled = false
    @Published private(set) var dressed = false
    private var waiting: [() -> Void] = []

    private init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.settle() }
    }

    /// A page has drawn (or finished): the launch has had what it needed.
    func pageShown() {
        dress()
        guard !settled else { return }
        // A beat for the page's own next frames before anything else starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.settle() }
    }

    /// The window's first appearance: the column follows in 0.2 s at the
    /// latest, for a launch whose page never paints (a blank tab).
    func windowShown() {
        guard !dressed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.dress() }
    }

    private func dress() {
        guard !dressed else { return }
        dressed = true
        Pace.mark("dressed")
    }

    /// Now if the launch has settled, else as soon as it does.
    func whenSettled(_ work: @escaping () -> Void) {
        if settled { work() } else { waiting.append(work) }
    }

    private func settle() {
        guard !settled else { return }
        settled = true
        dress()
        Pace.mark("settled")
        let work = waiting
        waiting = []
        work.forEach { $0() }
    }
}
