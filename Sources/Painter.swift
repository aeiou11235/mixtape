import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

struct CassetteDesign {
    let id: String
    let name: String
    let shell: Color
    let shellHi: Color
    let clear: Bool
    let label: Color
    let accent: Color
    let accent2: Color
    let ink: Color
    let pen: Color
    let typeText: String
    /// Set for designs that come from an add-on; they are drawn from its pictures.
    var skin: Skin? = nil

    /// The four the app comes with: worn pictures from Resources/Designs/base, under the ids tapes
    /// have always used. The drawn versions stay as a fallback.
    static let all: [CassetteDesign] = {
        guard let base = SkinStore.builtIn() else { return drawn }
        return drawn.map { d in
            var b = d
            b.skin = base.skins.first { $0.spec.id == d.id }
            return b
        }
    }()

    private static let drawn: [CassetteDesign] = [
        CassetteDesign(id: "ferro", name: "Ferro", shell: Color(hex: 0x161618), shellHi: Color(hex: 0x323237), clear: false,
                       label: Color(hex: 0xf0e9d8), accent: Color(hex: 0xc42f28), accent2: Color(hex: 0xe8a33a),
                       ink: Color(hex: 0x2a2a2a), pen: Color(hex: 0x1c3f94), typeText: "NORMAL POSITION · TYPE I"),
        CassetteDesign(id: "chrome", name: "Chrome", shell: Color(hex: 0x3d424a), shellHi: Color(hex: 0x6a707a), clear: false,
                       label: Color(hex: 0xf5f2ea), accent: Color(hex: 0x1d4c9a), accent2: Color(hex: 0x86b6e8),
                       ink: Color(hex: 0x1d2a45), pen: Color(hex: 0x141414), typeText: "HIGH POSITION · TYPE II · CrO₂"),
        CassetteDesign(id: "metal", name: "Metal", shell: Color(hex: 0xd9d1bc), shellHi: Color(hex: 0xf6f1e4), clear: false,
                       label: Color(hex: 0x151515), accent: Color(hex: 0xc8a14a), accent2: Color(hex: 0x7d6328),
                       ink: Color(hex: 0xc8a14a), pen: Color(hex: 0xf1e8cf), typeText: "METAL POSITION · TYPE IV"),
        CassetteDesign(id: "klar", name: L("Klar"), shell: Color.white.opacity(0.10), shellHi: Color.white.opacity(0.34), clear: true,
                       label: Color(hex: 0xfbfaf6), accent: Color(hex: 0xe8632b), accent2: Color(hex: 0xf3b43a),
                       ink: Color(hex: 0x333333), pen: Color(hex: 0x1c3f94), typeText: "NORMAL POSITION · TYPE I"),
    ]

    static func named(_ id: String) -> CassetteDesign {
        all.first { $0.id == id } ?? SkinStore.shared.skin(id)?.design ?? all[0]
    }
}

/// Everything the painter needs for one frame.
struct PaintState {
    var design: CassetteDesign
    var length: TapeLength
    var side: Side
    var title: String
    var total: Double
    var leader: Double
    var leftAmount: Double
    var rightAmount: Double
    var leftAngle: Double
    var rightAngle: Double
    var hideTitle: Bool
    var hint: Bool
    var strokes: [Stroke]
    /// The write-protect tab for the side facing up has been broken out.
    var writeProtected = false
    /// The label-tape strips stuck on this side; the first one is the title.
    var strips: [EmbossedTape] = []
    /// The strip being pressed: which one, its positions so far, the cursor and whether it is lit,
    /// and where its left end stays.
    var editingStrip: Int? = nil
    var embossCells: [String]? = nil
    var embossCursor: Int? = nil
    var embossCursorVisible = false
    var editAnchor: Painter.EmbossAnchor? = nil
    /// The strip and corner under the pointer, where dragging turns it.
    var hoverStrip: Int? = nil
    var embossCorner: Int? = nil
}

/// Window layout, in points with the origin top-left.
enum Geo {
    static let cw: CGFloat = 440, ch: CGFloat = 280, margin: CGFloat = 40
    static let panelW: CGFloat = 440, panelH: CGFloat = 60, gap: CGFloat = 8
    static let drawerH: CGFloat = 72, drawerGap: CGFloat = 6
    static let window = CGSize(width: cw + 2 * margin,
                               height: margin + ch + gap + panelH + drawerGap + drawerH + 24)
    static let cassette = CGRect(x: margin, y: margin, width: cw, height: ch)
    static let panel = CGRect(x: margin + (cw - panelW) / 2, y: margin + ch + gap, width: panelW, height: panelH)
    static let drawer = CGRect(x: panel.minX, y: panel.maxY + drawerGap, width: panelW, height: drawerH)
    /// Where the pointer may travel from the cassette down to the panel without it disappearing.
    static let panelZone = CGRect(x: panel.minX - 12, y: cassette.maxY - 4,
                                  width: panel.width + 24, height: panel.maxY - cassette.maxY + 16)
    static let drawerZone = drawer.insetBy(dx: -12, dy: -10)
}

/// Draws the cassette at true Compact Cassette proportions (IEC 60094): a 100.4 × 63.8 mm
/// shell, hubs 42.5 mm apart, and tape packs sized from real tape length and thickness.
enum Painter {
    static let W = 440.0, H = 280.0
    static let mm = W / 100.4                     // points per millimetre
    static let tapeSpeed = 47.6 * mm              // 4.76 cm/s
    static let hubY = 128.0
    static let hubL = CGPoint(x: W / 2 - 21.25 * mm, y: hubY)
    static let hubR = CGPoint(x: W / 2 + 21.25 * mm, y: hubY)
    static let hubRadius = 10.5 * mm              // the core the tape is wound on, Ø 21 mm
    /// The hub's drive opening (Ø 8.4 mm) and its six teeth, 1.1 mm long and 1.3 mm wide, as on a real cassette.
    static let hubBore = 4.2, hubTooth = 1.1, hubToothWidth = 1.3
    static let window = CGRect(x: W / 2 - 156, y: hubY - 50, width: 312, height: 100)
    static let windowCorner = 22.0

    /// Radius of a pack holding `amount` seconds of tape. Wound tape is an annulus, so its area
    /// – length × thickness – grows linearly, not its radius.
    static func packRadius(_ amount: Double, of total: Double, _ length: TapeLength) -> Double {
        let area: Double   // mm², tape length × thickness
        switch length {
        case .c46: area = 69_000 * 0.0155
        case .c60: area = 90_000 * 0.0155
        case .c90: area = 135_000 * 0.0105
        }
        let r0 = hubRadius / mm
        let f = total > 0 ? min(max(amount / total, 0), 1) : 0
        return sqrt(r0 * r0 + f * area / .pi) * mm
    }

    static func titleRect(_ d: CassetteDesign) -> CGRect {
        if let b = d.skin?.spec.title { return CGRect(x: b.x * mm, y: b.y * mm, width: b.w * mm, height: b.h * mm) }
        return d.clear ? CGRect(x: 72, y: 20, width: W - 152, height: 32) : CGRect(x: 72, y: 26, width: W - 160, height: 32)
    }

    /// Double-clicking here edits the label text.
    static func labelZone(_ d: CassetteDesign) -> CGRect {
        if let b = d.skin?.spec.labelZone { return CGRect(x: b.x * mm, y: b.y * mm, width: b.w * mm, height: b.h * mm) }
        return d.clear ? CGRect(x: 24, y: 12, width: W - 48, height: 56) : CGRect(x: 18, y: 12, width: W - 36, height: 62)
    }

    static func draw(_ ctx: inout GraphicsContext, _ s: PaintState) {
        let d = s.design
        if let k = d.skin {
            drawSkin(&ctx, s, k)
            if s.writeProtected { drawBrokenTab(&ctx) }
            return
        }
        let outer = CGRect(x: 0, y: 0, width: W, height: H)
        let shellShape = Path(roundedRect: outer, cornerRadius: 16)
        let windowShape = Path(roundedRect: window, cornerRadius: windowCorner)
        var body = shellShape
        if !d.clear { body.addPath(windowShape) }
        let eo = FillStyle(eoFill: true)

        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(d.clear ? 0.25 : 0.45), radius: 16, x: 0, y: 10))
            l.fill(body, with: .linearGradient(Gradient(colors: [d.shellHi, d.shell]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: H)), style: eo)
        }
        // The window is see-through smoked plastic.
        if !d.clear { ctx.fill(windowShape, with: .color(.black.opacity(0.42))) }

        ctx.drawLayer { l in
            l.clip(to: d.clear ? Path(roundedRect: outer.insetBy(dx: 8, dy: 8), cornerRadius: 10) : windowShape)
            let rl = packRadius(s.leftAmount, of: s.total, s.length)
            let rr = packRadius(s.rightAmount, of: s.total, s.length)
            drawTapePath(&l, rl, rr, color: tapeColor(s), guides: d.clear)
            // The innermost turns on each reel are leader: the start of the side on the
            // take-up reel, its end on the supply reel.
            drawPack(&l, hubL, rl, leaderR: packRadius(min(s.leftAmount, s.leader), of: s.total, s.length))
            drawPack(&l, hubR, rr, leaderR: packRadius(min(s.rightAmount, s.leader), of: s.total, s.length))
            drawHub(&l, hubL, s.leftAngle, d)
            drawHub(&l, hubR, s.rightAngle, d)
        }

        drawLabel(&ctx, s)
        if !d.clear { drawGlass(&ctx) }
        drawHeadArea(&ctx, d, tape: tapeColor(s))
        for p in [CGPoint(x: 15, y: 15), CGPoint(x: W - 15, y: 15), CGPoint(x: 15, y: H - 15),
                  CGPoint(x: W - 15, y: H - 15), CGPoint(x: W / 2, y: 222)] {
            drawScrew(&ctx, p)
        }
        ctx.stroke(Path(roundedRect: outer.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 15.5),
                   with: .color(.white.opacity(d.clear ? 0.55 : 0.14)), lineWidth: 1.5)
        ctx.stroke(Path(roundedRect: outer.insetBy(dx: 6, dy: 6), cornerRadius: 11),
                   with: .color(.black.opacity(0.12)), lineWidth: 1)
        drawStrips(&ctx, s)
        if s.writeProtected { drawBrokenTab(&ctx) }
        drawStrokes(&ctx, s)
    }

    static func drawStrokes(_ ctx: inout GraphicsContext, _ s: PaintState) {
        guard !s.strokes.isEmpty else { return }
        ctx.drawLayer { l in
            l.clip(to: Path(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerRadius: 16))
            for st in s.strokes { drawStroke(&l, st) }
        }
    }

    /// The write-protect tab sits in the top edge, at the left of the side facing you.
    /// Broken out, it leaves a notch you can see through.
    static func drawBrokenTab(_ ctx: inout GraphicsContext) {
        let notch = CGRect(x: 7.6 * mm, y: -1, width: 4.8 * mm, height: 1.5 * mm + 1)
        let shape = Path(roundedRect: notch, cornerRadius: 0.3 * mm)
        var c = ctx
        c.blendMode = .clear
        c.fill(shape, with: .color(.black))
        // Looking into the hole: dark, darkest at the bottom.
        ctx.fill(Path(roundedRect: CGRect(x: notch.minX, y: 0, width: notch.width, height: notch.maxY), cornerRadius: 0.3 * mm), with: .linearGradient(Gradient(colors: [.black.opacity(0.35), .black.opacity(0.85)]),
                                              startPoint: CGPoint(x: 0, y: notch.minY + 1), endPoint: CGPoint(x: 0, y: notch.maxY)))
    }

    static func drawStroke(_ ctx: inout GraphicsContext, _ st: Stroke) {
        let pts = stride(from: 0, to: st.points.count - 1, by: 2).map { CGPoint(x: st.points[$0], y: st.points[$0 + 1]) }
        guard let first = pts.first else { return }
        var p = Path()
        p.move(to: first)
        if pts.count == 1 {
            p.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
        } else {
            // Run through midpoints so the line comes out smooth rather than jagged.
            for i in 1..<pts.count {
                let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                p.addQuadCurve(to: mid, control: pts[i - 1])
            }
            p.addLine(to: pts[pts.count - 1])
        }
        ctx.stroke(p, with: .color(Color(hex: st.color, alpha: 0.95)),
                   style: StrokeStyle(lineWidth: st.width, lineCap: .round, lineJoin: .round))
    }

    private static func circle(_ c: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    static let oxide = Color(hex: 0x3a2618)
    static let leaderColor = Color(hex: 0xe8e3d5, alpha: 0.85)

    /// The tape running past the heads right now: brown oxide, or pale leader at either end.
    static func tapeColor(_ s: PaintState) -> Color {
        s.rightAmount < s.leader || s.leftAmount < s.leader ? leaderColor : oxide
    }

    private static func drawPack(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: Double, leaderR: Double) {
        ctx.fill(circle(c, r), with: .radialGradient(
            Gradient(colors: [Color(hex: 0x4a3324), Color(hex: 0x2a1c13), Color(hex: 0x3b281b)]),
            center: c, startRadius: hubRadius, endRadius: r))
        for k in stride(from: hubRadius + 5, to: r - 1, by: 7) {
            ctx.stroke(circle(c, k), with: .color(.white.opacity(0.035)), lineWidth: 1)
        }
        if leaderR > hubRadius + 0.5 {
            ctx.fill(circle(c, leaderR), with: .color(leaderColor))
        }
        ctx.stroke(circle(c, r - 0.5), with: .color(Color(hex: 0x6b4a33).opacity(0.8)), lineWidth: 1)
    }

    /// Where a line from `p` touches the circle on its outer flank (`sign` −1 right reel, +1 left reel).
    static func tangent(from p: CGPoint, to c: CGPoint, radius r: Double, sign: Double) -> CGPoint {
        let dx = p.x - c.x, dy = p.y - c.y
        let d = hypot(dx, dy)
        guard d > r else { return CGPoint(x: c.x - sign * r, y: c.y) }
        let a = atan2(dy, dx) + sign * acos(r / d)
        return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }

    /// The hub: a white core (Ø 21 mm) with a toothed drive hole for the deck's spindle
    /// and the clamp that holds the end of the leader.
    private static func drawHub(_ ctx: inout GraphicsContext, _ c: CGPoint, _ angle: Double, _ d: CassetteDesign) {
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .radians(angle))
        let hub = Color(hex: 0xf3f1ea)
        let o = CGPoint.zero
        let r = hubRadius, hole = hubBore * mm
        g.fill(circle(o, r), with: .radialGradient(Gradient(colors: [Color(hex: 0xfbfaf6), hub, Color(hex: 0xd9d6cc)]),
                                                   center: o, startRadius: hole, endRadius: r))
        g.stroke(circle(o, r), with: .color(.black.opacity(0.25)), lineWidth: 0.8)
        g.stroke(circle(o, hole + 5), with: .color(.black.opacity(0.07)), lineWidth: 1)
        g.fill(circle(o, hole), with: .color(Color(hex: 0x141414).opacity(d.clear ? 0.55 : 0.85)))
        for i in 0..<6 {
            var t = g
            t.rotate(by: .degrees(Double(i) * 60))
            t.fill(Path(roundedRect: CGRect(x: -hubToothWidth / 2 * mm, y: -hole - 0.2 * mm, width: hubToothWidth * mm,
                                            height: (hubTooth + 0.2) * mm), cornerRadius: 0.25 * mm),
                   with: .color(hub))
        }
        // Leader clamp, set into the rim; also makes the turning easy to follow.
        let clamp = CGRect(x: r - 2.6 * mm, y: -1.6 * mm, width: 2.6 * mm, height: 3.2 * mm)
        g.fill(Path(roundedRect: clamp, cornerRadius: 1.5), with: .color(Color(hex: 0xd2cec2)))
        g.stroke(Path(roundedRect: clamp, cornerRadius: 1.5), with: .color(.black.opacity(0.2)), lineWidth: 0.7)
    }

    /// Tape leaves each pack on its outer flank, wraps the guide rollers in the bottom corners
    /// and runs along the front edge past the heads. Through the window you see the
    /// stretch between pack and roller.
    private static func drawTapePath(_ ctx: inout GraphicsContext, _ rl: Double, _ rr: Double, color: Color, guides: Bool) {
        let roller = 6.0
        let gL = CGPoint(x: 40, y: H - 20), gR = CGPoint(x: W - 40, y: H - 20)
        let rollerL = CGPoint(x: gL.x - roller, y: gL.y), rollerR = CGPoint(x: gR.x + roller, y: gR.y)
        var p = Path()
        p.move(to: tangent(from: rollerL, to: hubL, radius: rl, sign: 1))
        p.addLine(to: rollerL)
        p.addQuadCurve(to: CGPoint(x: gL.x, y: gL.y + roller), control: CGPoint(x: rollerL.x, y: gL.y + roller))
        p.addLine(to: CGPoint(x: gR.x, y: gR.y + roller))
        p.addQuadCurve(to: rollerR, control: CGPoint(x: rollerR.x, y: gR.y + roller))
        p.addLine(to: tangent(from: rollerR, to: hubR, radius: rr, sign: -1))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
        ctx.stroke(p, with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        if guides {
            for g in [gL, gR] {
                ctx.fill(circle(g, roller), with: .color(.white.opacity(0.85)))
                ctx.stroke(circle(g, roller), with: .color(.black.opacity(0.2)), lineWidth: 0.8)
            }
        }
    }

    private static func drawLabel(_ ctx: inout GraphicsContext, _ s: PaintState) {
        let d = s.design
        let tr = titleRect(d)
        if d.clear {
            let r = CGRect(x: 24, y: 12, width: W - 48, height: 56)
            let shape = Path(roundedRect: r, cornerRadius: 5)
            ctx.fill(shape, with: .color(d.label))
            ctx.drawLayer { l in
                l.clip(to: shape)
                l.fill(Path(CGRect(x: r.minX, y: r.maxY - 8, width: r.width, height: 8)), with: .color(d.accent))
                l.fill(Path(CGRect(x: r.minX, y: r.maxY - 11, width: r.width, height: 2.5)), with: .color(d.accent2))
            }
            let box = CGRect(x: 34, y: 20, width: 28, height: 30)
            ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(d.accent))
            ctx.draw(Text(s.side.letter).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundColor(.white),
                     at: CGPoint(x: box.midX, y: box.midY))
            ctx.fill(Path(CGRect(x: 70, y: 52, width: W - 160, height: 0.8)), with: .color(d.ink.opacity(0.22)))
            ctx.draw(Text(s.length.label).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(d.ink),
                     at: CGPoint(x: W - 58, y: 30))
            ctx.draw(Text("2×\(s.length.rawValue / 2) MIN").font(.system(size: 7, weight: .bold)).kerning(0.8)
                        .foregroundColor(d.ink.opacity(0.6)), at: CGPoint(x: W - 58, y: 46))
        } else {
            let r = CGRect(x: 18, y: 12, width: W - 36, height: 202)
            var shape = Path(roundedRect: r, cornerRadius: 7)
            shape.addPath(Path(roundedRect: window.insetBy(dx: -4, dy: -4), cornerRadius: windowCorner + 4))
            ctx.fill(shape, with: .color(d.label), style: FillStyle(eoFill: true))
            ctx.draw(Text(s.side.letter).font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundColor(d.accent),
                     at: CGPoint(x: 46, y: 43))
            ctx.fill(Path(CGRect(x: 72, y: 62, width: W - 160, height: 0.8)), with: .color(d.ink.opacity(0.22)))
            ctx.draw(Text(s.length.label).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundColor(d.ink),
                     at: CGPoint(x: W - 52, y: 36))
            ctx.draw(Text("2×\(s.length.rawValue / 2) MIN").font(.system(size: 7, weight: .bold)).kerning(0.8)
                        .foregroundColor(d.ink.opacity(0.6)), at: CGPoint(x: W - 52, y: 54))
            let band = CGRect(x: r.minX, y: 186, width: r.width, height: 20)
            ctx.fill(Path(band), with: .color(d.accent))
            if d.id == "chrome" {
                ctx.fill(Path(CGRect(x: r.minX, y: 207.5, width: r.width, height: 3)), with: .color(d.accent2))
            }
            if d.id == "metal" {
                ctx.fill(Path(CGRect(x: r.minX + 10, y: 208.5, width: r.width - 20, height: 1)), with: .color(d.accent))
            }
            ctx.draw(Text(d.typeText).font(.system(size: 8.5, weight: .bold)).kerning(1.6)
                        .foregroundColor(d.id == "metal" ? .black : .white),
                     at: CGPoint(x: W / 2, y: band.midY))
        }

        drawTitle(&ctx, s, rect: tr)
    }

    static func drawTitle(_ ctx: inout GraphicsContext, _ s: PaintState, rect tr: CGRect) {
        let d = s.design
        // Titles go on label tape; an empty label only shows how to make one.
        if !s.hideTitle && s.strips.isEmpty && s.hint {
            ctx.draw(Text(L("Doppelklick zum Beschriften")).font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(d.pen.opacity(0.35)),
                     at: CGPoint(x: tr.minX + 4, y: tr.midY + 1), anchor: .leading)
        }
    }

    private static func drawGlass(_ ctx: inout GraphicsContext) {
        let shape = Path(roundedRect: window, cornerRadius: windowCorner)
        ctx.drawLayer { l in
            l.clip(to: shape)
            var refl = Path()
            refl.move(to: CGPoint(x: window.minX + 70, y: window.minY))
            refl.addLine(to: CGPoint(x: window.minX + 130, y: window.minY))
            refl.addLine(to: CGPoint(x: window.minX + 90, y: window.maxY))
            refl.addLine(to: CGPoint(x: window.minX + 30, y: window.maxY))
            refl.closeSubpath()
            l.fill(refl, with: .color(.white.opacity(0.06)))
        }
        ctx.stroke(shape, with: .color(.black.opacity(0.5)), lineWidth: 1.5)
        ctx.stroke(Path(roundedRect: window.insetBy(dx: 1.5, dy: 1.5), cornerRadius: windowCorner - 1.5),
                   with: .color(.white.opacity(0.08)), lineWidth: 1)
    }

    private static func drawHeadArea(_ ctx: inout GraphicsContext, _ d: CassetteDesign, tape: Color) {
        var trap = Path()
        trap.move(to: CGPoint(x: W / 2 - 142, y: H))
        trap.addLine(to: CGPoint(x: W / 2 - 120, y: H - 50))
        trap.addLine(to: CGPoint(x: W / 2 + 120, y: H - 50))
        trap.addLine(to: CGPoint(x: W / 2 + 142, y: H))
        trap.closeSubpath()
        ctx.drawLayer { l in
            l.clip(to: Path(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerRadius: 16))
            l.fill(trap, with: .color(.black.opacity(d.clear ? 0.10 : 0.16)))
        }
        var edge = Path()
        edge.move(to: CGPoint(x: W / 2 - 142, y: H))
        edge.addLine(to: CGPoint(x: W / 2 - 120, y: H - 50))
        edge.addLine(to: CGPoint(x: W / 2 + 120, y: H - 50))
        edge.addLine(to: CGPoint(x: W / 2 + 142, y: H))
        ctx.stroke(edge, with: .color(.white.opacity(0.12)), lineWidth: 1)

        var holes = Path()
        holes.addRoundedRect(in: CGRect(x: W / 2 - 18, y: H - 22, width: 36, height: 22), cornerSize: CGSize(width: 2, height: 2))
        for sx in [-1.0, 1.0] {
            holes.addRoundedRect(in: CGRect(x: W / 2 + sx * 70 - 12, y: H - 20, width: 24, height: 20), cornerSize: CGSize(width: 2, height: 2))
            holes.addEllipse(in: CGRect(x: W / 2 + sx * 104 - 5.5, y: H - 34, width: 11, height: 11))
            holes.addEllipse(in: CGRect(x: W / 2 + sx * 156 - 5, y: H - 26, width: 10, height: 10))
        }
        ctx.fill(holes, with: .color(.black.opacity(d.clear ? 0.55 : 0.85)))
        // The tape itself, glimpsed through the head openings.
        ctx.drawLayer { l in
            l.clip(to: holes)
            l.fill(Path(CGRect(x: W / 2 - 140, y: H - 15.6, width: 280, height: 3.2)), with: .color(tape))
        }
    }

    private static func drawScrew(_ ctx: inout GraphicsContext, _ c: CGPoint) {
        let r = 5.5
        ctx.fill(circle(c, r), with: .radialGradient(Gradient(colors: [Color(white: 0.92), Color(white: 0.55)]),
                                                     center: CGPoint(x: c.x - 1.5, y: c.y - 1.5), startRadius: 0, endRadius: r))
        ctx.stroke(circle(c, r), with: .color(.black.opacity(0.35)), lineWidth: 0.6)
        var x = Path()
        x.move(to: CGPoint(x: c.x - 3, y: c.y))
        x.addLine(to: CGPoint(x: c.x + 3, y: c.y))
        x.move(to: CGPoint(x: c.x, y: c.y - 3))
        x.addLine(to: CGPoint(x: c.x, y: c.y + 3))
        ctx.stroke(x, with: .color(.black.opacity(0.5)), lineWidth: 1.1)
    }
}
