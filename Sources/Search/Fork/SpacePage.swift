import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Settings › Spaces: every space, and everything about the one picked.
//
// The editor used to be a 296pt popover off the header or a chip, then a
// 660pt card of its own over the window. Collin wanted it where every other
// setting is, so it is a page of Settings now: the spaces across the top to
// pick one (drag to reorder), and under it the one picked — a live column
// drawn with the space's real `SpaceTint` beside its name, look and profile,
// then the icon, colours, picture or scene, the sliders and Delete. Settings
// is narrower than the card was, so the preview sits beside the few short
// controls rather than down the whole height. A click on the current
// space's icon (at the foot, or in the title row), Edit Space… and ⌘K's Edit
// Space all land here with that space picked (`SpaceEditing.open`). Every
// change lands as it is made.

/// The page: the spaces to pick from, and the picked one's controls.
struct SpacesSettingsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var editing = SpaceEditing.shared
    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme
    @State private var dragging: UUID?

    /// The space the page shows: the one a door named, else the one you are in.
    private var shown: UUID {
        if let id = editing.selected, spaces.all.contains(where: { $0.id == id }) { return id }
        return spaces.current(in: browser)
    }

    var body: some View {
        let _ = SettingsPerf.tick("spacesPage") // Fork (settings-perf)
        VStack(alignment: .leading, spacing: 18) {
            picker
                .settingsAnchor("spaces.picker") // Fork (settings-revamp): search anchors
            SpacePage(browser: browser, id: shown)
                .id(shown)
        }
    }

    /// Every space as a chip with its name, the picked one lifted out the
    /// way Settings' own rail lifts the page you are on. Drag one along to
    /// reorder; the column's foot follows.
    private var picker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(spaces.all) { space in
                    chip(space)
                        .onDrag {
                            dragging = space.id
                            return NSItemProvider(object: space.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: SpaceChipDrop(target: space.id, dragging: $dragging))
                }
                Button {
                    let id = spaces.add(in: browser)
                    editing.selected = id
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.wash.opacity(0.7)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Space")
                .accessibilityLabel("New Space")
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ space: Space) -> some View {
        let on = space.id == shown
        let tint = SpaceTint(space: space, dark: scheme == .dark).offColumn
        return Button { editing.selected = space.id } label: {
            HStack(spacing: 7) {
                SpaceGlyph(space: space, size: 14, dark: scheme == .dark, ink: tint.mark, bare: true)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.ground))
                Text(space.title)
                    .font(.system(size: 12, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                if space.id == spaces.current(in: browser) {
                    Circle().fill(Palette.muted.opacity(0.6)).frame(width: 4, height: 4)
                        .help("The space you are in")
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? Palette.ground : Palette.wash.opacity(0.7))
                    .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 3, y: 1)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(on ? Palette.hairline : .clear, lineWidth: 1)
            }
            .opacity(dragging == space.id ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .contextMenu { SpaceMenu(browser: browser, space: space) }
    }
}

/// A chip dragged over another takes its place at once, so the row makes
/// way as the pointer moves rather than on the drop.
private struct SpaceChipDrop: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        let spaces = Spaces.shared
        guard let moving = dragging, moving != target,
              let to = spaces.all.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(Motion.settle) { spaces.move(moving, to: to) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// One space's controls, as Settings › Spaces shows them under the picker.
struct SpacePage: View {
    @ObservedObject var browser: Browser
    let id: UUID

    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var emoji = ""
    @State private var profileDraft = ""
    @State private var namingProfile = false
    /// The Look tab picked before the theme can say so itself: Picture,
    /// chosen with no picture yet, is still a colour until one is picked.
    @State private var picked: Kind?
    /// The preview's appearance when it is not the window's — to see the
    /// space in the other mode without switching the whole Mac.
    @State private var previewNight: Bool?
    @FocusState private var focus: Field?

    private enum Field { case name, emoji, profile }

    /// Settings' page column, less its padding: what the page is laid out in.
    static let width: CGFloat = 446
    private static let rail: CGFloat = 144

    /// The symbols on offer: enough for the spaces people make; anything
    /// else is an emoji away.
    static let symbols = [
        "house", "briefcase", "book", "hammer", "gamecontroller", "cart", "heart", "star",
        "flask", "graduationcap", "music.note", "airplane", "paintbrush", "leaf", "terminal", "globe",
        "camera", "film", "bolt", "flame", "moon", "sun.max", "cup.and.saucer", "dumbbell", "chart.bar", "folder",
    ]

    /// What a symbol is called to a person — in the tooltip, the Icon
    /// caption and VoiceOver — rather than its SF Symbols name.
    static func symbolName(_ symbol: String) -> String {
        let names = [
            "house": "Home", "briefcase": "Briefcase", "book": "Book", "hammer": "Hammer",
            "gamecontroller": "Game controller", "cart": "Cart", "heart": "Heart", "star": "Star",
            "flask": "Flask", "graduationcap": "Graduation cap", "music.note": "Music", "airplane": "Airplane",
            "paintbrush": "Paintbrush", "leaf": "Leaf", "terminal": "Terminal", "globe": "Globe",
            "camera": "Camera", "film": "Film", "bolt": "Bolt", "flame": "Flame", "moon": "Moon",
            "sun.max": "Sun", "cup.and.saucer": "Cup", "dumbbell": "Dumbbell", "chart.bar": "Chart", "folder": "Folder",
        ]
        if let name = names[symbol] { return name }
        let words = symbol.split(separator: ".").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    enum Kind: String, CaseIterable, Identifiable {
        case colour, gradient, picture, animated
        var id: String { rawValue }
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        init(_ theme: SpaceTheme) {
            self = theme.motion != nil ? .animated : theme.image != nil ? .picture : theme.colors.count > 1 ? .gradient : .colour
        }
    }

    private var space: Space? { spaces.all.first { $0.id == id } }
    private var look: SpaceTheme { space?.look ?? .plain }
    private var night: Bool { scheme == .dark }
    /// For the tiles on the card: the space's colour, but the card's ink —
    /// the column's tone must not turn a white card's marks white.
    private var tint: SpaceTint { SpaceTint(theme: look, dark: night).offColumn }
    private var kind: Kind { picked ?? Kind(look) }

    private func set(_ change: (inout SpaceTheme) -> Void) {
        var theme = look
        change(&theme)
        spaces.theme(id, theme)
    }

    var body: some View {
        if let space {
            VStack(alignment: .leading, spacing: 18) {
                // The preview beside the short controls: Settings has the
                // width for one or the other down the page, not both. At
                // Settings' narrowest there isn't room for both side by side,
                // so the controls come first and the preview under them.
                SpaceSplit(spacing: 16) {
                    preview(space)
                    VStack(alignment: .leading, spacing: 16) {
                        header(space)
                        section("Name") { name }
                            .settingsAnchor("spaces.name")
                        section("Look", trailing: kind == Kind(look) ? nil : "pick a picture below") {
                            // Settings' own segmented control, so the page reads
                            // as one with the rest of Settings.
                            Segmented(options: Kind.allCases.map { ($0, $0.title) },
                                      selection: Binding(get: { kind }, set: choose(kind:)), wide: true, label: "Look")
                        }
                        .settingsAnchor("spaces.look")
                        section("Profile") { profile(space) }
                            .settingsAnchor("spaces.profile")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                controls(space)
                footer
            }
            .onAppear { draft = space.name }
        }
    }

    // MARK: - the preview

    /// The column as it will be: the real backdrop and the real tint, under
    /// a few rows standing in for tabs, with Light / Dark under it.
    private func preview(_ space: Space) -> some View {
        let shown = previewNight ?? night
        return VStack(spacing: 10) {
            // Laid out at a real column's width and shrunk to fit beside
            // the controls: squeezed instead, its rows would spill over.
            SpaceColumnPreview(space: space, all: spaces.all, night: shown)
                .frame(width: SpacePage.rail / 0.72, height: 330 / 0.72)
                .scaleEffect(0.72)
                .frame(width: SpacePage.rail, height: 330)
                // A picture of the column, not tabs to read out one by one.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Preview of the column")
            Picker("", selection: Binding(get: { shown }, set: { previewNight = $0 == night ? nil : $0 })) {
                Text("Light").tag(false)
                Text("Dark").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 120)
            .accessibilityLabel("Preview in")
        }
        .frame(width: SpacePage.rail)
    }

    // MARK: - the controls

    private func header(_ space: Space) -> some View {
        HStack(spacing: 10) {
            SpaceGlyph(space: space, size: 20, dark: night, ink: tint.mark, bare: true)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.ground))
            VStack(alignment: .leading, spacing: 1) {
                Text(space.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                let n = spaces.count(of: id, in: browser)
                Text("\(n) tab\(n == 1 ? "" : "s") · \(look.kind)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// What is too wide to sit beside the preview, in cards down the page.
    private func controls(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            group { section("Icon", trailing: space.symbol.map(SpacePage.symbolName) ?? (space.icon == nil ? (space.emoji == nil ? "None" : "From the name") : "Emoji")) { icons(space) } }
                .settingsAnchor("spaces.icon", card: true)
            group {
                VStack(alignment: .leading, spacing: 18) {
                    section(kind == .picture ? "Tint" : "Colours", trailing: colourName(space)) { colours }
                    if kind == .picture { section("Picture") { pictures } }
                    if kind == .animated { section("Scene", trailing: AnimatedBackdrop.styles.first { $0.id == look.motion?.style }?.name) { scenes } }
                }
            }
            .settingsAnchor("spaces.colours", card: true)
            group { section("Adjust") { adjust } }
                .settingsAnchor("spaces.adjust", card: true)
        }
    }

    /// One of Settings' hairline cards around a section or two.
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let inside = content()
        return Card { inside.padding(14) }
    }

    /// A caption over its content; `trailing` names the current choice.
    private func section<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.8))
                if let trailing {
                    Spacer(minLength: 6)
                    Text(trailing).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var name: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .focused($focus, equals: .name)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .settingsField(radius: 8) // SB-04: the ink edge while the keyboard is in it
            .onChange(of: draft) { _, now in
                let trimmed = now.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { spaces.rename(id, to: trimmed) }
            }
            .onSubmit { focus = nil }
    }

    // MARK: icon

    /// None (the dot Arc draws for a space without one), the symbols, and
    /// a field for an emoji.
    private func icons(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // As many to a line as the card has room for: nine fixed
            // columns ran off the card at Settings' narrowest.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34, maximum: 34), spacing: 5)], alignment: .leading, spacing: 5) {
                tile(selected: space.icon == nil) {
                    Circle().fill(tint.mark).frame(width: 7, height: 7)
                } act: { spaces.icon(id, nil); emoji = "" }
                .help("No icon — a dot, or the emoji the name starts with")
                .accessibilityLabel("No icon")
                ForEach(SpacePage.symbols, id: \.self) { symbol in
                    tile(selected: space.symbol == symbol) {
                        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint.mark)
                    } act: { spaces.icon(id, "sf:" + symbol); emoji = "" }
                    .help(SpacePage.symbolName(symbol))
                    .accessibilityLabel(SpacePage.symbolName(symbol))
                }
            }
            HStack(spacing: 8) {
                if let shown = space.emoji, space.icon != nil {
                    Text(shown).font(.system(size: 17)).frame(width: 26)
                }
                TextField("Type or paste an emoji", text: $emoji)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focus, equals: .emoji)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .settingsField() // SB-04
                    .onChange(of: emoji) { _, now in
                        // The first emoji typed is the icon; the rest is noise.
                        guard let first = now.first(where: { $0.unicodeScalars.first?.properties.isEmojiPresentation == true
                            || $0.unicodeScalars.contains { $0.properties.isEmojiModifierBase } }) else { return }
                        spaces.icon(id, String(first))
                        if now != String(first) { emoji = String(first) }
                    }
                Button("Emoji…") {
                    focus = .emoji
                    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                }
                .controlSize(.small)
            }
        }
    }

    private func tile<Content: View>(selected: Bool, @ViewBuilder _ content: () -> Content, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            content()
                .frame(width: 34, height: 30)
                // The chosen tile wears the column's own colour; the others
                // the card's wash.
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? tint.ground : Palette.wash.opacity(0.7)))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tint.dot.opacity(0.8), lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: look

    /// A tab of the Look picker, applied. Colour keeps the first colour and
    /// drops the rest; Gradient makes sure there are two; Picture keeps the
    /// colours as the tint over it; Animated starts the first scene, or the
    /// one it had.
    private func choose(kind new: Kind) {
        picked = nil
        switch new {
        case .colour:
            set { $0.motion = nil; $0.image = nil; $0.colors = Array($0.colors.prefix(1)) }
        case .gradient:
            set {
                $0.motion = nil
                $0.image = nil
                if $0.colors.count < 2 { $0.colors.append(SpaceTheme.next(after: $0.colors.last)) }
            }
        case .picture:
            set { $0.motion = nil }
            if look.image == nil { picked = .picture }
        case .animated:
            set { $0.motion = SpaceTheme.Motion(style: $0.motion?.style ?? AnimatedBackdrop.styles.first?.id ?? "ribbons",
                                                speed: $0.motion?.speed ?? 1) }
        }
    }

    private func colourName(_ space: Space) -> String {
        guard look.colors.count == 1 else { return "\(look.colors.count) colours" }
        let named = SpaceColour.allCases.first { theme(for: $0).colors == look.colors }
        return named?.name ?? "Custom"
    }

    /// A named colour's own theme — what `Spaces.tint` gives a space.
    private func theme(for colour: SpaceColour) -> SpaceTheme {
        colour.hue.map(SpaceTheme.hue) ?? .plain
    }

    /// The wells, a door to add or drop a stop, and the named colours.
    private var colours: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Array(look.colors.enumerated()), id: \.offset) { index, stop in
                    ColorPicker("", selection: Binding(
                        get: { stop.color },
                        set: { new in
                            guard let picked = SpaceTheme.Stop(new) else { return }
                            set { if $0.colors.indices.contains(index) { $0.colors[index] = picked } }
                        }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .fixedSize()
                }
                // A plain colour is one stop by definition; more is Gradient.
                if look.colors.count < 3, kind != .colour {
                    round("plus", help: "Add a colour") { set { $0.colors.append(SpaceTheme.next(after: $0.colors.last)) } }
                }
                if look.colors.count > (kind == .gradient ? 2 : 1) {
                    round("minus", help: "One colour fewer") { set { $0.colors.removeLast() } }
                }
                Spacer(minLength: 0)
            }
            // The named colours set the first stop and leave the rest of the
            // look alone. A space that comes back to exactly a named colour's
            // theme goes back to being that hue, as the menu's Colour does.
            // Wrapped rather than one line: eleven swatches ran off the
            // card at Settings' narrowest.
            SettingsFlow(spacing: 7) {
                ForEach(SpaceColour.allCases) { colour in
                    let named = theme(for: colour)
                    let chosen = look.colors.first == named.colors.first
                    Button {
                        var next = look
                        if next.colors.isEmpty { next.colors = named.colors } else { next.colors[0] = named.colors[0] }
                        // The copper picture is the default's, not a choice:
                        // picking a colour means that colour, not copper under it.
                        if next.image == SpaceTheme.copperPicture { next.image = nil; next.intensity = named.intensity }
                        if next == named { spaces.tint(id, hue: colour.hue) } else { spaces.theme(id, next) }
                    } label: {
                        ZStack {
                            Circle().fill(SpaceTint(hue: colour.hue, dark: night).swatch)
                            if chosen {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(colour.name)
                    .accessibilityLabel(colour.name)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .scaleEffect(chosen ? 1.12 : 1)
                    .animation(Motion.quick, value: chosen)
                }
            }
        }
    }

    /// Choose… for a new one; the pictures already in `themes/`, newest
    /// first, to reuse; and a way back to none.
    private var pictures: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(look.image == nil ? "Choose…" : "Change…") { choosePicture() }
                    .controlSize(.small)
                if look.image != nil {
                    Button("Clear") { set { $0.image = nil }; picked = .picture }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            let recent = SpacePictures.recent()
            if !recent.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 54, maximum: 54), spacing: 7)], alignment: .leading, spacing: 7) {
                    ForEach(recent, id: \.self) { name in
                        Button {
                            set { $0.image = name; $0.motion = nil }
                            picked = nil
                        } label: {
                            Group {
                                if let thumb = SpacePictures.thumbnail(name) {
                                    Image(nsImage: thumb).resizable().scaledToFill()
                                } else {
                                    Palette.wash
                                }
                            }
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(look.image == name ? tint.dot : Palette.hairline, lineWidth: look.image == name ? 2 : 1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name == SpaceTheme.copperPicture ? "\(Fork.name) picture" : "Picture used before")
                        .accessibilityAddTraits(look.image == name ? .isSelected : [])
                    }
                }
            } else {
                Text("Pictures you pick are kept here to use again.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    /// The scenes by name, and how fast the chosen one moves.
    private var scenes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(AnimatedBackdrop.styles, id: \.id) { style in
                    let on = look.motion?.style == style.id
                    Button {
                        set { $0.motion = SpaceTheme.Motion(style: style.id, speed: $0.motion?.speed ?? 1) }
                    } label: {
                        Text(style.name)
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? tint.mark : Palette.ink.opacity(0.8))
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(Capsule().fill(on ? tint.ground : Palette.wash.opacity(0.7)))
                            .overlay { if on { Capsule().strokeBorder(tint.dot.opacity(0.8), lineWidth: 1.5) } }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            slider("Speed", value: look.motion?.speed ?? 1, range: 0...2,
                   readout: String(format: "%.1f×", look.motion?.speed ?? 1)) { v in
                set { $0.motion?.speed = v }
            }
        }
    }

    /// Intensity, grain, blur and the tone.
    private var adjust: some View {
        VStack(alignment: .leading, spacing: 10) {
            slider("Intensity", value: look.intensity, range: 0.2...1) { v in set { $0.intensity = v } }
            slider("Grain", value: look.grain, range: 0...1) { v in set { $0.grain = v } }
            // Blur has nothing to soften on a flat colour or a gradient, so it isn't offered there.
            if kind != .colour && kind != .gradient {
                slider("Blur", value: look.blur, range: 0...1) { v in set { $0.blur = v } }
            }
            tone
        }
    }

    /// Dark to bright with Normal in the middle. The middle is sticky — a
    /// drag that ends near it lands on exactly as-is, which is hard to hit
    /// by hand on a bare slider.
    private var tone: some View {
        HStack(alignment: .top, spacing: 10) {
            label("Tone").padding(.top, 3)
            VStack(spacing: 2) {
                Slider(value: Binding(get: { look.tone }, set: { v in set { $0.tone = abs(v) < 0.08 ? 0 : v } }), in: -1...1)
                    .controlSize(.small)
                HStack {
                    Text("Dark")
                    Spacer()
                    Text("Normal").fontWeight(look.tone == 0 ? .semibold : .regular)
                    Spacer()
                    Text("Bright")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
            }
            Text(look.tone == 0 ? "—" : String(format: "%@%d", look.tone < 0 ? "−" : "+", Int((abs(look.tone) * 100).rounded())))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .frame(width: 38, alignment: .trailing)
                .padding(.top, 3)
        }
    }

    private func label(_ title: String) -> some View {
        Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 64, alignment: .leading)
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, readout: String? = nil,
                        _ change: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            label(title)
            Slider(value: Binding(get: { value }, set: change), in: range).controlSize(.small)
            Text(readout ?? "\(Int((value * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .frame(width: 38, alignment: .trailing)
        }
    }

    /// A small round door beside the colour wells.
    private func round(_ symbol: String, help: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.wash))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "A picture for the space's column"
        // A sheet on this window, not a modal that froze every window.
        SettingsPanels.present(panel, on: Windows.window(of: browser)) { url in
            guard let url, let name = SpaceTheme.adopt(image: url) else { return }
            set { $0.image = name; $0.motion = nil }
            picked = nil
        }
    }

    // MARK: profile and the foot

    /// Shared, one of the names in use, or a new one.
    private func profile(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Profile", selection: Binding(
                get: { namingProfile ? "\u{0}new" : (space.profile ?? "") },
                set: { value in
                    if value == "\u{0}new" { namingProfile = true; profileDraft = ""; focus = .profile }
                    else { namingProfile = false; spaces.profile(id, named: value.isEmpty ? nil : value) }
                }
            )) {
                Text("Shared").tag("")
                ForEach(spaces.profiles, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("New Profile…").tag("\u{0}new")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200, alignment: .leading)
            if namingProfile {
                TextField("Profile name", text: $profileDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focus, equals: .profile)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .settingsField() // SB-04
                    .onSubmit {
                        let name = profileDraft.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        spaces.profile(id, named: name)
                        namingProfile = false
                    }
            }
            // What a profile is, in one line: the cookie jar. A page that is
            // already up keeps the jar it was built with.
            Text("Its own sign-ins and cookies, shared with spaces of the same profile. Pages opened from now on use it.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Delete, which asks first. Done is Settings' own close.
    @ViewBuilder
    private var footer: some View {
        if spaces.all.count > 1 {
            Card {
                Line("Delete this space", "Asks first, and can move its tabs to the space beside it") {
                    Pill("Delete Space…", tint: .red) { SpaceDelete.ask(id, in: browser) }
                }
            }
            .settingsAnchor("spaces.delete", card: true)
        }
    }
}

// MARK: - preview beside, or under

/// The preview and the short controls: side by side when the page has the
/// width for both, else the controls first and the preview under them — so
/// nothing runs off the page at Settings' narrowest.
private struct SpaceSplit: Layout {
    var spacing: CGFloat = 16
    /// The least the controls need beside the preview: the Look choices
    /// whole, without "Gradie…".
    var least: CGFloat = 270

    private func beside(_ width: CGFloat, preview: CGSize) -> Bool {
        width >= preview.width + spacing + least
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let preview = subviews[0].sizeThatFits(.unspecified)
        guard let width = proposal.width else {
            let rest = subviews[1].sizeThatFits(ProposedViewSize(width: least, height: nil))
            return CGSize(width: preview.width + spacing + rest.width, height: max(preview.height, rest.height))
        }
        if beside(width, preview: preview) {
            let rest = subviews[1].sizeThatFits(ProposedViewSize(width: width - preview.width - spacing, height: nil))
            return CGSize(width: width, height: max(preview.height, rest.height))
        }
        let rest = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: rest.height + spacing + preview.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let preview = subviews[0].sizeThatFits(.unspecified)
        if beside(bounds.width, preview: preview) {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(preview))
            let x = bounds.minX + preview.width + spacing
            subviews[1].place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: bounds.maxX - x, height: nil))
        } else {
            let rest = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + rest.height + spacing), proposal: ProposedViewSize(preview))
        }
    }
}

// MARK: - the preview column

/// A column in miniature: the lights, an address, three favourites, the
/// space's title, a live row and a few resting ones, New Tab and the foot's
/// chips — every one drawn with the tint the real column uses, so what the
/// preview says about legibility is what the column will do.
struct SpaceColumnPreview: View {
    let space: Space
    let all: [Space]
    let night: Bool

    var body: some View {
        let tint = SpaceTint(space: space, dark: night)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 8, height: 8)
                }
                Spacer()
                ForEach(["chevron.left", "chevron.right", "arrow.clockwise"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 9, weight: .semibold)).foregroundStyle(tint.ink.opacity(0.72))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.square)
                .frame(height: 26)
                .overlay(alignment: .leading) {
                    Text("copper.app").font(.system(size: 11)).foregroundStyle(tint.muted).padding(.leading, 9)
                }
                .padding(.horizontal, 8)

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(i == 0 ? tint.pill : tint.square)
                        .frame(height: 30)
                        .overlay { RowMark(icon: nil, letter: ["M", "C", "G"][i], tint: tint, size: 14) }
                }
            }
            .padding(8)

            HStack(spacing: 8) {
                SpaceGlyph(space: space, size: 13, dark: night, ink: tint.muted, bare: true)
                Text(space.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tint.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 28)

            row("Inbox", "I", tint: tint, live: true)
            row("Design review", "D", tint: tint)
            row("Reading list", "R", tint: tint)
            Rectangle().fill(tint.hairline).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 6)
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 10)).frame(width: 14)
                Text("New Tab").font(.system(size: 12))
            }
            .foregroundStyle(tint.muted)
            .padding(.horizontal, 14)
            .frame(height: 28)
            row("Today's page", "T", tint: tint)
            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: "books.vertical").font(.system(size: 11)).foregroundStyle(tint.ink.opacity(0.72))
                Spacer(minLength: 2)
                ForEach(all.prefix(5)) { other in
                    SpaceChip(space: other, current: other.id == space.id, dark: night, over: false, ink: tint.ink)
                        .scaleEffect(0.78)
                        .frame(width: 22, height: 22)
                }
                Spacer(minLength: 2)
                Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(tint.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { tint.backdrop }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    private func row(_ title: String, _ letter: String, tint: SpaceTint, live: Bool = false) -> some View {
        HStack(spacing: 8) {
            RowMark(icon: nil, letter: letter, tint: tint, size: 14)
            Text(title)
                .font(.system(size: 12, weight: live ? .semibold : .regular))
                .foregroundStyle(live ? tint.ink : tint.ink.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            if live {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.pill)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.rim, lineWidth: 1))
                    .shadow(color: tint.lift, radius: 3, y: 1)
            }
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - pictures to pick again

/// The pictures already copied into `themes/` — every one some space has
/// worn — newest first, with small thumbnails made once.
@MainActor
enum SpacePictures {
    private static var thumbs: [String: NSImage] = [:]

    static func recent(limit: Int = 12) -> [String] {
        let folder = Store.file("themes")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && !$0.lastPathComponent.hasPrefix(".") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(limit - 1)
            .map(\.lastPathComponent)
            // Copper's own picture is always on offer, first, whether or not
            // any space has worn it yet.
            .reduce(into: [SpaceTheme.copperPicture]) { $0.append($1) }
    }

    /// 160 pixels on the long side, off ImageIO's thumbnailer rather than
    /// decoding the whole 2800-pixel picture for a 54pt square.
    static func thumbnail(_ name: String) -> NSImage? {
        if let seen = thumbs[name] { return seen }
        guard let source = CGImageSourceCreateWithURL(SpaceTheme.file(name) as CFURL, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: small, size: NSSize(width: small.width / 2, height: small.height / 2))
        thumbs[name] = image
        return image
    }
}
