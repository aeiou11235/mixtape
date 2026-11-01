import AVFoundation
import AppKit
import SwiftUI

/// A tape as a single web page: the player from player.html with the tape, its recordings
/// and a picture of the cassette built in. It plays in any browser, no app needed.
enum WebTape {
    /// Most mail services take attachments up to 25 MB; the page stays below this.
    static let sizeTarget = 24_000_000
    static let mailLimit = 25_000_000
    /// HE-AAC rates to try, best first; the first that keeps the page under the target wins.
    static let bitRates = [48_000, 40_000, 32_000, 24_000]

    /// What the page needs from the tape, taken on the main thread so the slow part can run elsewhere.
    struct Source: Sendable {
        var data: TapeData
        var audioDir: URL
        var title: String
        var icon: Data?
        /// An add-on design with its pictures, as JSON for the page; nil for the built-in ones.
        var skin: String?
    }

    private struct SkinPayload: Encodable {
        var spec: SkinSpec
        var back: String
        var front: String
    }

    @MainActor
    static func source(_ doc: TapeDocument, picture: PaintState) -> Source {
        let title = doc.data.titleA.isEmpty ? (doc.fileURL?.deletingPathExtension().lastPathComponent ?? "Mixtape") : doc.data.titleA
        var skin: String?
        if let k = doc.design.skin, let b = try? Data(contentsOf: k.backURL), let f = try? Data(contentsOf: k.frontURL),
           let json = try? JSONEncoder().encode(SkinPayload(spec: k.spec, back: "data:image/png;base64," + b.base64EncodedString(),
                                                             front: "data:image/png;base64," + f.base64EncodedString())) {
            skin = String(decoding: json, as: UTF8.self)
        }
        return Source(data: doc.data, audioDir: doc.audioDir, title: title, icon: render(picture, scale: 0.25), skin: skin)
    }

    /// Builds the page. Slow (it re-encodes the audio), so call it off the main thread.
    static func write(_ src: Source, to url: URL) throws -> Int {
        guard let templateURL = Bundle.main.url(forResource: "player", withExtension: "html"),
              let template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            throw TapeError.tool("player.html")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("webtape-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Only what you can hear goes in: each side becomes one recording holding just its
        // segments, back to back, so takes that were recorded over don't weigh anything.
        let heard = (src.data.sideA + src.data.sideB).reduce(0) { $0 + $1.duration }
        let budget = Double(sizeTarget - template.utf8.count - (src.skin?.utf8.count ?? 0) - 200_000) * 3 / 4   // base64 adds a third
        let fitting = bitRates.first { Double($0) / 8 * heard <= budget } ?? bitRates.last!

        var data = src.data
        var audio: [String: String] = [:]
        for side in [Side.a, .b] {
            let segments = side == .a ? data.sideA : data.sideB
            guard !segments.isEmpty else { continue }
            let name = "side-\(side.rawValue).m4a"
            let file = work.appendingPathComponent(name)
            let packed = try pack(segments, from: src.audioDir, to: file, name: name, bitRates: bitRates.filter { $0 <= fitting })
            if side == .a { data.sideA = packed } else { data.sideB = packed }
            audio[name] = try Data(contentsOf: file).base64EncodedString()
        }
        // A tape you're given starts at the beginning of side A; links to it stay with the sender.
        data.sideUp = .a
        data.links = nil
        data.headA = 0

        // JSONEncoder writes "/" as "\/", so nothing in the tape can close the <script> early.
        let tapeJSON = String(decoding: try JSONEncoder().encode(data), as: UTF8.self)
        let audioJSON = String(decoding: try JSONEncoder().encode(audio), as: UTF8.self)
        let glyphs = Bundle.main.url(forResource: "emboss-glyphs", withExtension: "json")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "{}"
        let page = template
            .replacingOccurrences(of: "__SKIN_JSON__", with: src.skin ?? "null")
            .replacingOccurrences(of: "__GLYPHS_JSON__", with: glyphs)
            .replacingOccurrences(of: "__TITLE__", with: escapeHTML(src.title))
            .replacingOccurrences(of: "__ICON__", with: src.icon.map { "data:image/png;base64," + $0.base64EncodedString() } ?? "")
            .replacingOccurrences(of: "__TAPE_JSON__", with: tapeJSON)
            .replacingOccurrences(of: "__AUDIO_JSON__", with: audioJSON)
        let bytes = Data(page.utf8)
        try bytes.write(to: url, options: .atomic)
        return bytes.count
    }

    /// Copies the audible part of each segment into one HE-AAC file and returns the
    /// segments pointing into it. Tries the given bit rates in turn until the encoder takes one.
    private static func pack(_ segments: [Segment], from dir: URL, to url: URL, name: String, bitRates: [Int]) throws -> [Segment] {
        let format = AVAudioFormat(standardFormatWithSampleRate: TapeFormat.sampleRate, channels: 2)!
        var lastError: Error = TapeError.tool("AAC")
        for rate in bitRates {
            try? FileManager.default.removeItem(at: url)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC_HE, AVSampleRateKey: TapeFormat.sampleRate,
                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: rate]
            do {
                let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                var packed: [Segment] = []
                var written: AVAudioFramePosition = 0
                for s in segments {
                    let frames = try copy(s, from: dir, into: out, format: format)
                    packed.append(Segment(start: s.start, duration: Double(frames) / format.sampleRate, file: name,
                                          fileOffset: Double(written) / format.sampleRate))
                    written += frames
                }
                return packed
            } catch { lastError = error }
        }
        throw lastError
    }

    /// Appends one segment's audio to `out`, converting if its file is in another format.
    private static func copy(_ s: Segment, from dir: URL, into out: AVAudioFile, format: AVAudioFormat) throws -> AVAudioFramePosition {
        let want = AVAudioFramePosition((s.duration * format.sampleRate).rounded())
        let silence = { (n: AVAudioFramePosition) throws in
            // Audio missing from the archive: keep the timing with silence.
            var left = n
            while left > 0 {
                let c = AVAudioFrameCount(min(left, 48_000))
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: c)!
                b.frameLength = c
                try out.write(from: b)
                left -= AVAudioFramePosition(c)
            }
        }
        guard let input = try? AVAudioFile(forReading: dir.appendingPathComponent(s.file)) else {
            try silence(want)
            return want
        }
        let inFormat = input.processingFormat
        input.framePosition = min(AVAudioFramePosition(s.fileOffset * inFormat.sampleRate), input.length)
        let converter = inFormat == format ? nil : AVAudioConverter(from: inFormat, to: format)
        var done: AVAudioFramePosition = 0
        while done < want {
            let chunk = AVAudioFrameCount(min(want - done, 48_000))
            let inFrames = AVAudioFrameCount((Double(chunk) * inFormat.sampleRate / format.sampleRate).rounded(.up))
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inFrames) else { break }
            try input.read(into: buf, frameCount: inFrames)
            if buf.frameLength == 0 { break }
            var outBuf = buf
            if let converter {
                let cap = AVAudioFrameCount(Double(buf.frameLength) * format.sampleRate / inFormat.sampleRate) + 64
                guard let conv = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { break }
                var fed = false
                _ = converter.convert(to: conv, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return buf
                }
                outBuf = conv
            }
            let n = min(AVAudioFramePosition(outBuf.frameLength), want - done)
            outBuf.frameLength = AVAudioFrameCount(n)
            try out.write(from: outBuf)
            done += n
        }
        if done < want { try silence(want - done) }
        return want
    }

    /// Shows the cassette in the Finder as the file's icon. (Only on this Mac: custom icons
    /// don't travel by email.)
    @MainActor
    static func setIcon(_ picture: PaintState, on url: URL) {
        if let png = render(picture, scale: 2), let image = NSImage(data: png) {
            NSWorkspace.shared.setIcon(image, forFile: url.path, options: [])
        }
    }

    /// The cassette alone, centred on a transparent square.
    @MainActor
    static func render(_ state: PaintState, scale: CGFloat) -> Data? {
        let side = Geo.cw + 2 * Geo.margin
        let view = Canvas { ctx, size in
            var c = ctx
            c.translateBy(x: Geo.margin, y: (size.height - Geo.ch) / 2)
            Painter.draw(&c, state)
        }
        .frame(width: side, height: side)
        let r = ImageRenderer(content: view)
        r.scale = scale
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
