import AppKit
import SwiftUI

struct TapeRootView: View {
    @ObservedObject var deck: Deck

    var body: some View {
        ZStack(alignment: .topLeading) {
            CassetteView(deck: deck)
                .frame(width: Geo.cw + 2 * Geo.margin, height: Geo.ch + 2 * Geo.margin)
                .rotation3DEffect(.degrees(deck.flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            Group {
                if deck.drawMode { PenPanel(deck: deck) }
                else if deck.editingLabel { LabelPanel(deck: deck) }
                else { ControlPanel(deck: deck) }
            }
            .frame(width: Geo.panel.width, height: Geo.panel.height)
            .background(PanelBackground())
            .offset(x: Geo.panel.minX, y: Geo.panel.minY + (deck.showPanel ? 0 : -14))
            .opacity(deck.showPanel ? 1 : 0)
            .allowsHitTesting(deck.showPanel)
            let drawer = deck.showPanel && deck.meterOpen && !deck.drawMode
            MeterDrawer(deck: deck)
                .frame(width: Geo.drawer.width, height: Geo.drawer.height)
                .background(PanelBackground())
                .offset(x: Geo.drawer.minX, y: Geo.drawer.minY + (drawer ? 0 : -24))
                .opacity(drawer ? 1 : 0)
                .allowsHitTesting(drawer)
        }
        .frame(width: Geo.window.width, height: Geo.window.height, alignment: .topLeading)
    }
}

struct CassetteView: View {
    @ObservedObject var deck: Deck

    var body: some View {
        let m = Geo.margin
        let state = deck.paint
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                ctx.translateBy(x: m, y: m)
                Painter.draw(&ctx, state)
            }
            .allowsHitTesting(false)
            if !deck.snapshotMode {
                DragArea(deck: deck, drawMode: deck.drawMode)
                    .frame(width: Geo.cw, height: Geo.ch)
                    .offset(x: m, y: m)
            }
        }
    }
}

/// Invisible layer over the cassette: drags the window, opens the label editor,
/// shows the context menu, and takes the pen strokes in drawing mode.
struct DragArea: NSViewRepresentable {
    let deck: Deck
    let drawMode: Bool

    func makeNSView(context: Context) -> DragNSView {
        let v = DragNSView()
        v.deck = deck
        return v
    }

    func updateNSView(_ v: DragNSView, context: Context) {
        v.deck = deck
        if v.drawMode != drawMode {
            v.drawMode = drawMode
            v.window?.invalidateCursorRects(for: v)
        }
    }
}

final class DragNSView: NSView {
    weak var deck: Deck?
    var drawMode = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if drawMode { addCursorRect(bounds, cursor: .crosshair) }
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) {
        guard let deck else { return }
        if drawMode {
            deck.beginStroke(at: point(e))
        } else if e.clickCount == 2 {
            // On a strip: press on. On an empty label: the title strip. Anywhere else: a new strip right there.
            let p = point(e)
            if let i = deck.stripIndex(at: p) { deck.beginLabelEdit(.existing(i)) }
            else if deck.doc.strips(deck.side).isEmpty && Painter.labelZone(deck.doc.design).contains(p) { deck.beginLabelEdit(.title) }
            else { deck.beginLabelEdit(.new(p)) }
        } else if case let hover = deck.tapeHover(point(e)), hover != .none {
            deck.beginEmbossDrag(at: point(e), rotate: hover == .turn)
            movingTape = true
        } else {
            window?.performDrag(with: e)
        }
    }

    private var movingTape = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// Over the label strip: a hand to move it, a turning arrow at its corners.
    override func mouseMoved(with e: NSEvent) {
        guard let deck, !drawMode, !movingTape else { return }
        switch deck.tapeHover(point(e)) {
        case .turn: Self.turnCursor.set()
        case .move: NSCursor.openHand.set()
        case .none: NSCursor.arrow.set()
        }
    }

    override func mouseExited(with e: NSEvent) {
        guard let deck, !drawMode else { return }
        _ = deck.tapeHover(CGPoint(x: -100, y: -100))
        NSCursor.arrow.set()
    }

    static let turnCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { r in
            for (color, weight) in [(NSColor.white, NSFont.Weight.black), (NSColor.black, .bold)] {
                let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: weight).applying(.init(paletteColors: [color]))
                if let s = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                    s.draw(in: NSRect(x: (r.width - s.size.width) / 2, y: (r.height - s.size.height) / 2,
                                      width: s.size.width, height: s.size.height))
                }
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()

    override func mouseDragged(with e: NSEvent) {
        if drawMode { deck?.extendStroke(to: point(e)) }
        if movingTape { deck?.moveEmbossDrag(to: point(e)) }
    }

    override func mouseUp(with e: NSEvent) {
        if drawMode { deck?.endStroke() }
        if movingTape {
            deck?.endEmbossDrag()
            movingTape = false
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let deck else { return nil }
        if let i = deck.stripIndex(at: point(event)) { return deck.stripMenu(i) }
        return deck.makeMenu()
    }
}

// MARK: - Panels

struct PanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0x3b3b3f), Color(hex: 0x1d1d20)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
    }
}

struct ControlPanel: View {
    @ObservedObject var deck: Deck

    var body: some View {
        let t = deck.transport
        HStack(spacing: 10) {
            VStack(spacing: 5) {
                Counter(value: deck.counter)
                    .onTapGesture { deck.resetCounter() }
                    .help(L("Zählwerk – klicken zum Nullstellen"))
                HStack(spacing: 6) {
                    Led(on: deck.recordLED.on, level: deck.recordLED.level, color: Color(hex: 0xff3b30))
                    Led(on: t == .playing && !deck.paused, level: 1, color: Color(hex: 0x4cd964))
                }
            }
            HStack(spacing: 3) {
                DeckKey(kind: .rec, latched: t == .recording, help: L("Aufnahme (R) – mit Pause: Aufnahmebereitschaft")) { deck.pressRecord() }
                DeckKey(kind: .rew, latched: t == .rewind || deck.cue < 0,
                        help: L("Zurückspulen (←) – während der Wiedergabe gedrückt halten zum hörbaren Zurückspulen"),
                        onPress: { deck.pressWind(.rewind) }, onRelease: { deck.releaseWind(.rewind) })
                DeckKey(kind: .play, latched: t == .playing || t == .recording, help: L("Wiedergabe (Leertaste)")) { deck.pressPlay() }
                DeckKey(kind: .ff, latched: t == .ffwd || deck.cue > 0,
                        help: L("Vorspulen (→) – während der Wiedergabe gedrückt halten zum hörbaren Vorspulen"),
                        onPress: { deck.pressWind(.ffwd) }, onRelease: { deck.releaseWind(.ffwd) })
                DeckKey(kind: .pause, latched: deck.paused, help: L("Pause (P) – aus jeder App: ⌥⌘P")) { deck.pressPause() }
            }
            VStack(spacing: 7) {
                SourceSwitch(source: $deck.source)
                HStack(spacing: 6) {
                    SmallIcon(name: deck.onTop ? "pin.fill" : "pin", help: L("Immer im Vordergrund"), active: deck.onTop) { deck.toggleOnTop() }
                    SmallIcon(name: "gauge.with.needle", help: L("Aussteuerung"), active: deck.meterOpen) { deck.toggleMeter() }
                    SmallIcon(name: "pencil", help: L("Auf die Kassette malen")) { deck.toggleDrawMode() }
                    SmallIcon(name: "ellipsis.circle", help: L("Mehr")) { deck.popMenu() }
                }
            }
            DeckKey(kind: t == .stopped && !deck.paused ? .eject : .stop, latched: false,
                    help: t == .stopped ? L("Auswerfen und umdrehen") : L("Stopp")) { deck.pressStop() }
        }
        .padding(.horizontal, 12)
    }
}

/// Two backlit VU meters and the record level fader, folded out under the keys.
struct MeterDrawer: View {
    @ObservedObject var deck: Deck

    var body: some View {
        HStack(spacing: 12) {
            VUMeter(value: deck.needleL, channel: "L")
            VUMeter(value: deck.needleR, channel: "R")
            if deck.transport == .recording {
                LevelFader(title: "REC LEVEL", position: $deck.recordLevel, resetTo: Deck.unityLevel, redAbove: Deck.unityLevel,
                           help: L("Aufnahmepegel – Doppelklick setzt ihn zurück. Im roten Bereich wird das Band übersteuert: Es verzerrt, wird aber kaum lauter."))
            } else {
                LevelFader(title: "VOLUME", position: $deck.playVolume, resetTo: Deck.defaultVolume, redAbove: nil,
                           help: L("Lautstärke – Doppelklick setzt sie zurück. Während einer Aufnahme wird der Regler zum Aufnahmepegel."))
            }
        }
        .padding(.horizontal, 12)
    }
}

struct VUMeter: View {
    let value: Double     // dB relative to 0 VU
    let channel: String

    /// VU scales follow the voltage, so 0 VU sits about 70 % of the way across.
    private static func position(_ db: Double) -> Double { pow(10, db / 20) / pow(10, 3.0 / 20) }

    var body: some View {
        Canvas { ctx, size in
            let face = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: face, cornerRadius: 4), with: .linearGradient(
                Gradient(colors: [Color(hex: 0xf7e7b4), Color(hex: 0xe9cf86)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let pivot = CGPoint(x: size.width / 2, y: size.height + 26)
            let radius = 60.0
            func angle(_ db: Double) -> Double { (-40 + 80 * Self.position(db)) * .pi / 180 }
            func point(_ db: Double, _ r: Double) -> CGPoint {
                let a = angle(db)
                return CGPoint(x: pivot.x + r * sin(a), y: pivot.y - r * cos(a))
            }
            var arc = Path()
            arc.addArc(center: pivot, radius: radius, startAngle: .radians(angle(-20) - .pi / 2),
                       endAngle: .radians(angle(0) - .pi / 2), clockwise: false)
            ctx.stroke(arc, with: .color(Color(hex: 0x2a2418)), lineWidth: 1.2)
            var red = Path()
            red.addArc(center: pivot, radius: radius - 1, startAngle: .radians(angle(0) - .pi / 2),
                       endAngle: .radians(angle(3) - .pi / 2), clockwise: false)
            ctx.stroke(red, with: .color(Color(hex: 0xc8281e)), lineWidth: 3.5)
            for db in [-20.0, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3] {
                var tick = Path()
                tick.move(to: point(db, radius))
                tick.addLine(to: point(db, radius + (db == 0 || db == -20 || db == 3 ? 6 : 4)))
                ctx.stroke(tick, with: .color(db > 0 ? Color(hex: 0xc8281e) : Color(hex: 0x2a2418)), lineWidth: 1)
            }
            for (db, label) in [(-20.0, "20"), (-10, "10"), (-5, "5"), (-3, "3"), (0, "0"), (3, "+3")] {
                ctx.draw(Text(label).font(.system(size: 6.5, weight: .semibold)).foregroundColor(db > 0 ? Color(hex: 0xc8281e) : Color(hex: 0x2a2418)),
                         at: point(db, radius + 11))
            }
            ctx.draw(Text("VU").font(.system(size: 9, weight: .heavy, design: .serif)).foregroundColor(Color(hex: 0x2a2418)),
                     at: CGPoint(x: size.width / 2, y: size.height - 16))
            ctx.draw(Text(channel).font(.system(size: 7, weight: .bold)).foregroundColor(Color(hex: 0x2a2418).opacity(0.6)),
                     at: CGPoint(x: 9, y: size.height - 8))
            var needle = Path()
            needle.move(to: pivot)
            needle.addLine(to: point(min(4, value), radius + 4))
            ctx.drawLayer { l in
                l.clip(to: Path(roundedRect: face, cornerRadius: 4))
                l.stroke(needle, with: .color(.black.opacity(0.18)), lineWidth: 1.4)   // shadow
                l.translateBy(x: -1.5, y: -1)
                l.stroke(needle, with: .color(Color(hex: 0x111111)), lineWidth: 1.1)
            }
            // A soft vignette, as if lit by a small bulb behind the face.
            ctx.fill(Path(roundedRect: face, cornerRadius: 4), with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(0.22)]),
                center: CGPoint(x: size.width / 2, y: size.height * 0.4), startRadius: size.width * 0.25, endRadius: size.width * 0.7))
        }
        .frame(width: 104, height: 52)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.7), lineWidth: 1.5))
    }
}

/// A slide fader with a ridged metal cap, scaled 0–10.
struct LevelFader: View {
    let title: String
    @Binding var position: Double
    let resetTo: Double
    let redAbove: Double?
    let help: String

    private let width: CGFloat = 136
    private let inset: CGFloat = 10

    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 7.5, weight: .heavy)).kerning(1).foregroundColor(.white.opacity(0.55))
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0...10, id: \.self) { i in
                        // Above the unity mark the fader drives the tape into saturation.
                        Rectangle().fill(redAbove.map { Double(i) / 10 > $0 } ?? false ? Color(hex: 0xd8392b) : Color.white.opacity(0.35))
                            .frame(width: 1, height: i % 5 == 0 ? 7 : 4)
                        if i < 10 { Spacer(minLength: 0) }
                    }
                }
                .frame(width: width - 2 * inset)
                .offset(x: inset, y: -11)
                Capsule().fill(Color.black.opacity(0.8)).frame(width: width - 2 * inset + 6, height: 4).offset(x: inset - 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
                    .overlay(HStack(spacing: 2) { ForEach(0..<4, id: \.self) { _ in Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1) } }
                        .padding(.vertical, 3))
                    .frame(width: 14, height: 20)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: inset - 7 + CGFloat(position) * (width - 2 * inset))
            }
            .frame(width: width, height: 30)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                position = min(1, max(0, Double((v.location.x - inset) / (width - 2 * inset))))
            })
            .onTapGesture(count: 2) { position = resetTo }
            .help(help)
        }
    }
}

/// The drawing tools replace the transport keys while drawing, like Preview's markup bar.
struct PenPanel: View {
    @ObservedObject var deck: Deck

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(Deck.pens, id: \.self) { c in
                    Circle()
                        .fill(Color(hex: c))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.white.opacity(deck.penColor == c ? 0.95 : 0.25),
                                                       lineWidth: deck.penColor == c ? 2 : 1))
                        .contentShape(Circle())
                        .onTapGesture { deck.penColor = c }
                }
            }
            HStack(spacing: 6) {
                ForEach(Deck.penWidths, id: \.self) { w in
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: w * 1.8, height: w * 1.8)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(deck.penWidth == w ? 0.18 : 0)))
                        .contentShape(Rectangle())
                        .onTapGesture { deck.penWidth = w }
                }
            }
            HStack(spacing: 12) {
                SmallIcon(name: "arrow.uturn.backward", help: L("Letzten Strich zurücknehmen")) { deck.undoStroke() }
                SmallIcon(name: "trash", help: L("Alles auf dieser Seite wegradieren")) { deck.clearDrawing() }
            }
            Button(L("Fertig")) { deck.toggleDrawMode() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(white: 0.88)))
        }
        .padding(.horizontal, 14)
    }
}

/// While pressing the label: the tape colours, a fresh strip, done.
struct LabelPanel: View {
    @ObservedObject var deck: Deck

    var body: some View {
        let current = deck.editingColor
        let colors = Painter.embossColors
        HStack(spacing: 12) {
            VStack(spacing: 5) {
                ForEach([Array(colors.prefix(8)), Array(colors.dropFirst(8))], id: \.self) { row in
                    HStack(spacing: 5) {
                        ForEach(row, id: \.self) { c in
                            Swatch(color: c, selected: current == c)
                                .onTapGesture { deck.setEmbossColor(c) }
                                .help(L("Band ziehen verschiebt es, an den Ecken dreht es sich"))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            SmallIcon(name: "scissors", help: L("Neues Band – das alte abschneiden")) { deck.newStrip() }
            SmallIcon(name: "plus", help: L("Weiteres Band prägen")) { deck.nextStrip() }
            Button(L("Fertig")) { deck.commitLabel() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(white: 0.88)))
        }
        .padding(.horizontal, 14)
    }
}

/// One tape colour. Clear tape shows as a frosted strip.
private struct Swatch: View {
    let color: UInt32
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Painter.isClearTape(color) ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color(hex: color)))
            .frame(width: 22, height: 12)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(selected ? 0.95 : 0.25), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
    }
}

struct Counter: View {
    let value: Int

    var body: some View {
        let digits = Array(String(format: "%03d", value))
        HStack(spacing: 1.5) {
            ForEach(0..<digits.count, id: \.self) { i in
                Text(String(digits[i]))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(white: 0.95))
                    .frame(width: 12, height: 18)
                    .background(RoundedRectangle(cornerRadius: 2).fill(LinearGradient(
                        colors: [Color(white: 0.04), Color(white: 0.2), Color(white: 0.04)],
                        startPoint: .top, endPoint: .bottom)))
            }
        }
        .padding(2.5)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.6)))
    }
}

struct Led: View {
    let on: Bool
    let level: Float
    let color: Color

    var body: some View {
        Circle()
            .fill(on ? color.opacity(0.45 + 0.55 * Double(min(1, level * 3))) : Color(white: 0.25))
            .frame(width: 6, height: 6)
            .shadow(color: on ? color.opacity(0.8) : .clear, radius: on ? 3 : 0)
    }
}

enum KeyKind { case rec, rew, play, ff, stop, eject, pause }

/// A piano key that acts the moment it goes down, stays down while its function runs,
/// and can report being let go (for cue and review).
struct DeckKey: View {
    let kind: KeyKind
    let latched: Bool
    let help: String
    var onPress: () -> Void
    var onRelease: (() -> Void)? = nil
    @State private var held = false

    init(kind: KeyKind, latched: Bool, help: String, onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) {
        self.kind = kind
        self.latched = latched
        self.help = help
        self.onPress = onPress
        self.onRelease = onRelease
    }

    var body: some View {
        let down = held || latched
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)).offset(y: 2.5)
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: down ? [Color(hex: 0xb9b8b2), Color(hex: 0xd2d1cb)]
                                                  : [Color(hex: 0xf5f4ef), Color(hex: 0xcac9c3)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(down ? 0.2 : 0.7), lineWidth: 0.6))
                .overlay(icon)
                .offset(y: down ? 2 : 0)
        }
        .frame(width: 38, height: 34)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.06), value: down)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !held {
                    held = true
                    onPress()
                }
            }
            .onEnded { _ in
                held = false
                onRelease?()
            })
        .help(help)
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .rec:
            Circle().fill(Color(hex: 0xd62d20)).frame(width: 11, height: 11)
        default:
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(hex: 0x2c2c2c))
        }
    }

    private var symbol: String {
        switch kind {
        case .rew: return "backward.fill"
        case .play: return "play.fill"
        case .ff: return "forward.fill"
        case .stop: return "stop.fill"
        case .eject: return "eject.fill"
        case .pause: return "pause.fill"
        case .rec: return ""
        }
    }
}

struct SourceSwitch: View {
    @Binding var source: RecordSource

    var body: some View {
        HStack(spacing: 0) {
            segment("SYS", .system, L("Systemton aufnehmen – alles, was der Mac gerade abspielt"))
            segment("MIC", .mic, L("Mikrofon aufnehmen"))
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private func segment(_ title: String, _ s: RecordSource, _ help: String) -> some View {
        let on = source == s
        return Text(title)
            .font(.system(size: 8.5, weight: .heavy))
            .kerning(0.8)
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(on ? .black : .white.opacity(0.55))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? Color(white: 0.88) : .clear))
            .contentShape(Capsule())
            .onTapGesture { source = s }
            .help(help)
    }
}

struct SmallIcon: View {
    let name: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(active ? Color(hex: 0xf7d77a) : .white.opacity(0.75))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
