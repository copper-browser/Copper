import SwiftUI
import AppKit

/// One field, in the middle, and the few places it thinks you mean. It takes
/// addresses and only addresses: type something that isn't a place and it
/// shivers and says so, rather than quietly handing your keystrokes to a
/// search engine.
struct Omnibox: View {
    @ObservedObject var browser: Browser
    /// Raised over a page by ⌘L, rather than standing on an empty tab.
    let over: Bool
    /// Fork (new-tab-launcher): what is typed and offered; see `Browser.Field`.
    @ObservedObject private var state: Browser.Field

    @State private var shake: CGFloat = 0
    @State private var refused = false
    @State private var breathing = false

    init(browser: Browser, over: Bool) {
        self.browser = browser
        self.over = over
        _state = ObservedObject(wrappedValue: browser.field)
    }

    @ViewBuilder
    var body: some View {
        // Fork (command-bar-hooks): ⌘K is its own instrument and gets its own
        // card; ⌘L over a page is still upstream's field.
        if browser.summoning {
            CommandPalette(browser: browser, over: over)
        } else {
            plain
        }
    }

    private var plain: some View {
        ZStack {
            if over {
                // The page is still there, just out of the way.
                Rectangle()
                    .fill(Palette.ground.opacity(0.74))
                    .ignoresSafeArea()
                    .onTapGesture { browser.dismiss() }
                    .transition(.opacity)
            }

            VStack(spacing: 8) {
                field
                if !browser.offers.isEmpty { list }
                else if !over { StartCard(browser: browser).padding(.top, 8) } // Fork (first-run)
            }
            .frame(width: Metrics.fieldWidth)
            // Lifted a little above centre: dead centre reads as low, because
            // the strip at the top isn't part of what the eye is measuring.
            .padding(.bottom, 60)
            .animation(Motion.settle, value: browser.offers)
            .animation(Motion.settle, value: refused)
        }
    }

    private var field: some View {
        AddressField(browser: browser)
            .frame(height: 22)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background {
                ZStack {
                    // A slow, almost invisible breath under the field. It is
                    // the only thing on an empty tab, and a thing that never
                    // moves at all reads as a picture of an app rather than
                    // an app.
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Palette.ink.opacity(0.05))
                        .blur(radius: 26)
                        .scaleEffect(breathing ? 1.03 : 0.97)
                        .opacity(breathing ? 1 : 0.65)

                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Palette.ground)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        refused ? Color.red.opacity(0.35) : Palette.hairline,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.06), radius: 24, y: 8)
            .modifier(Shake(travel: shake))
            .onAppear {
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
            .onChange(of: browser.refusals) { _, _ in
                shake = 0
                refused = true
                withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
            }
            .onChange(of: browser.typed) { _, _ in
                withAnimation(Motion.quick) { refused = false }
            }
    }

    /// What it thinks you mean. Places you have been come with their titles;
    /// the handful of well-known addresses it starts life knowing come without
    /// the weight of one.
    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(browser.offers.enumerated()), id: \.element.id) { index, offer in
                Row(offer: offer, picked: browser.picked == index)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.take(offer) }
            }
        }
        .padding(6)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.07), radius: 20, y: 6)
        .transition(.scale(scale: 0.98, anchor: .top).combined(with: .opacity))
    }

    private struct Row: View {
        let offer: Suggestion
        /// Where the arrow keys have walked to. The pointer gets its own,
        /// quieter mark, and changes nothing but the look of the row.
        let picked: Bool

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                switch offer.kind {
                case .search:
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.muted)
                case .bookmark:
                    Image(systemName: "bookmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.muted)
                case .command:
                    Image(systemName: "command")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.muted)
                case .open:
                    // Already open: naming it takes you back to it rather than
                    // opening a second copy.
                    Circle()
                        .fill(Palette.ink.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .padding(.horizontal, 2)
                default:
                    EmptyView()
                }
                Text(offer.key)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)

                if !offer.title.isEmpty {
                    Text(offer.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if picked {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.wash)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.hover)
                }
            }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

/// The field itself, in AppKit.
///
/// SwiftUI's TextField can hold a string and nothing else, and the whole point
/// here is the part you didn't type: the rest of the address, already there and
/// selected, so carrying on typing replaces it and Return accepts it. That
/// needs a real text field and its delegate.
struct AddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    /// Fork (command-bar-hooks): show what was typed and nothing else. The
    /// address field completes as you type and shows the row the arrows have
    /// walked to; a command bar must keep your question on screen while you
    /// walk past six answers to it.
    var literal = false
    var size: CGFloat = 15.5
    var placeholder = "Search or enter address" // Fork (first-run): one wording everywhere
    /// Fork (new-tab-launcher): what is typed and offered; see `Browser.Field`.
    @ObservedObject private var state: Browser.Field

    init(browser: Browser, literal: Bool = false, size: CGFloat = 15.5, placeholder: String = "Search or enter address") {
        self.browser = browser
        self.literal = literal
        self.size = size
        self.placeholder = placeholder
        _state = ObservedObject(wrappedValue: browser.field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: size)
        field.textColor = Palette.NS.ink
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        // SwiftUI picks its own colour for a placeholder, and on a pale ground
        // that colour was near-white.
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: Palette.NS.muted, // Fork (ui-system): was ink at 0.3, ~2:1
            ]
        )
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.literal = literal

        // Only when something other than typing changed it — ⌘L arriving with
        // an address, a walk through the list, a submit clearing it.
        //
        // Comparing against the field's own text instead would undo every
        // backspace: deleting leaves the field shorter than what the browser
        // still considers complete, and the next update would helpfully type
        // it back in. That is a field you cannot shorten, and it reads exactly
        // like one that has stopped responding.
        let want = literal ? browser.typed : browser.completed
        if want != coordinator.synced {
            coordinator.synced = want
            field.stringValue = want
            coordinator.select(from: browser.typed.count, in: field)
        }

        if coordinator.answered != browser.focusRequest {
            coordinator.answered = browser.focusRequest
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                guard let editor = field.currentEditor() as? NSTextView else { return }
                // The system paints selected text as a block of accent colour,
                // which over this pale field is the loudest thing in the
                // window. A tenth of the ink says "selected" quietly enough.
                editor.selectedTextAttributes = [
                    .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                    .foregroundColor: Palette.NS.ink,
                ]
                // Fork: the command bar keeps what you typed and a caret at
                // the end of it. Selecting the whole query would say "type
                // over me", and in ⌘K the query is the thing you are
                // refining, not an address you are replacing.
                if literal { editor.selectedRange = NSRange(location: field.stringValue.count, length: 0) }
                else { editor.selectAll(nil) }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var literal = false
        var answered = -1
        /// The last value pushed in from the browser side, so an update can
        /// tell a change worth applying from one it made itself.
        var synced = ""

        /// A backspace has to be allowed to actually take a letter off. Without
        /// this the field puts the same letter straight back as a completion
        /// and the address can never be shortened.
        private var deleting = false

        init(browser: Browser) {
            self.browser = browser
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let text = field.stringValue

            browser.typed = text
            // Fork (developer-shortcuts): ⌘T and ⌘K keep their ending out of
            // the field, for Tab to take; only the address bar draws it.
            guard !literal, !deleting, let ending = browser.ending else {
                if deleting, !literal { browser.stopCompleting() }
                deleting = false
                synced = literal ? text : browser.completed
                return
            }
            deleting = false

            field.stringValue = text + ending
            synced = field.stringValue
            select(from: text.count, in: field)
        }

        /// The part after the caret, shown as selected, so the next keystroke
        /// replaces it and Return takes it.
        func select(from start: Int, in field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            let length = field.stringValue.count
            guard start <= length else { return }
            editor.selectedRange = NSRange(location: start, length: length - start)
        }

        /// Fork (developer-shortcuts): the completion on offer into the field,
        /// the caret after it.
        @MainActor private func take(into control: NSControl, _ textView: NSTextView) {
            guard browser.acceptCompletion() else { return }
            let text = literal ? browser.typed : browser.completed
            synced = text
            control.stringValue = text
            textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                browser.submit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                browser.walk(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                browser.walk(-1)
                return true
            // Fork (cmdt-sections): on ⌘T's and ⌘K's card, Tab and ⇧Tab jump
            // to the next and previous section (Fork/CardSections), and → at
            // the end of what you typed takes the completion Tab used to.
            case #selector(NSResponder.insertTab(_:)) where browser.summoning:
                browser.jumpSection(1)
                return true
            case #selector(NSResponder.insertBacktab(_:)) where browser.summoning:
                browser.jumpSection(-1)
                return true
            case #selector(NSResponder.moveRight(_:)) where browser.summoning,
                 #selector(NSResponder.scrollToEndOfDocument(_:)) where browser.summoning,
                 #selector(NSResponder.moveToEndOfDocument(_:)) where browser.summoning:
                let caret = textView.selectedRange()
                guard !textView.hasMarkedText(), caret.length == 0,
                      caret.location == (textView.string as NSString).length else { return false }
                take(into: control, textView)
                return true
            // Fork (developer-shortcuts): Tab takes what the field is
            // offering and leaves the caret after it — no page opens, no tab
            // changes. With nothing on offer, Tab and ⇧Tab do nothing here
            // rather than throw the keyboard somewhere unexpected.
            case #selector(NSResponder.insertTab(_:)):
                take(into: control, textView)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)):
                deleting = true
                return false
            default:
                return false
            }
        }
    }
}
