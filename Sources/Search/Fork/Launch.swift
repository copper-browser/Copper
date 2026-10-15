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
@MainActor
final class Launch: ObservableObject {
    static let shared = Launch()

    @Published private(set) var settled = false
    private var waiting: [() -> Void] = []

    private init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.settle() }
    }

    /// A page has drawn (or finished): the launch has had what it needed.
    func pageShown() {
        guard !settled else { return }
        // A beat for the page's own next frames before anything else starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.settle() }
    }

    /// Now if the launch has settled, else as soon as it does.
    func whenSettled(_ work: @escaping () -> Void) {
        if settled { work() } else { waiting.append(work) }
    }

    private func settle() {
        guard !settled else { return }
        settled = true
        Pace.mark("settled")
        let work = waiting
        waiting = []
        work.forEach { $0() }
    }
}
