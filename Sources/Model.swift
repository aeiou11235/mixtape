import Foundation

enum Side: String, Codable {
    case a, b
    var letter: String { rawValue.uppercased() }
    var other: Side { self == .a ? .b : .a }
}

enum TapeLength: Int, Codable, CaseIterable {
    case c46 = 46, c60 = 60, c90 = 90
    /// Each side holds half of the total running time.
    var sideSeconds: Double { Double(rawValue) * 30 }
    var label: String { "C\(rawValue)" }
    /// Clear leader tape at both ends of a side: it carries no sound and can't be recorded on.
    static let leaderSeconds = 4.0
}

/// The tape's character on playback. Stored in the tape, so the sender's choice travels
/// with it, but whoever has the cassette can change it. Nothing here is baked into the audio.
struct SoundSettings: Codable, Equatable {
    var hiss = true     // Bandrauschen
    var wow = true      // Leiern
    var tone = true     // dull top end of tape
    var spool = true    // whirr while winding
    var clicks = true   // key clunks
}

/// A stretch of recorded audio on one side of the tape.
struct Segment: Codable, Equatable {
    var start: Double       // position on the side, in seconds
    var duration: Double
    var file: String        // audio file inside the tape archive
    var fileOffset: Double  // where in that file this segment begins
    var end: Double { start + duration }
}

/// A pen stroke drawn onto the cassette, in cassette coordinates (440 × 278).
struct Stroke: Codable, Equatable {
    var color: UInt32
    var width: Double
    var points: [Double]    // x0, y0, x1, y1, …
}

struct TapeData: Codable {
    var version = 1
    var length: TapeLength
    var design: String
    var titleA = ""
    var titleB = ""
    var sideA: [Segment] = []
    var sideB: [Segment] = []
    var drawingA: [Stroke] = []
    var drawingB: [Stroke] = []
    /// Physical tape position, in seconds from the beginning of side A.
    var headA: Double = 0
    var sideUp: Side = .a
    var sound: SoundSettings?
}

/// Recording erases whatever was on the tape underneath the new segment.
func overwrite(_ segments: [Segment], with new: Segment) -> [Segment] {
    var out: [Segment] = []
    let t0 = new.start, t1 = new.end
    for s in segments {
        if s.end <= t0 || s.start >= t1 { out.append(s); continue }
        if s.start < t0 {
            var head = s
            head.duration = t0 - s.start
            out.append(head)
        }
        if s.end > t1 {
            var tail = s
            let cut = t1 - s.start
            tail.start = t1
            tail.fileOffset += cut
            tail.duration = s.end - t1
            out.append(tail)
        }
    }
    out.append(new)
    return out.sorted { $0.start < $1.start }
}

enum TapeError: LocalizedError {
    case unreadable(String)
    case tool(String)
    case noInput
    case noSystemAudio
    case capture(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return String(format: L("„%@“ ist keine lesbare Mixtape-Kassette."), name)
        case .tool(let name): return String(format: L("%@ ist fehlgeschlagen."), name)
        case .noInput: return L("Kein Mikrofon gefunden.")
        case .noSystemAudio: return L("Vom Systemton kommt nichts an. Prüfe unter „Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme“, ob Mixtape aufnehmen darf.")
        case .capture(let step, let status): return String(format: L("Systemton-Aufnahme fehlgeschlagen (%@, Fehler %d)."), step, Int(status))
        }
    }
}

/// A .mixtape file is a zip archive holding tape.json plus the recorded audio.
/// While open, it lives unpacked in a private working directory.
final class TapeDocument {
    var data: TapeData
    var fileURL: URL?
    var dirty = false
    let workDir: URL

    var audioDir: URL { workDir.appendingPathComponent("audio", isDirectory: true) }
    var design: CassetteDesign { CassetteDesign.named(data.design) }

    init(length: TapeLength, design: String) throws {
        data = TapeData(length: length, design: design)
        workDir = try Self.makeWorkDir()
    }

    init(url: URL) throws {
        workDir = try Self.makeWorkDir()
        do {
            try Self.run("/usr/bin/ditto", "-x", "-k", url.path, workDir.path)
            let json = try Data(contentsOf: workDir.appendingPathComponent("tape.json"))
            var d = try JSONDecoder().decode(TapeData.self, from: json)
            // Only plain file names may point into the archive.
            let safe: (Segment) -> Bool = { !$0.file.contains("/") && !$0.file.hasPrefix(".") }
            d.sideA = d.sideA.filter(safe)
            d.sideB = d.sideB.filter(safe)
            data = d
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            throw TapeError.unreadable(url.lastPathComponent)
        }
        fileURL = url
    }

    func segments(_ side: Side) -> [Segment] { side == .a ? data.sideA : data.sideB }

    func record(_ segment: Segment, on side: Side) {
        if side == .a { data.sideA = overwrite(data.sideA, with: segment) }
        else { data.sideB = overwrite(data.sideB, with: segment) }
        dirty = true
    }

    func title(_ side: Side) -> String { side == .a ? data.titleA : data.titleB }

    func setTitle(_ title: String, _ side: Side) {
        if side == .a { data.titleA = title } else { data.titleB = title }
        dirty = true
    }

    var sound: SoundSettings {
        get { data.sound ?? SoundSettings() }
        set { data.sound = newValue; dirty = true }
    }

    /// Trims a fresh recording to the magnetic part of the tape; nil if it fell entirely on leader.
    func clipToMagnetic(_ s: Segment) -> Segment? {
        let lo = TapeLength.leaderSeconds, hi = data.length.sideSeconds - TapeLength.leaderSeconds
        guard s.end > lo, s.start < hi else { return nil }
        var c = s
        if c.start < lo {
            let cut = lo - c.start
            c.start = lo
            c.fileOffset += cut
            c.duration -= cut
        }
        if c.end > hi { c.duration = hi - c.start }
        return c.duration > 0.05 ? c : nil
    }

    func drawing(_ side: Side) -> [Stroke] { side == .a ? data.drawingA : data.drawingB }

    func setDrawing(_ strokes: [Stroke], _ side: Side) {
        if side == .a { data.drawingA = strokes } else { data.drawingB = strokes }
        dirty = true
    }

    func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        // Drop audio that has been completely recorded over.
        let used = Set((data.sideA + data.sideB).map(\.file))
        for f in (try? fm.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)) ?? []
        where !used.contains(f.lastPathComponent) {
            try? fm.removeItem(at: f)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(data).write(to: workDir.appendingPathComponent("tape.json"))

        let url = try fileURL ?? Self.newFileURL(title: data.titleA)
        let tmp = workDir.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
        try Self.run("/usr/bin/ditto", "-c", "-k", "--norsrc", "--zlibCompressionLevel", "1", workDir.path, tmp.path)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        fileURL = url
        dirty = false
    }

    func discard() {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Development test modes point this at a temporary folder so they never touch real tapes.
    static var libraryOverride: URL?

    static var libraryFolder: URL {
        // New tapes land on the Desktop, where they're easy to find and drag into an email.
        libraryOverride ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private static func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mixtape", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func newFileURL(title: String) throws -> URL {
        let dir = libraryFolder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = clean.isEmpty ? "Mixtape" : clean
        var url = dir.appendingPathComponent(base + ".mixtape")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).mixtape")
            n += 1
        }
        return url
    }

    static func run(_ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TapeError.tool(tool) }
    }
}
