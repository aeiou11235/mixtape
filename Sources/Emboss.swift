import AppKit
import SwiftUI

/// A strip of embossed plastic label tape, stuck on instead of handwriting: coloured tape,
/// raised capitals pressed in by a hand embosser. It can be moved and turned anywhere on the cassette.
struct EmbossedTape: Codable, Equatable {
    var color: UInt32
    /// Centre of the strip and its turn in degrees; nil until it has been moved.
    var x: Double?
    var y: Double?
    var angle: Double?
    /// What was pressed at each position; nil for strips from before overstriking existed.
    var cells: [String]?
}

extension Painter {
    /// Black, red, blue, green, yellow, fluorescent pink, orange and green; then the odd ones:
    /// gold, silver, clear, maroon, olive, lavender, petrol and brown.
    static let embossColors: [UInt32] = [0x161618, 0xd8212a, 0x1846c8, 0x12853f, 0xf0c419, 0xff2d8a, 0xff6a1a, 0x3ddc3a,
                                         0xc9a43c, 0xb4b8be, clearTape, 0x6d1a24, 0x7f8b2b, 0xa98be0, 0x0e7c86, 0x6b4426]
    /// Clear tape has no colour of its own; marked outside the RGB bits.
    static let clearTape: UInt32 = 0x01ff_ffff
    static func isClearTape(_ c: UInt32) -> Bool { c >> 24 == 1 }
    /// Typing happens in an ordinary text field; this font is only for that.
    static let embossFont = "DINCondensed-Bold"
    static let embossSize: CGFloat = 19
    static let embossPad: CGFloat = 11
    static let embossHeight: CGFloat = 31

    /// The embosser's letters: strokes on a 6 × 10 grid, from emboss-glyphs.json (shared with the web player).
    static let embossGlyphs: [Character: Path] = {
        guard let url = Bundle.main.url(forResource: "emboss-glyphs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var out: [Character: Path] = [:]
        for (k, v) in table { if let c = k.first { out[c] = glyphPath(v) } }
        return out
    }()
    static let glyphUnit: CGFloat = 1.3          // points per grid step: capitals 13 pt high
    static let glyphPitch: CGFloat = 11.3         // every letter takes the same room, like on the embosser's wheel
    static let glyphStroke: CGFloat = 1.65

    /// Absolute M, L, C and Z, which is all the glyph table uses.
    private static func glyphPath(_ d: String) -> Path {
        var p = Path()
        var nums: [CGFloat] = []
        var cmd: Character = "M"
        func flush() {
            switch cmd {
            case "M": if nums.count >= 2 { p.move(to: CGPoint(x: nums[0], y: nums[1])) }
            case "L": if nums.count >= 2 { p.addLine(to: CGPoint(x: nums[0], y: nums[1])) }
            case "C": if nums.count >= 6 {
                p.addCurve(to: CGPoint(x: nums[4], y: nums[5]), control1: CGPoint(x: nums[0], y: nums[1]),
                           control2: CGPoint(x: nums[2], y: nums[3]))
            }
            default: break
            }
            nums = []
        }
        var token = ""
        for ch in d + " " {
            if ch.isLetter {
                if let v = Double(token) { nums.append(CGFloat(v)) }
                token = ""
                flush()
                if ch == "Z" { p.closeSubpath() }
                cmd = ch
            } else if ch == "," || ch == " " || (ch == "-" && !token.isEmpty) {
                if let v = Double(token) { nums.append(CGFloat(v)) }
                token = ch == "-" ? "-" : ""
            } else {
                token.append(ch)
            }
        }
        flush()
        return p
    }

    /// What the embosser can press: capitals; ß becomes SS, anything it doesn't have a space.
    static func embossChars(_ title: String) -> [Character] {
        Array(title.uppercased().replacingOccurrences(of: "ß", with: "SS"))
    }

    struct EmbossFrame {
        var center: CGPoint
        var size: CGSize
        var angle: Double   // degrees
    }

    /// The pressed positions on a strip: each holds every letter pressed there, in order,
    /// so a letter pressed twice sits deeper and two different ones lie on top of each other.
    static func cells(of text: String) -> [String] {
        embossChars(text).map { $0 == " " ? "" : String($0) }
    }

    /// What a strip reads as text: the last letter pressed at each position.
    static func embossText(_ cells: [String]) -> String {
        cells.map { $0.last.map(String.init) ?? " " }.joined().trimmingCharacters(in: .whitespaces)
    }

    /// How many letters fit on a strip.
    static func embossMaxCells(_ d: CassetteDesign) -> Int {
        Int((titleRect(d).width + 8 - 2 * embossPad + (glyphPitch - 6) * glyphUnit) / (glyphPitch * glyphUnit))
    }

    /// The left end of a strip being pressed: it stays put while the strip grows out of the embosser.
    struct EmbossAnchor: Equatable {
        var point: CGPoint
        var angle: Double
    }

    static func anchor(of f: EmbossFrame) -> EmbossAnchor {
        let r = f.angle * .pi / 180
        return EmbossAnchor(point: CGPoint(x: f.center.x - cos(r) * f.size.width / 2, y: f.center.y - sin(r) * f.size.width / 2),
                            angle: f.angle)
    }

    /// Where strip number `index` sits. While it is being pressed (`cursor` set) it is one position
    /// longer than the cursor, growing from `anchor`, or from the title line if it has no place yet.
    /// Strips that were never moved line up from the title line downwards.
    static func stripFrame(_ t: EmbossedTape, index: Int, cells: [String], design: CassetteDesign,
                           cursor: Int? = nil, anchor: EmbossAnchor? = nil) -> EmbossFrame {
        let n = CGFloat(cursor.map { max(cells.count, $0 + 1) } ?? cells.count)
        let w = min(max(n * glyphPitch - (glyphPitch - 6), 0) * glyphUnit + 2 * embossPad, W)
        let size = CGSize(width: w, height: embossHeight)
        if let a = anchor {
            let r = a.angle * .pi / 180
            return EmbossFrame(center: CGPoint(x: a.point.x + cos(r) * w / 2, y: a.point.y + sin(r) * w / 2), size: size, angle: a.angle)
        }
        if cursor == nil, let x = t.x, let y = t.y {
            return EmbossFrame(center: CGPoint(x: x, y: y), size: size, angle: t.angle ?? 0)
        }
        let tr = titleRect(design)
        // Stuck on by hand: never quite straight.
        let seed = embossText(cells).unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return EmbossFrame(center: CGPoint(x: tr.minX - 4 + w / 2, y: min(tr.midY + 1 + CGFloat(index) * 36, H - 20)), size: size,
                           angle: cursor != nil ? 0 : Double(seed % 21 - 10) * 0.12)
    }

    /// Repeatable randomness for one press: the same letter at the same place always lands the same way.
    /// The web player computes exactly the same numbers.
    static func pressNoise(_ i: Int, _ k: Int, _ code: UInt32) -> () -> CGFloat {
        var h = UInt32(truncatingIfNeeded: i) &* 73856093 ^ UInt32(truncatingIfNeeded: k) &* 19349663 ^ code &* 83492791
        if h == 0 { h = 1 }
        return {
            h ^= h << 13; h ^= h >> 17; h ^= h << 5
            return CGFloat(h % 10_000) / 10_000
        }
    }

    /// The corner of the strip under `p` (0 top left, 1 top right, 2 bottom right, 3 bottom left), if any:
    /// dragging there turns the strip.
    static func embossCorner(_ f: EmbossFrame, _ p: CGPoint) -> Int? {
        let a = -f.angle * .pi / 180
        let dx = p.x - f.center.x, dy = p.y - f.center.y
        let lx = dx * cos(a) - dy * sin(a), ly = dx * sin(a) + dy * cos(a)
        let w = f.size.width / 2, h = f.size.height / 2
        for (k, c) in [(-w, -h), (w, -h), (w, h), (-w, h)].enumerated() where hypot(lx - c.0, ly - c.1) < 9 { return k }
        return nil
    }

    /// Whether a strip would cover a hub hole: on a real cassette that blocks the deck's spindle,
    /// so the tape wouldn't play.
    static func stripCoversHub(_ f: EmbossFrame, _ d: CassetteDesign) -> Bool {
        let hy = (d.skin?.spec.hubY).map { $0 * mm } ?? hubY
        let r = 6.0 * mm
        let a = -f.angle * .pi / 180
        for c in [CGPoint(x: hubL.x, y: hy), CGPoint(x: hubR.x, y: hy)] {
            let dx = c.x - f.center.x, dy = c.y - f.center.y
            let lx = dx * cos(a) - dy * sin(a), ly = dx * sin(a) + dy * cos(a)
            let nx = min(max(lx, -f.size.width / 2), f.size.width / 2), ny = min(max(ly, -f.size.height / 2), f.size.height / 2)
            if hypot(lx - nx, ly - ny) < r { return true }
        }
        return false
    }

    /// The nearest place up or down where the strip leaves the hub holes free.
    static func clearOfHubs(_ f: EmbossFrame, _ d: CassetteDesign) -> EmbossFrame {
        guard stripCoversHub(f, d) else { return f }
        for step in stride(from: 4.0, through: 160, by: 4) {
            for sign in [1.0, -1.0] {
                var g = f
                g.center.y = f.center.y + sign * step
                if g.center.y > 8, g.center.y < H - 8, !stripCoversHub(g, d) { return g }
            }
        }
        return f
    }

    static func embossContains(_ f: EmbossFrame, _ p: CGPoint) -> Bool {
        let a = -f.angle * .pi / 180
        let dx = p.x - f.center.x, dy = p.y - f.center.y
        let lx = dx * cos(a) - dy * sin(a), ly = dx * sin(a) + dy * cos(a)
        return abs(lx) <= f.size.width / 2 + 3 && abs(ly) <= f.size.height / 2 + 3
    }

    /// The raised letters come out pale where the plastic is stretched.
    static func embossLetterColor(_ c: UInt32, _ k: Double = 0.8) -> Color {
        let r = Double((c >> 16) & 0xff) / 255, g = Double((c >> 8) & 0xff) / 255, b = Double(c & 0xff) / 255
        return Color(.sRGB, red: r + (1 - r) * k, green: g + (1 - g) * k, blue: b + (1 - b) * k, opacity: 1)
    }

    /// All strips on the side facing up; the one being pressed on top.
    static func drawStrips(_ ctx: inout GraphicsContext, _ s: PaintState) {
        for (i, t) in s.strips.enumerated() where i != s.editingStrip {
            let cells = t.cells ?? []
            guard cells.contains(where: { !$0.isEmpty }) else { continue }
            let f = stripFrame(t, index: i, cells: cells, design: s.design)
            drawStrip(&ctx, t, cells, f, cursor: nil, corner: s.hoverStrip == i ? s.embossCorner : nil)
        }
        if let i = s.editingStrip, i < s.strips.count, let cells = s.embossCells {
            let t = s.strips[i]
            let f = stripFrame(t, index: i, cells: cells, design: s.design, cursor: s.embossCursor, anchor: s.editAnchor)
            drawStrip(&ctx, t, cells, f, cursor: s.embossCursorVisible ? s.embossCursor : nil, corner: s.hoverStrip == i ? s.embossCorner : nil)
        }
    }

    private static func drawStrip(_ ctx: inout GraphicsContext, _ t: EmbossedTape, _ cells: [String], _ f: EmbossFrame,
                                  cursor: Int?, corner: Int?) {
        var g = ctx
        g.translateBy(x: f.center.x, y: f.center.y)
        g.rotate(by: .degrees(f.angle))
        let strip = CGRect(x: -f.size.width / 2, y: -f.size.height / 2, width: f.size.width, height: f.size.height)
        let shape = Path(roundedRect: strip, cornerRadius: 1.2)
        let clear = isClearTape(t.color)
        g.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(clear ? 0.2 : 0.45), radius: 1.6, x: 0, y: 1.2))
            l.fill(shape, with: .color(clear ? .white.opacity(0.16) : Color(hex: t.color)))
        }
        if clear { g.stroke(shape, with: .color(.white.opacity(0.5)), lineWidth: 0.8) }
        // A slightly curved plastic surface: light along the top, darker towards the bottom.
        g.fill(shape, with: .linearGradient(Gradient(stops: [
            .init(color: .white.opacity(0.22), location: 0), .init(color: .white.opacity(0.05), location: 0.3),
            .init(color: .clear, location: 0.6), .init(color: .black.opacity(0.22), location: 1)]),
            startPoint: CGPoint(x: 0, y: strip.minY), endPoint: CGPoint(x: 0, y: strip.maxY)))
        g.fill(Path(CGRect(x: strip.minX + 1, y: strip.minY + 2, width: strip.width - 2, height: 0.8)), with: .color(.white.opacity(0.2)))
        g.stroke(shape, with: .color(.black.opacity(0.3)), lineWidth: 0.6)

        let u = glyphUnit, sw = glyphStroke
        var l = g
        l.clip(to: shape)
        for (i, cell) in cells.enumerated() {
            for (k, ch) in cell.enumerated() {
                guard let glyph = embossGlyphs[ch] else { continue }
                // Each press lands a little differently: height, turn, depth; a second press never
                // quite meets the first.
                let r = pressNoise(i, k, ch.unicodeScalars.first?.value ?? 0)
                let dy = (r() - 0.5) * 1.3, rot = (r() - 0.5) * 3.2, depth = 0.6 + r() * 0.4
                let dx = (r() - 0.5) * 0.6 + (k > 0 ? (r() - 0.5) * 0.9 : 0)
                let x = strip.minX + embossPad + CGFloat(i) * glyphPitch * u + dx
                var c = l
                c.translateBy(x: x + 3 * u, y: dy)
                c.rotate(by: .degrees(rot))
                c.translateBy(x: -3 * u, y: -5 * u)
                c.scaleBy(x: u, y: u)
                func stroke(_ color: Color, width: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) {
                    var o = c
                    o.translateBy(x: dx / u, y: dy / u)
                    o.stroke(glyph, with: .color(color), style: StrokeStyle(lineWidth: width / u, lineCap: .round, lineJoin: .round))
                }
                // Stress whitening around the letter, the dent's shadow, the lit edge, then the raised letter.
                stroke(.white.opacity(0.07 * depth), width: sw * 3.2)
                stroke(.black.opacity(0.55 * depth), width: sw + 0.5, dx: 0.55, dy: 0.75)
                stroke(.white.opacity(0.75 * depth), width: sw, dx: -0.4, dy: -0.5)
                stroke(embossLetterColor(t.color, 0.62 + 0.25 * Double(depth)), width: sw)
                stroke(.white.opacity(0.45 * depth), width: sw * 0.35, dx: -0.25, dy: -0.3)
            }
        }
        // At the corner under the pointer, a small ring: drag there to turn the strip.
        if let k = corner {
            let c = [CGPoint(x: strip.minX, y: strip.minY), CGPoint(x: strip.maxX, y: strip.minY),
                     CGPoint(x: strip.maxX, y: strip.maxY), CGPoint(x: strip.minX, y: strip.maxY)][k]
            let ring = Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
            g.stroke(ring, with: .color(.black.opacity(0.45)), lineWidth: 3)
            g.stroke(ring, with: .color(.white.opacity(0.95)), lineWidth: 1.5)
        }
        // The blinking block cursor, like on an old home computer.
        if let cur = cursor {
            let x = strip.minX + embossPad + CGFloat(cur) * glyphPitch * u - 0.8 * u
            l.fill(Path(CGRect(x: x, y: -6.2 * u, width: 7.6 * u, height: 12.4 * u)), with: .color(embossLetterColor(t.color, 0.9).opacity(0.85)))
        }
    }
}
