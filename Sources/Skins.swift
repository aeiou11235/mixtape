import AppKit
import ImageIO
import SwiftUI

/// One tape design from an add-on. It is two pictures of the cassette – what lies behind the
/// reels, and everything in front of them – and the app draws the turning reels, the tape and
/// the label text between and over them. Positions are in millimetres on the 100.4 × 63.8 mm
/// shell, so a design doesn't depend on the size the app draws at. docs/ADDONS.md describes it.
struct SkinSpec: Codable {
    struct Box: Codable {
        var x, y, w, h: Double
    }
    /// Text the app writes on the label: the side letter, the tape length, or fixed text.
    struct Label: Codable {
        var kind: String            // "side", "length" (C60), "total" (60 MIN), "minutes" (2×30 MIN) or "text"
        var text: String?
        var x, y, size: Double      // y is the middle of the line
        var font: String?
        var color: String
        var prefix: String?         // fixed text in front, e.g. "MX-" before "C60"
        var prefixColor: String?
        var tracking: Double?
        var align: String?          // "left" (default), "center" or "right"
    }
    var id: String
    var name: String
    var back: String                // picture behind the reels
    var front: String               // picture in front of them, transparent where they show
    var margin: Double              // picture around the shell on every side, for its shadow
    var hubY: Double?
    var hubColor: String?
    var rollers: [Double]?          // left x, y, right x, y, radius: where the tape turns
    var pen: String
    var title: Box
    var labelZone: Box
    var labels: [Label]?
}

struct SkinPackSpec: Codable {
    var format: Int
    var id: String
    var name: String
    var author: String?
    var version: String?
    var designs: [SkinSpec]
}

final class Skin {
    let id: String                  // "<pack id>/<design id>", what a tape stores
    let spec: SkinSpec
    let pack: SkinPackSpec
    let backURL: URL, frontURL: URL
    let back: CGImage, front: CGImage

    init(spec: SkinSpec, pack: SkinPackSpec, dir: URL) throws {
        guard SkinStore.validID(spec.id), let b = SkinStore.inside(dir, spec.back), let f = SkinStore.inside(dir, spec.front),
              spec.margin >= 0, spec.margin < 30 else {
            throw SkinError.invalid
        }
        id = pack.id + "/" + spec.id
        self.spec = spec
        self.pack = pack
        backURL = b
        frontURL = f
        back = try Self.image(b)
        front = try Self.image(f)
    }

    private static func image(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width <= 4000, img.height <= 4000 else { throw SkinError.invalid }
        return img
    }

    var design: CassetteDesign {
        let pen = Color(hexString: spec.pen) ?? Color(hex: 0x1c3f94)
        return CassetteDesign(id: id, name: spec.name, shell: .black, shellHi: .black, clear: false, label: .white,
                              accent: pen, accent2: pen, ink: .black, pen: pen, typeText: "", skin: self)
    }

    /// Writes this design alone as a pack, so a tape can carry the look it was made with.
    func export(to dir: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = spec
        s.back = "back.png"
        s.front = "front.png"
        var p = pack
        p.designs = [s]
        try fm.copyItem(at: backURL, to: dir.appendingPathComponent("back.png"))
        try fm.copyItem(at: frontURL, to: dir.appendingPathComponent("front.png"))
        try JSONEncoder().encode(p).write(to: dir.appendingPathComponent("pack.json"))
    }
}

enum SkinError: LocalizedError {
    case invalid
    var errorDescription: String? { L("Das ist kein gültiges Kassetten-Design.") }
}

/// The installed add-ons, plus designs that arrived inside a tape someone sent.
final class SkinStore {
    nonisolated(unsafe) static let shared = SkinStore()

    struct Pack {
        let spec: SkinPackSpec
        let skins: [Skin]
    }

    private(set) var packs: [Pack] = []
    private var embedded: [String: Skin] = [:]

    /// Development test modes point this at a temporary folder so they never touch the real one.
    nonisolated(unsafe) static var folderOverride: URL?

    static var folder: URL {
        folderOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mixtape/Designs", isDirectory: true)
    }

    func skin(_ id: String) -> Skin? {
        for p in packs { if let s = p.skins.first(where: { $0.id == id }) { return s } }
        return embedded[id]
    }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        packs = dirs.compactMap { try? Self.load($0) }.sorted { $0.spec.name.localizedStandardCompare($1.spec.name) == .orderedAscending }
    }

    /// Unpacks a .mixtapeskins file into the designs folder, replacing an older version of the same pack.
    func install(_ url: URL) throws -> Pack {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("skins-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size < 200_000_000, try Self.safeZip(url) else { throw SkinError.invalid }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do { try TapeDocument.run("/usr/bin/ditto", "-x", "-k", url.path, tmp.path) } catch { throw SkinError.invalid }
        // The pack may sit at the top of the archive or in a single folder inside it.
        var root = tmp
        if !fm.fileExists(atPath: tmp.appendingPathComponent("pack.json").path) {
            let inner = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil))?.filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
            guard inner.count == 1 else { throw SkinError.invalid }
            root = inner[0]
        }
        let pack = try Self.load(root)
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let dest = Self.folder.appendingPathComponent(pack.spec.id, isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: root, to: dest)
        reload()
        return packs.first { $0.spec.id == pack.spec.id } ?? pack
    }

    /// The designs the app comes with, unpacked in its Resources.
    static func builtIn() -> Pack? {
        guard let dir = Bundle.main.url(forResource: "base", withExtension: nil, subdirectory: "Designs") else { return nil }
        return try? load(dir)
    }

    /// A design that came inside a tape. An installed one with the same name wins.
    func addEmbedded(_ dir: URL) {
        guard let pack = try? Self.load(dir) else { return }
        for s in pack.skins where skin(s.id) == nil { embedded[s.id] = s }
    }

    private static func load(_ dir: URL) throws -> Pack {
        let json = try Data(contentsOf: dir.appendingPathComponent("pack.json"))
        let spec = try JSONDecoder().decode(SkinPackSpec.self, from: json)
        guard spec.format == 1, validID(spec.id), !spec.designs.isEmpty, spec.designs.count <= 100 else { throw SkinError.invalid }
        return Pack(spec: spec, skins: try spec.designs.map { try Skin(spec: $0, pack: spec, dir: dir) })
    }

    static func validID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } && !s.hasPrefix(".")
    }

    /// A picture's path must stay inside the pack.
    static func inside(_ dir: URL, _ path: String) -> URL? {
        let parts = path.split(separator: "/")
        guard !parts.isEmpty, parts.count <= 2, path.lowercased().hasSuffix(".png"),
              parts.allSatisfy({ !$0.hasPrefix(".") && !$0.contains("\\") }) else { return nil }
        return dir.appendingPathComponent(path)
    }

    /// Refuses archives whose entries would land outside the folder they are unpacked into.
    private static func safeZip(_ url: URL) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-1", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let names = String(decoding: out, as: UTF8.self).split(separator: "\n")
        return names.count < 1000 && names.allSatisfy { !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }
    }
}

extension Color {
    /// "#rgb", "#rrggbb" or "#rrggbbaa".
    init?(hexString s: String) {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        if h.count == 6 { self.init(hex: UInt32(v)) }
        else { self.init(hex: UInt32(v >> 8), alpha: Double(v & 0xff) / 255) }
    }
}

extension Painter {
    /// A design from an add-on: back picture, reels and tape, front picture, then the label text.
    static func drawSkin(_ ctx: inout GraphicsContext, _ s: PaintState, _ k: Skin) {
        let sp = k.spec, m = sp.margin * mm
        let pic = CGRect(x: -m, y: -m, width: W + 2 * m, height: H + 2 * m)
        ctx.draw(Image(decorative: k.back, scale: 1), in: pic)

        let hy = (sp.hubY ?? 28.3) * mm
        let cl = CGPoint(x: hubL.x, y: hy), cr = CGPoint(x: hubR.x, y: hy)
        let rl = packRadius(s.leftAmount, of: s.total, s.length)
        let rr = packRadius(s.rightAmount, of: s.total, s.length)
        let ro = sp.rollers ?? [8.6, 60.8, 91.8, 60.8, 1.7]
        if ro.count == 5 {
            let r = ro[4] * mm
            let gL = CGPoint(x: ro[0] * mm, y: ro[1] * mm), gR = CGPoint(x: ro[2] * mm, y: ro[3] * mm)
            let outL = CGPoint(x: gL.x - r, y: gL.y), outR = CGPoint(x: gR.x + r, y: gR.y)
            var p = Path()
            p.move(to: tangent(from: outL, to: cl, radius: rl, sign: 1))
            p.addLine(to: outL)
            p.addQuadCurve(to: CGPoint(x: gL.x, y: gL.y + r), control: CGPoint(x: outL.x, y: gL.y + r))
            p.addLine(to: CGPoint(x: gR.x, y: gR.y + r))
            p.addQuadCurve(to: outR, control: CGPoint(x: outR.x, y: gR.y + r))
            p.addLine(to: tangent(from: outR, to: cr, radius: rr, sign: -1))
            let tape = tapeColor(s)
            ctx.stroke(p, with: .color(tape), style: StrokeStyle(lineWidth: 0.62 * mm, lineCap: .round, lineJoin: .round))
            if tape != leaderColor {
                ctx.stroke(p, with: .color(Color(hex: 0xb5532a, alpha: 0.7)), style: StrokeStyle(lineWidth: 0.22 * mm, lineCap: .round, lineJoin: .round))
            }
        }
        drawSkinPack(&ctx, cl, rl, leaderR: packRadius(min(s.leftAmount, s.leader), of: s.total, s.length))
        drawSkinPack(&ctx, cr, rr, leaderR: packRadius(min(s.rightAmount, s.leader), of: s.total, s.length))
        let hub = sp.hubColor.flatMap { Color(hexString: $0) } ?? Color(hex: 0xf3f1ea)
        drawSkinHub(&ctx, cl, s.leftAngle, hub)
        drawSkinHub(&ctx, cr, s.rightAngle, hub)

        ctx.draw(Image(decorative: k.front, scale: 1), in: pic)

        for t in sp.labels ?? [] {
            let str: String
            switch t.kind {
            case "side": str = s.side.letter
            case "length": str = s.length.label
            case "minutes": str = "2×\(s.length.rawValue / 2) MIN"
            case "total": str = "\(s.length.rawValue) MIN"
            default: str = t.text ?? ""
            }
            let font = Font.custom(t.font ?? "Futura-Bold", size: t.size * mm)
            let kern = (t.tracking ?? 0) * mm
            let color = Color(hexString: t.color) ?? .black
            var text = Text(str).font(font).kerning(kern).foregroundColor(color)
            if let pre = t.prefix {
                text = Text(pre).font(font).kerning(kern).foregroundColor(t.prefixColor.flatMap { Color(hexString: $0) } ?? color) + text
            }
            let anchor: UnitPoint = t.align == "center" ? .center : t.align == "right" ? .trailing : .leading
            ctx.draw(text, at: CGPoint(x: t.x * mm, y: t.y * mm), anchor: anchor)
        }
        drawTitle(&ctx, s, rect: titleRect(s.design))
        drawStrips(&ctx, s)
        drawStrokes(&ctx, s)
    }

    /// Wound tape: dark oxide with fine turns and a soft sheen.
    private static func drawSkinPack(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: Double, leaderR: Double) {
        let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(disc, with: .radialGradient(Gradient(colors: [Color(hex: 0x3a2618), Color(hex: 0x24170f), Color(hex: 0x33221a)]),
                                             center: c, startRadius: hubRadius, endRadius: r))
        var k = hubRadius + 1.5, i = 0
        while k < r - 0.8 {
            let ring = Path(ellipseIn: CGRect(x: c.x - k, y: c.y - k, width: 2 * k, height: 2 * k))
            let light = (i * 7919) % 5
            ctx.stroke(ring, with: .color(light < 2 ? Color(hex: 0xa07a5a, alpha: 0.10) : .black.opacity(0.08)), lineWidth: 0.7)
            k += 1.6 + Double((i * 104729) % 7) * 0.35
            i += 1
        }
        if leaderR > hubRadius + 0.5 {
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - leaderR, y: c.y - leaderR, width: 2 * leaderR, height: 2 * leaderR)),
                     with: .color(leaderColor))
        }
        ctx.fill(disc, with: .linearGradient(Gradient(stops: [
            .init(color: .white.opacity(0), location: 0.2), .init(color: Color(hex: 0xc9a27c, alpha: 0.22), location: 0.45),
            .init(color: .white.opacity(0), location: 0.55), .init(color: .black.opacity(0.22), location: 0.85)]),
            startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)))
    }

    /// The hub as you see it through the shell's hole: white core, toothed drive hole, leader clamp.
    private static func drawSkinHub(_ ctx: inout GraphicsContext, _ c: CGPoint, _ angle: Double, _ color: Color) {
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .radians(angle))
        func ring(_ r: Double) -> Path { Path(ellipseIn: CGRect(x: -r * mm, y: -r * mm, width: 2 * r * mm, height: 2 * r * mm)) }
        g.fill(ring(10.6), with: .color(color))
        g.fill(ring(10.6), with: .radialGradient(Gradient(colors: [.white.opacity(0.25), .black.opacity(0.18)]),
                                                 center: CGPoint(x: -2 * mm, y: -2.5 * mm), startRadius: 0, endRadius: 12 * mm))
        g.stroke(ring(8.2), with: .color(.black.opacity(0.10)), lineWidth: 0.35 * mm)
        g.stroke(ring(5.0), with: .color(.black.opacity(0.12)), lineWidth: 0.25 * mm)
        g.fill(Path(roundedRect: CGRect(x: 9.2 * mm, y: -1.4 * mm, width: 1.6 * mm, height: 2.8 * mm), cornerRadius: 0.3 * mm),
               with: .color(.black.opacity(0.18)))
        g.fill(ring(hubBore), with: .color(Color(hex: 0x0d0c0b)))
        for i in 0..<6 {
            var t = g
            t.rotate(by: .degrees(Double(i) * 60))
            t.fill(Path(roundedRect: CGRect(x: -hubToothWidth / 2 * mm, y: -(hubBore + 0.2) * mm, width: hubToothWidth * mm,
                                            height: (hubTooth + 0.2) * mm), cornerRadius: 0.25 * mm),
                   with: .color(color))
        }
    }
}
