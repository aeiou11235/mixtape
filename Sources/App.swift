import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// Borderless and transparent: only the cassette (and on hover its panel) is visible.
final class TapeWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Geo.window), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.managed, .participatesInCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class TapeController: NSObject, NSWindowDelegate {
    let deck: Deck
    let window = TapeWindow()
    private var hoverTimer: Timer?
    private weak var app: AppDelegate?

    init(doc: TapeDocument, app: AppDelegate) {
        deck = Deck(doc: doc)
        self.app = app
        super.init()
        let host = FirstMouseHostingView(rootView: TapeRootView(deck: deck))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Geo.window)
        window.contentView = host
        window.delegate = self
        deck.window = window
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollMouse() }
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    /// Clicks on the empty area around the cassette fall through to whatever lies beneath.
    private func pollMouse() {
        guard window.isVisible else { return }
        let p = window.mouseLocationOutsideOfEventStream
        let over = deck.updateHover(CGPoint(x: p.x, y: window.frame.height - p.y))
        if NSEvent.pressedMouseButtons == 0 && window.ignoresMouseEvents == over {
            window.ignoresMouseEvents = !over
        }
    }

    func windowWillClose(_ notification: Notification) {
        hoverTimer?.invalidate()
        deck.shutdown()
        app?.controllerDidClose(self)
    }
}

/// A system-wide shortcut. Carbon hot keys need no accessibility permission.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(ctx).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, me, &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4D58_5450), id: 1)   // 'MXTP'
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TapeController] = []
    private var pauseHotKey: GlobalHotKey?
    private(set) var alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Tools.run(CommandLine.arguments) { exit(0) }
        NSApp.mainMenu = makeMainMenu()
        // ⌥⌘P pauses from any app – plain ⌘P would take Print away from every other app.
        pauseHotKey = GlobalHotKey(keyCode: kVK_ANSI_P, modifiers: cmdKey | optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.activeDeck?.pressPause() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            nonisolated(unsafe) let event = e
            return MainActor.assumeIsolated { self?.handleKey(event) ?? event }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                if self.controllers.isEmpty { self.newTape(design: "ferro", length: .c60) }
            }
        }
        // Development aid: clicks the REC key with a real mouse event, like a user.
        if let i = CommandLine.arguments.firstIndex(of: "--autoclick"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            Deck.keepPanel = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                MainActor.assumeIsolated {
                    guard let c = self.controllers.first else { return }
                    let deck = c.deck
                    deck.source = .system
                    deck.scrub(toFraction: 0.05)
                    deck.showPanel = true
                    c.window.ignoresMouseEvents = false
                    let before = deck.elapsed
                    let p = NSPoint(x: Geo.panel.minX + 90, y: c.window.frame.height - Geo.panel.midY)
                    func post(_ type: NSEvent.EventType) {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                    post(.leftMouseDown)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { post(.leftMouseUp) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        MainActor.assumeIsolated {
                            let moved = deck.elapsed - before
                            let t = deck.transport
                            deck.pressStop()
                            try? "autoclick: tape moved \(String(format: "%.2f", moved)) s, transport \(t)".write(toFile: out, atomically: true, encoding: .utf8)
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
        // Development aid: launches normally, then presses REC itself and reports the result.
        if let i = CommandLine.arguments.firstIndex(of: "--autorecord"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                MainActor.assumeIsolated {
                    guard let deck = self.controllers.first?.deck else { return }
                    deck.source = .system
                    deck.scrub(toFraction: 0.05)
                    let before = deck.elapsed
                    deck.pressRecord()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        MainActor.assumeIsolated {
                            let moved = deck.elapsed - before
                            deck.pressStop()
                            try? "autorecord: tape moved \(String(format: "%.2f", moved)) s, transport \(deck.transport)".write(toFile: out, atomically: true, encoding: .utf8)
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        for u in urls { openTape(u) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty { newTape(design: "ferro", length: .c60) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for c in controllers { c.deck.shutdown() }
    }

    /// The cassette a global shortcut should act on: one that's running, else the front one.
    private var activeDeck: Deck? {
        (controllers.first { $0.deck.transport != .stopped || $0.deck.paused }
            ?? controllers.first { $0.window.isKeyWindow }
            ?? controllers.last)?.deck
    }

    func setAlwaysOnTop(_ on: Bool) {
        alwaysOnTop = on
        UserDefaults.standard.set(on, forKey: "alwaysOnTop")
        for c in controllers { apply(onTop: on, to: c) }
    }

    private func apply(onTop on: Bool, to c: TapeController) {
        c.window.level = on ? .floating : .normal
        c.deck.onTop = on
    }

    func newTape(design: String, length: TapeLength) {
        do { show(try TapeDocument(length: length, design: design)) } catch { alert(error) }
    }

    func openTape(_ url: URL) {
        if let c = controllers.first(where: { $0.deck.doc.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            c.window.makeKeyAndOrderFront(nil)
            return
        }
        do { show(try TapeDocument(url: url)) } catch { alert(error) }
    }

    @objc func openDocument(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "mixtape") ?? .data]
        p.allowsMultipleSelection = true
        p.directoryURL = TapeDocument.libraryFolder
        NSApp.activate()
        if p.runModal() == .OK { p.urls.forEach(openTape) }
    }

    @objc private func newDefault(_ sender: Any?) { newTape(design: "ferro", length: .c60) }

    @objc private func closeKey(_ sender: Any?) {
        controllers.first { $0.window.isKeyWindow }?.window.close()
    }

    private func show(_ doc: TapeDocument) {
        let c = TapeController(doc: doc, app: self)
        controllers.append(c)
        apply(onTop: alwaysOnTop, to: c)
        if let screen = NSScreen.main?.visibleFrame {
            let n = CGFloat(controllers.count - 1)
            c.window.setFrameOrigin(NSPoint(x: screen.midX - Geo.window.width / 2 + n * 30,
                                            y: screen.midY - Geo.window.height / 2 - n * 30))
        }
        NSApp.activate()
        c.window.makeKeyAndOrderFront(nil)
    }

    func controllerDidClose(_ c: TapeController) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.controllers.removeAll { $0 === c }
                if self.controllers.isEmpty { NSApp.terminate(nil) }
            }
        }
    }

    private func alert(_ error: Error) {
        let a = NSAlert()
        a.messageText = "Mixtape"
        a.informativeText = error.localizedDescription
        NSApp.activate()
        a.runModal()
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard let c = controllers.first(where: { $0.window.isKeyWindow }), !c.deck.editingLabel,
              e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
        let d = c.deck
        if e.type == .keyUp {
            // Letting go of an arrow ends cue / review, like releasing the key on a deck.
            switch e.keyCode {
            case 123: d.releaseWind(.rewind)
            case 124: d.releaseWind(.ffwd)
            default: return e
            }
            return nil
        }
        if e.isARepeat { return [49, 123, 124, 15, 3, 35].contains(e.keyCode) ? nil : e }
        switch e.keyCode {
        case 49: d.togglePlay()                 // space
        case 123: d.pressWind(.rewind)          // ←
        case 124: d.pressWind(.ffwd)            // →
        case 15: d.pressRecord()                // R
        case 3: d.flip()                        // F
        case 35: d.pressPause()                 // P
        case 53:                                // esc
            if d.drawMode { d.toggleDrawMode() }
            else if d.transport != .stopped { d.pressStop() }
            else { return e }
        default: return e
        }
        return nil
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Mixtape beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L("Ablage"))
        fileMenu.addItem(withTitle: L("Neue Kassette"), action: #selector(newDefault(_:)), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: L("Öffnen …"), action: #selector(openDocument(_:)), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: L("Schließen"), action: #selector(closeKey(_:)), keyEquivalent: "w").target = self
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Bearbeiten"))
        editMenu.addItem(withTitle: L("Ausschneiden"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Einsetzen"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Alles auswählen"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        return main
    }
}

/// Command-line helpers for development: rendering previews and the app icon, and a self-test.
@MainActor
enum Tools {
    static func run(_ args: [String]) -> Bool {
        if args.contains(where: { ["--rectest", "--mictest", "--tapbench", "--switchtest", "--autorecord", "--autoclick", "--selftest", "--snapshot", "--icon", "--taptest"].contains($0) }) {
            TapeDocument.libraryOverride = FileManager.default.temporaryDirectory.appendingPathComponent("MixtapeTests", isDirectory: true)
        }
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let out = value("--snapshot") {
            let fraction = Double(value("--pos") ?? "") ?? 0.3
            let side: Side = value("--side") == "b" ? .b : .a
            let deck: Deck
            if let path = value("--file") {
                // A real tape, label and drawings as the user made them; it is only read, never saved.
                let doc = try! TapeDocument(url: URL(fileURLWithPath: path))
                doc.fileURL = nil
                doc.data.sideUp = side
                deck = Deck(doc: doc, snapshotMode: true)
                deck.scrub(toFraction: fraction)
            } else {
                deck = demoDeck(design: value("--design") ?? "ferro", fraction: fraction, side: side,
                                drawing: args.contains("--draw"))
            }
            deck.showPanel = !args.contains("--nopanel")
            if args.contains("--meter") {
                deck.meterOpen = true
                deck.demoNeedles(-4, 1.5)
            }
            write(TapeRootView(deck: deck).background(Color(hex: 0x8e98a3)), scale: 2, to: out)
            deck.doc.discard()
            return true
        }
        if let out = value("--icon") {
            let deck = demoDeck(design: "ferro", fraction: 0.35, side: .a, drawing: false)
            write(CassetteView(deck: deck)
                    .frame(width: Geo.cw + 2 * Geo.margin, height: Geo.ch + 2 * Geo.margin)
                    .frame(width: 520, height: 520),
                  scale: 2, to: out)
            deck.doc.discard()
            return true
        }
        if let out = value("--rectest") {
            // Presses REC three times in one running process, like a user would, and reports
            // how far the tape moved and how loud the recording came out.
            let doc = try! TapeDocument(length: .c46, design: "ferro")
            let deck = Deck(doc: doc)
            deck.source = .system
            deck.scrub(toFraction: 0.05)
            var report = ""
            for round in 1...3 {
                RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                let before = deck.elapsed
                deck.pressRecord()
                RunLoop.main.run(until: Date().addingTimeInterval(3))
                let moved = deck.elapsed - before
                deck.pressStop()
                var peak: Float = 0
                if let seg = doc.data.sideA.last, let f = try? AVAudioFile(forReading: doc.audioDir.appendingPathComponent(seg.file)),
                   let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) {
                    try? f.read(into: b)
                    for i in 0..<Int(b.frameLength) { peak = max(peak, abs(b.floatChannelData![0][i])) }
                }
                report += "round \(round): tape moved \(String(format: "%.2f", moved)) s, recorded peak \(peak)\n"
            }
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
            doc.discard()
            return true
        }
        if let out = value("--mictest") {
            // Opens the chosen microphone for two seconds and reports what arrived.
            let m = MicCapture()
            let lock = NSLock()
            var buffers = 0
            var peak: Float = 0
            var report = ""
            do {
                try m.start { b in
                    lock.lock(); buffers += 1
                    if let c = b.floatChannelData { for i in 0..<Int(b.frameLength) { peak = max(peak, abs(c[0][i])) } }
                    lock.unlock()
                }
                RunLoop.main.run(until: Date().addingTimeInterval(2))
                m.stop()
                lock.lock(); report = "microphone: buffers \(buffers) peak \(peak)"; lock.unlock()
            } catch {
                report = "microphone error: \(error.localizedDescription)"
            }
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
            return true
        }
        if let out = value("--switchtest") {
            // One take that starts on the microphone and flips the selector five times.
            let doc = try! TapeDocument(length: .c46, design: "ferro")
            let deck = Deck(doc: doc)
            deck.source = .mic
            deck.scrub(toFraction: 0.05)
            let before = deck.elapsed
            var log = "microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = allowed)\n"
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                try? log.write(toFile: out, atomically: true, encoding: .utf8)
                doc.discard()
                return true
            }
            deck.pressRecord()
            for next in [RecordSource.system, .mic, .system, .mic, .system] {
                RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                let at = deck.elapsed
                deck.source = next
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                log += "→ \(next): tape \(String(format: "%+.2f", deck.elapsed - at)) s in 0.3 s\n"
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let moved = deck.elapsed - before
            let t = deck.transport
            deck.pressStop()
            log += "total: tape moved \(String(format: "%.2f", moved)) s in 10.5 s, still \(t), takes \(doc.data.sideA.count)"
            try? log.write(toFile: out, atomically: true, encoding: .utf8)
            doc.discard()
            return true
        }
        if let out = value("--tapbench") {
            // Starts the system tap ten times, waiting up to 6 s each, and records when audio arrived.
            var report = ""
            var times: [String] = []
            for _ in 0..<10 {
                let r = SystemAudioTap().benchmarkOnce(timeout: 6)
                times.append(r.ok ? String(format: "%.2f", r.seconds) : "–")
                Thread.sleep(forTimeInterval: 0.3)
            }
            report += "first audio after (s): \(times.joined(separator: " "))\n"
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
            return true
        }
        if let out = value("--taptest") {
            // Listens to the system audio tap for three seconds and reports what arrived.
            if args.contains("--taponly") { SystemAudioTap.withOutputDevice = false }
            // With --engine, run the deck's own audio first, as in the real app.
            let deckAudio = args.contains("--engine") ? DeckAudio() : nil
            if args.contains("--noexclude") { SystemAudioTap.excludeSelf = false }
            let tap = SystemAudioTap()
            let lock = NSLock()
            var buffers = 0, frames = 0
            var peak: Float = 0
            var result = ""
            do {
                try tap.start { b in
                    lock.lock()
                    buffers += 1
                    frames += Int(b.frameLength)
                    if let ch = b.floatChannelData {
                        for i in 0..<Int(b.frameLength) { peak = max(peak, abs(ch[0][i])) }
                    }
                    lock.unlock()
                }
                RunLoop.main.run(until: Date().addingTimeInterval(3))
                tap.stop()
                lock.lock()
                result = "buffers=\(buffers) frames/s=\(frames / 3) format rate=\(tap.lastFormat?.sampleRate ?? 0) peak=\(peak)"
                lock.unlock()
            } catch {
                result = "error: \(error.localizedDescription)"
            }
            try? result.write(toFile: out, atomically: true, encoding: .utf8)
            return true
        }
        if args.contains("--selftest") {
            selftest()
            return true
        }
        return false
    }

    private static func demoDeck(design: String, fraction: Double, side: Side, drawing: Bool) -> Deck {
        let doc = try! TapeDocument(length: .c60, design: design)
        doc.data.titleA = "Sommer ’86"
        doc.data.titleB = "Nachtfahrt"
        doc.data.sideUp = side
        if drawing {
            var pts: [Double] = []
            for i in 0...60 {
                let t = Double(i) / 60 * 2 * .pi
                pts += [330 + 16 * pow(sin(t), 3), 60 - (13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t))]
            }
            doc.setDrawing([Stroke(color: Deck.pens[2], width: 2.2, points: pts)], side)
        }
        let deck = Deck(doc: doc, snapshotMode: true)
        deck.scrub(toFraction: fraction)
        return deck
    }

    private static func write<V: View>(_ view: V, scale: CGFloat, to path: String) {
        let r = ImageRenderer(content: view)
        r.scale = scale
        guard let cg = r.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("render failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private static func selftest() {
        func check(_ ok: Bool, _ msg: String) { print((ok ? "ok    " : "FAIL  ") + msg) }

        let a = Segment(start: 10, duration: 3, file: "a", fileOffset: 0)
        let b = Segment(start: 11, duration: 1, file: "b", fileOffset: 0)
        let r = overwrite(overwrite([], with: a), with: b)
        check(r.count == 3 && r[0].duration == 1 && r[1].file == "b" && r[2].start == 12
              && r[2].fileOffset == 2 && r[2].duration == 1, "recording over the middle splits the old take")
        check(overwrite(r, with: Segment(start: 5, duration: 20, file: "c", fileOffset: 0)).count == 1,
              "recording over everything erases it")

        check(tapeSaturate(0.3) == 0.3 && tapeSaturate(0.9) < 0.9 && tapeSaturate(4) <= 1 && tapeSaturate(-4) >= -1,
              "normal levels pass clean, overdriven ones squash below full scale")

        // Overdrive: a 0 VU sine through the tape at unity and with the fader all the way up.
        func throughTape(fader: Double) -> (rms: Float, crest: Float) {
            let d = TapeDrive()
            d.setFader(fader)
            let n = 48_000
            var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
            for i in 0..<n { l[i] = 0.5 * Float(sin(2 * .pi * 440 * Double(i) / 48_000)); r[i] = l[i] }
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                d.applyInput(lp.baseAddress!, rp.baseAddress!, n)
                d.saturate(lp.baseAddress!, rp.baseAddress!, n)
            } }
            let tail = l[(n / 2)...]
            let rms = (tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
            return (rms, (tail.map(abs).max() ?? 0) / rms)
        }
        let clean = throughTape(fader: TapeDrive.unityFader), driven = throughTape(fader: 1)
        let louder = 20 * log10(driven.rms / clean.rms)
        check(abs(louder) < 3 && driven.crest < clean.crest - 0.2,
              String(format: "full drive squashes the sound (crest %.2f → %.2f) without getting louder (%+.1f dB)", clean.crest, driven.crest, louder))

        let doc = try! TapeDocument(length: .c46, design: "klar")
        defer { doc.discard() }
        let clipped = doc.clipToMagnetic(Segment(start: 1, duration: 10, file: "x", fileOffset: 0))
        check(clipped == Segment(start: 4, duration: 7, file: "x", fileOffset: 3), "sound recorded over the leader is dropped")
        check(doc.clipToMagnetic(Segment(start: 0, duration: 3, file: "x", fileOffset: 0)) == nil, "a take entirely on leader leaves nothing")
        do {
            try FileManager.default.createDirectory(at: doc.audioDir, withIntermediateDirectories: true)
            let url = doc.audioDir.appendingPathComponent("tone.m4a")
            let w = try TapeWriter(url: url, maxFrames: 96_000)   // 2 s of tape left
            var ended = false
            w.onEnd = { ended = true }
            let mono = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let meter = LevelMeter()
            var phase = 0.0
            for _ in 0..<40 {   // 4 s of 44.1 kHz mono offered
                let buf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4410)!
                buf.frameLength = 4410
                for i in 0..<4410 {
                    buf.floatChannelData![0][i] = Float(sin(phase)) * 0.5
                    phase += 2 * .pi * 440 / 44_100
                }
                _ = w.append(buf, fader: TapeDrive.unityFader, meter: meter)
            }
            let n = w.finish()
            check(n == 96_000 && ended, "writer stops when the tape runs out (\(n) frames)")
            let f = try AVAudioFile(forReading: url)
            let codec = (f.fileFormat.settings[AVFormatIDKey] as? NSNumber)?.uint32Value ?? 0
            check(abs(Int(f.length) - 96_000) < 4096,
                  "encoded file reads back (\(f.length) frames, codec \(codec == kAudioFormatMPEG4AAC_HE ? "HE-AAC" : "AAC \(codec)"))")

            let w2 = try TapeWriter(url: doc.audioDir.appendingPathComponent("pause.m4a"), maxFrames: 480_000)
            w2.squealThenPause()
            let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            func feed(_ w: TapeWriter, seconds: Int) -> AVAudioFramePosition {
                var n: AVAudioFramePosition = 0
                for _ in 0..<(seconds * 10) {
                    let buf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4800)!
                    buf.frameLength = 4800
                    for c in 0..<2 { for i in 0..<4800 { buf.floatChannelData![c][i] = Float(sin(Double(i) * 0.06)) * 0.3 } }
                    n = w.append(buf, fader: TapeDrive.unityFader, meter: meter)
                }
                return n
            }
            let paused = feed(w2, seconds: 1)
            check(!w2.writing && paused > 0 && paused < 12_000, "pause: a short squeal goes on tape, then it stands still (\(paused) frames)")
            w2.squealThenResume()
            check(feed(w2, seconds: 1) > paused + 40_000, "releasing pause records again")
            _ = w2.finish()

            doc.record(Segment(start: 5, duration: 2, file: "tone.m4a", fileOffset: 0), on: .a)
            doc.data.titleA = "Test"
            doc.setDrawing([Stroke(color: 0x111111, width: 2, points: [1, 2, 3, 4])], .b)
            doc.fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest.mixtape")
            try doc.save()
            let size = (try FileManager.default.attributesOfItem(atPath: doc.fileURL!.path)[.size] as? NSNumber)?.intValue ?? 0
            let back = try TapeDocument(url: doc.fileURL!)
            defer { back.discard() }
            check(back.data.sideA == doc.data.sideA && back.data.titleA == "Test" && back.data.drawingB == doc.data.drawingB,
                  "save and reopen (\(size) bytes)")
            check(FileManager.default.fileExists(atPath: back.audioDir.appendingPathComponent("tone.m4a").path),
                  "audio travels inside the .mixtape file")
            try? FileManager.default.removeItem(at: doc.fileURL!)
        } catch {
            check(false, "error: \(error)")
        }
    }
}
