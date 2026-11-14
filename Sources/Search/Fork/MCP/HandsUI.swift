import SwiftUI

// The agents' hands, drawn: a small coloured square on every tab an agent
// is touching (or touched in the last half minute), a capsule over the page
// while one drives the tab you are looking at, and a card on hover saying
// who, in which thread, doing what, since when — with Stop beside it.
//
// The square is the size of a favicon's corner so a row of tabs reads at a
// glance: one colour per agent session, its initial on it, stacked when two
// share a tab. Colours come from Drive.colour (Hands.swift).

/// The badges on one tab row or tab pill.
struct HandBadges: View {
    let tab: UUID
    var size: CGFloat = 14
    @ObservedObject private var drive = Drive.shared
    @State private var hovering = false
    @State private var inCard = false
    @State private var shown = false

    var body: some View {
        let here = drive.hands(on: tab)
        if !here.isEmpty {
            HStack(spacing: -size * 0.35) {
                ForEach(Array(here.prefix(3).enumerated()), id: \.element.id) { index, hand in
                    HandSquare(hand: hand, size: size)
                        .zIndex(Double(10 - index))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0; settle() }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                HandCards(hands: here).onHover { inCard = $0; settle() }
            }
            .onChange(of: drive.forcedCard) { _, forced in if forced == tab { shown = true } }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    /// Open on the pointer, and stay open while it travels into the card so
    /// Stop can be pressed; close a moment after it has left both.
    private func settle() {
        if hovering || inCard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if hovering || inCard { shown = true } }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if !hovering && !inCard { shown = false } }
        }
    }
}

/// One agent's square: its colour, its initial, a soft rim so it lifts off
/// whatever column or pill it sits on. It breathes while a call is in flight.
struct HandSquare: View {
    let hand: Drive.Hand
    var size: CGFloat = 14

    var body: some View {
        let swatch = Drive.colour(for: hand.who)
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(swatch.fill)
            .overlay {
                Group {
                    if hand.driver == .jev {
                        Image(systemName: "sparkle").font(.system(size: size * 0.55, weight: .bold))
                    } else {
                        Text(hand.who.initial).font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                    }
                }
                .foregroundStyle(swatch.ink)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            .help(hand.who.line)
    }
}

/// The hover card: one block per agent on the tab.
struct HandCards: View {
    let hands: [Drive.Hand]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hands.enumerated()), id: \.element.id) { index, hand in
                if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                HandCard(hand: hand)
            }
        }
        .frame(width: 280)
    }
}

struct HandCard: View {
    let hand: Drive.Hand
    @ObservedObject private var drive = Drive.shared

    var body: some View {
        let swatch = Drive.colour(for: hand.who)
        let now = drive.heartbeat
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HandSquare(hand: hand, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hand.who.agent + (hand.who.via.isEmpty ? "" : "  ·  for \(hand.who.via)"))
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(hand.who.thread.isEmpty ? "No thread named" : hand.who.thread)
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                }
                Spacer(minLength: 4)
                if drive.canStop(hand) {
                    Button { drive.stop(hand.who.key) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill").font(.system(size: 8))
                            Text("Stop").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(swatch.fill)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(swatch.fill.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(hand.driver == .jev ? "Stop the run" : "Take the browser back — its next calls are refused")
                }
            }
            if !hand.doing.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(swatch.fill).frame(width: 5, height: 5).opacity(hand.busy ? 1 : 0.4)
                    Text(hand.doing).font(.system(size: 11.5)).foregroundStyle(Palette.ink).lineLimit(2)
                }
            }
            Text(timing(now))
                .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            if !hand.who.session.isEmpty || !hand.who.project.isEmpty {
                Text([hand.who.project, hand.who.session.isEmpty ? "" : "session \(hand.who.session)"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted.opacity(0.8)).lineLimit(1)
            }
        }
        .padding(12)
    }

    private func timing(_ now: Date) -> String {
        let since = Int(max(0, now.timeIntervalSince(hand.since)))
        let first = since < 60 ? "\(since) s" : "\(since / 60) min"
        let started = hand.since.formatted(date: .omitted, time: .shortened)
        if hand.busy { return "Working for \(first) · since \(started)" }
        let idle = Int(max(0, now.timeIntervalSince(hand.last)))
        return "Since \(started) · last move \(idle) s ago"
    }
}

/// Over the page, top centre, while agents drive the tab you are looking at:
/// a capsule per agent in its own colour — "Jev · Download Copper and Migrate
/// Arc" — that opens the timeline on a click, shows the card on hover, and
/// stops that agent from its square. It replaces the plain "… is driving"
/// pill, in the same small, quiet language.
struct HandBar: View {
    let tabs: [UUID]
    @ObservedObject private var drive = Drive.shared

    var body: some View {
        let here = Array(Dictionary(tabs.flatMap { drive.hands(on: $0) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            .values.sorted { $0.last > $1.last }.prefix(3))
        HStack(spacing: 6) {
            ForEach(here) { hand in HandCapsule(hand: hand) }
        }
    }
}

struct HandCapsule: View {
    let hand: Drive.Hand
    @ObservedObject private var drive = Drive.shared
    @State private var breathing = false
    @State private var hovering = false
    @State private var inCard = false
    @State private var shown = false

    var body: some View {
        let swatch = Drive.colour(for: hand.who)
        HStack(spacing: 6) {
            HandSquare(hand: hand, size: 14)
                .opacity(hand.busy ? 1 : (breathing ? 0.55 : 1))
            Button { Agent.shared.reveal() } label: {
                // Fork (agent-ux): "<Agent> · <task>", then Stop — the pill's format.
                (Text(hand.who.agent).fontWeight(.semibold)
                 + Text(hand.who.thread.isEmpty || hand.who.thread == "this window" ? "" : "  ·  \(hand.who.thread)"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .help("Show what it is doing")
            if drive.canStop(hand) {
                DriveStop(help: hand.driver == .jev ? "Stop the run (⎋)" : "Take the browser back (⎋)") { drive.stop(hand.who.key) }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .frame(height: 30)
        .background(Palette.ground.opacity(0.94), in: Capsule())
        .background(swatch.fill.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(swatch.fill.opacity(0.75), lineWidth: 1.25))
        .shadow(color: swatch.fill.opacity(0.25), radius: 6, y: 1)
        .onHover { hovering = $0; settle() }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            HandCards(hands: [hand]).onHover { inCard = $0; settle() }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathing = true }
        }
    }

    private func settle() {
        if hovering || inCard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if hovering || inCard { shown = true } }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if !hovering && !inCard { shown = false } }
        }
    }
}
