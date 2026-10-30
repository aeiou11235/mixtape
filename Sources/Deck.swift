import AppKit
import AVFoundation
import SwiftUI

enum Transport { case stopped, playing, recording, ffwd, rewind }

/// One cassette in one deck: transport mechanics, reel motion, recording and drawing.
@MainActor
final class Deck: NSObject, ObservableObject {
    let doc: TapeDocument
    weak var window: NSWindow?
    let snapshotMode: Bool

    @Published private(set) var transport: Transport = .stopped
    @Published var showPanel = false
    @Published var editingLabel = false
    @Published var draftTitle = ""
    @Published private(set) var flipAngle: Double = 0
    @Published private(set) var paused = false
    @Published var onTop = false
    @Published private(set) var cue = 0          // +1 cueing forward, −1 reviewing
    @Published var meterOpen = UserDefaults.standard.bool(forKey: "meterOpen") {
        didSet { UserDefaults.standard.set(meterOpen, forKey: "meterOpen") }
    }
    /// The same fader is the volume control whenever the deck isn't recording.
    @Published var playVolume = UserDefaults.standard.object(forKey: "playVolume") as? Double ?? Deck.defaultVolume {
        didSet {
            UserDefaults.standard.set(playVolume, forKey: "playVolume")
            audio?.setVolume(Self.volumeGain(playVolume))
        }
    }
    @Published var recordLevel = UserDefaults.standard.object(forKey: "recordLevel") as? Double ?? Deck.unityLevel {
        didSet {
            UserDefaults.standard.set(recordLevel, forKey: "recordLevel")
            recorder?.fader = recordLevel
        }
    }
    @Published var source: RecordSource {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "recordSource")
            if source != oldValue { switchRecordingSource() }
        }
    }
    @Published private(set) var drawMode = false
    @Published var penColor: UInt32 = Deck.pens[1]
    @Published var penWidth: Double = Deck.penWidths[0]

    static let pens: [UInt32] = [0x111111, 0x1c3f94, 0xd0342c, 0xf7f7f2, 0xf2c230]
    static let penWidths: [Double] = [2.2, 5.5]
    /// Fast forward / rewind top speed, as a multiple of play speed.
    static let maxWind = 36.0
    static let unityLevel = TapeDrive.unityFader
    static let defaultVolume = 0.9

    /// Fader position to loudness: squared, which feels even across the travel.
    static func volumeGain(_ p: Double) -> Float { Float(p * p) }
    static var keepPanel = false   // development aid: never hide the panel
    static let needleRest = -22.0

    private(set) var leftAngle = 0.0, rightAngle = 0.0
    private var counterRaw = 0.0
    private var windSpeed = 0.0
    private var flipping = false
    private var ticker: Timer?
    private var lastTick = CACurrentMediaTime()
    private var recorder: TapeRecorder?
    private var recordingFile = ""
    private var recordStart = 0.0
    private var lastOver = 0.0
    private var cueCursor = 0.0
    private var recordStartedAt: CFTimeInterval = 0
    private var squealStart: CFTimeInterval?
    private var squealStops = false
    static let squealTime = 0.12
    private(set) var needleL = Deck.needleRest, needleR = Deck.needleRest
    private var heldL: Float = 0, heldR: Float = 0
    private var liveStroke: Stroke?
    private var closed = false
    private lazy var audio: DeckAudio? = snapshotMode ? nil : DeckAudio()

    init(doc: TapeDocument, snapshotMode: Bool = false) {
        self.doc = doc
        self.snapshotMode = snapshotMode
        source = RecordSource(rawValue: UserDefaults.standard.string(forKey: "recordSource") ?? "") ?? .system
        super.init()
        audio?.onRestart = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transport == .playing else { return }
                self.audio?.play(self.doc.segments(self.side), from: self.elapsed, in: self.doc.audioDir)
            }
        }
        audio?.setTone(doc.sound.tone)
        audio?.setVolume(Self.volumeGain(playVolume))
    }

    var sound: SoundSettings { doc.sound }

    private func click(_ kind: Clunk) {
        if sound.clicks { audio?.clunk(kind) }
    }

    /// Between the two leaders, where there is oxide and therefore sound.
    var onMagnetic: Bool {
        elapsed >= TapeLength.leaderSeconds && elapsed <= length - TapeLength.leaderSeconds
    }

    // MARK: Position

    var length: Double { doc.data.length.sideSeconds }
    var side: Side { doc.data.sideUp }
    /// Seconds played on the side facing up.
    var elapsed: Double { side == .a ? doc.data.headA : length - doc.data.headA }

    private func setElapsed(_ e: Double) {
        let c = min(max(e, 0), length)
        doc.data.headA = side == .a ? c : length - c
    }

    var counter: Int {
        let v = Int(floor(counterRaw)) % 1000
        return v < 0 ? v + 1000 : v
    }

    var paint: PaintState {
        let title = doc.title(side)
        return PaintState(design: doc.design, length: doc.data.length, side: side, title: title,
                          total: length, leader: TapeLength.leaderSeconds,
                          leftAmount: length - elapsed, rightAmount: elapsed,
                          leftAngle: leftAngle, rightAngle: rightAngle,
                          hideTitle: editingLabel, hint: showPanel && title.isEmpty && !drawMode,
                          strokes: doc.drawing(side) + (liveStroke.map { [$0] } ?? []))
    }

    /// Moves the tape and turns the hubs. Each hub turns by tape length over its pack radius,
    /// so the nearly empty reel spins fast and the full one slowly, like the real thing.
    private func advance(_ de: Double) {
        let before = elapsed
        setElapsed(before + de)
        let moved = elapsed - before
        guard moved != 0 else { return }
        let px = moved * Painter.tapeSpeed
        let rl = Painter.packRadius(length - elapsed, of: length, doc.data.length)
        let rr = Painter.packRadius(elapsed, of: length, doc.data.length)
        let cap = 0.42  // per frame; faster would strobe
        leftAngle -= max(-cap, min(cap, px / rl))
        rightAngle -= max(-cap, min(cap, px / rr))
        counterRaw += px / rr / (2 * .pi) / 2
    }

    func scrub(toFraction f: Double) { advance(f * length - elapsed) }

    func resetCounter() {
        counterRaw = 0
        objectWillChange.send()
    }

    // MARK: Transport keys

    func pressPlay() {
        if editingLabel { commitLabel() }
        if transport == .playing || flipping { return }
        if transport == .recording { finishRecording() }
        if transport == .ffwd || transport == .rewind { audio?.spool(false) }
        guard elapsed < length - 0.05 else { click(.key); return }
        click(.key)
        setTransport(.playing)
        if !paused { startPlayback() }
    }

    private func startPlayback() {
        audio?.play(doc.segments(side), from: elapsed, in: doc.audioDir)
    }

    func togglePlay() {
        if transport == .stopped { pressPlay() } else { pressStop() }
    }

    /// STOP while running; EJECT (turn the cassette over) when already stopped.
    func pressStop() {
        endCue(resume: false)
        let wasPaused = paused
        paused = false
        switch transport {
        case .stopped:
            if wasPaused { click(.key) } else { flip() }
            return
        case .recording: finishRecording()
        case .playing: audio?.stopPlayback()
        case .ffwd, .rewind: audio?.spool(false)
        }
        click(.key)
        setTransport(.stopped)
    }

    /// PAUSE latches: the tape halts but PLAY or REC stay engaged. REC with PAUSE down is
    /// record standby – the meters show the input so the level can be set before the song starts.
    func pressPause() {
        if flipping { return }
        click(.key)
        paused.toggle()
        switch transport {
        case .playing:
            // Engaging or releasing the pinch roller made the tape lurch: a short squeal.
            if paused {
                endCue(resume: false)
                beginSqueal(stopping: true)
            } else {
                startPlayback()
                beginSqueal(stopping: false)
            }
        case .recording:
            recorder?.setPaused(paused)
        default:
            break
        }
        lastTick = CACurrentMediaTime()
        startTicker()
    }

    private func beginSqueal(stopping: Bool) {
        squealStart = CACurrentMediaTime()
        squealStops = stopping
    }

    /// FF / REW. During play they cue and review – the music audibly whizzes past – for as long
    /// as the key is held; otherwise they latch and wind the tape.
    func pressWind(_ dir: Transport) {
        if flipping { return }
        if transport == .playing && !paused {
            beginCue(dir == .ffwd ? 1 : -1)
            return
        }
        if transport == dir { pressStop(); return }
        if transport == .recording { finishRecording() }
        if transport == .playing { audio?.stopPlayback() }
        paused = false
        click(.key)
        let atEnd = dir == .ffwd ? elapsed >= length - 0.01 : elapsed <= 0.01
        if atEnd {
            audio?.spool(false)
            setTransport(.stopped)
            return
        }
        windSpeed = 1
        audio?.spool(sound.spool)
        setTransport(dir)
    }

    func releaseWind(_ dir: Transport) {
        if cue == (dir == .ffwd ? 1 : -1) { endCue(resume: true) }
    }

    private func beginCue(_ dir: Int) {
        guard cue == 0 else { return }
        click(.key)
        cue = dir
        audio?.stopPlayback()
        audio?.startCue()
        cueCursor = elapsed
        feedCue()
    }

    private func endCue(resume: Bool) {
        guard cue != 0 else { return }
        cue = 0
        audio?.stopCue()
        if resume && transport == .playing && !paused {
            click(.key)
            startPlayback()
        }
    }

    /// Keeps about a quarter second of squeezed tape queued ahead of the moving head.
    private func feedCue() {
        let ahead = Double(DeckAudio.cueFactor) * 0.25, chunk = 0.4
        let segs = doc.segments(side)
        if cue > 0 {
            if cueCursor < elapsed { cueCursor = elapsed }
            while cueCursor < min(length, elapsed + ahead) {
                let b = min(length, cueCursor + chunk)
                audio?.queueCue(segs, from: cueCursor, to: b, reverse: false, in: doc.audioDir)
                cueCursor = b
            }
        } else {
            if cueCursor > elapsed { cueCursor = elapsed }
            while cueCursor > max(0, elapsed - ahead) {
                let a = max(0, cueCursor - chunk)
                audio?.queueCue(segs, from: a, to: cueCursor, reverse: true, in: doc.audioDir)
                cueCursor = a
            }
        }
    }

    func pressRecord() {
        if transport == .recording || flipping { return }
        if editingLabel { commitLabel() }
        if source == .mic {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    Task { @MainActor in if ok { self.pressRecord() } }
                }
                return
            case .denied, .restricted:
                showError(L("Mixtape darf das Mikrofon nicht benutzen. Du kannst es in den Systemeinstellungen unter „Datenschutz & Sicherheit → Mikrofon“ erlauben."))
                return
            default:
                break
            }
        }
        endCue(resume: false)
        if transport == .playing { audio?.stopPlayback() }
        if transport == .ffwd || transport == .rewind { audio?.spool(false) }
        guard elapsed < length - 0.5 else {
            click(.key)
            setTransport(.stopped)
            return
        }
        click(.key)
        let name = UUID().uuidString + ".m4a"
        do {
            try FileManager.default.createDirectory(at: doc.audioDir, withIntermediateDirectories: true)
            let rec = try TapeRecorder(url: doc.audioDir.appendingPathComponent(name),
                                       maxFrames: AVAudioFramePosition((length - elapsed) * TapeFormat.sampleRate),
                                       source: source)
            rec.onEnd = { [weak self] in
                Task { @MainActor in self?.endOfTapeWhileRecording() }
            }
            rec.fader = recordLevel
            rec.startPaused = paused
            rec.onStartFailure = { [weak self] error in
                Task { @MainActor in self?.recordingCouldNotStart(error) }
            }
            DiagnosticLog.write("record pressed: source \(source), paused \(paused), position \(Int(elapsed)) s")
            try rec.start()
            recorder = rec
            recordStartedAt = CACurrentMediaTime()
            recordingFile = name
            recordStart = elapsed
            setTransport(.recording)
        } catch {
            setTransport(.stopped)
            showError(L("Die Aufnahme konnte nicht starten.") + " " + error.localizedDescription)
        }
    }

    /// The input selector takes effect at once, also mid-recording or in record standby.
    private func switchRecordingSource() {
        guard transport == .recording, let rec = recorder, rec.source != source else { return }
        if source == .mic && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    Task { @MainActor in if ok { self.switchRecordingSource() } else { self.source = .system } }
                }
            } else {
                source = .system
                showError(L("Mixtape darf das Mikrofon nicht benutzen. Du kannst es in den Systemeinstellungen unter „Datenschutz & Sicherheit → Mikrofon“ erlauben."))
            }
            return
        }
        DiagnosticLog.write("source switched while recording: \(rec.source) → \(source)")
        do {
            try rec.switchSource(to: source)
            recordStartedAt = CACurrentMediaTime()   // the microphone watchdog starts over
        } catch {
            recordingCouldNotStart(error)
        }
    }

    private func finishRecording() {
        guard let rec = recorder else { return }
        recorder = nil
        let frames = rec.stop()
        let duration = Double(frames) / TapeFormat.sampleRate
        // Whatever ran over the leader simply isn't on the tape.
        if let seg = doc.clipToMagnetic(Segment(start: recordStart, duration: duration, file: recordingFile, fileOffset: 0)) {
            doc.record(seg, on: side)
            save()
        } else {
            try? FileManager.default.removeItem(at: rec.url)
        }
        setElapsed(recordStart + duration)
    }

    /// When a source delivers nothing for a while, the tape simply waits – no alarm. The
    /// system capture keeps retrying on its own; only real faults are reported.
    private func recordingCouldNotStart(_ error: Error) {
        guard transport == .recording else { return }
        DiagnosticLog.write("capture trouble: \(error.localizedDescription)")
        if case TapeError.noSystemAudio = error { return }
        finishRecording()
        paused = false
        click(.stop)
        setTransport(.stopped)
        showError(L("Die Aufnahme konnte nicht starten.") + " " + error.localizedDescription)
    }

    /// Record standby (REC with PAUSE down) blinks the record LED, like on a real deck.
    var recordLED: (on: Bool, level: Float) {
        guard transport == .recording else { return (false, 0) }
        if paused { return (Int(CACurrentMediaTime() * 2.5) % 2 == 0, 1) }
        return (true, Float((needleL + 20) / 23))
    }

    private func endOfTapeWhileRecording() {
        guard transport == .recording else { return }
        finishRecording()
        paused = false
        click(.stop)
        setTransport(.stopped)
    }

    /// The tape ran out: the keys pop back up.
    private func autoStop() {
        endCue(resume: false)
        switch transport {
        case .playing: audio?.stopPlayback()
        case .ffwd, .rewind: audio?.spool(false)
        default: break
        }
        paused = false
        click(.stop)
        setTransport(.stopped)
    }

    private func setTransport(_ t: Transport) {
        transport = t
        // While recording the controls stay out, so level and pause are always at hand.
        if t == .recording && !showPanel && !snapshotMode {
            withAnimation(.easeOut(duration: 0.18)) { showPanel = true }
        }
        squealStart = nil
        audio?.setRate(1)
        startTicker()
    }

    private func startTicker() {
        lastTick = CACurrentMediaTime()
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)
        lastTick = now
        var peaks: (Float, Float) = (0, 0)
        switch transport {
        case .playing:
            if let start = squealStart {
                let p = (now - start) / Self.squealTime
                if p >= 1 {
                    squealStart = nil
                    audio?.setRate(1)
                    if squealStops { audio?.stopPlayback() }
                } else {
                    let rate = 1 + 0.7 * sin(.pi * p)
                    advance(dt * rate)
                    audio?.setRate(Float(rate))
                    audio?.setHiss(sound.hiss && onMagnetic)
                }
            } else if paused {
                audio?.setHiss(false)
            } else if cue != 0 {
                advance(Double(cue) * dt * Double(DeckAudio.cueFactor))
                feedCue()
                audio?.setHiss(sound.hiss && onMagnetic)
            } else {
                advance(dt)
                audio?.wobble(now, on: sound.wow)
                audio?.setHiss(sound.hiss && onMagnetic)
            }
            peaks = audio?.meter.take() ?? (0, 0)
            if !paused && (cue < 0 ? elapsed <= 0.0005 : elapsed >= length - 0.0005) { autoStop() }
        case .ffwd, .rewind:
            windSpeed = min(Self.maxWind, windSpeed + dt * 30)
            advance((transport == .ffwd ? 1 : -1) * dt * windSpeed)
            audio?.spool(sound.spool, speed: windSpeed / Self.maxWind)
            if transport == .ffwd ? elapsed >= length - 0.0005 : elapsed <= 0.0005 { autoStop() }
        case .recording:
            if let r = recorder {
                advance(recordStart + r.seconds - elapsed)
                peaks = r.meter.take()
            }
        case .stopped:
            break
        }
        moveNeedles(peaks, dt)
        if transport == .stopped && !flipping && needleL < Self.needleRest + 0.1 && needleR < Self.needleRest + 0.1 {
            ticker?.invalidate()
            ticker = nil
        }
        objectWillChange.send()
    }

    // MARK: Meters

    /// VU needles in dB relative to 0 VU. They rise quickly and fall back slowly.
    private func moveNeedles(_ p: (Float, Float), _ dt: Double) {
        let hold = Float(exp(-dt / 0.12))
        heldL = max(p.0, heldL * hold)
        heldR = max(p.1, heldR * hold)
        func db(_ x: Float) -> Double {
            x > 0.0001 ? max(Self.needleRest, min(4, 20 * log10(Double(x / zeroVU)))) : Self.needleRest
        }
        func ease(_ v: Double, _ target: Double) -> Double {
            v + (target - v) * (1 - exp(-dt / (target > v ? 0.06 : 0.3)))
        }
        needleL = ease(needleL, db(heldL))
        needleR = ease(needleR, db(heldR))
    }

    func demoNeedles(_ l: Double, _ r: Double) {
        needleL = l
        needleR = r
    }

    func toggleMeter() {
        withAnimation(.easeOut(duration: 0.2)) { meterOpen.toggle() }
    }

    // MARK: Turning the cassette over

    func flip() {
        guard !flipping, !snapshotMode else { return }
        if transport != .stopped { pressStop() }
        if editingLabel { commitLabel() }
        flipping = true
        paused = false
        click(.eject)
        withAnimation(.easeIn(duration: 0.2)) { flipAngle = 90 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                // Turned over, the full reel is now on the other side.
                self.doc.data.sideUp = self.side.other
                (self.leftAngle, self.rightAngle) = (-self.rightAngle, -self.leftAngle)
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { self.flipAngle = -90 }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        withAnimation(.easeOut(duration: 0.22)) { self.flipAngle = 0 }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated {
                        self.flipping = false
                        self.click(.insert)
                    }
                }
            }
        }
    }

    // MARK: Hover

    /// Shows or hides the panel. Returns whether the point (window coordinates,
    /// top-left origin) is over something the user can interact with.
    func updateHover(_ p: CGPoint) -> Bool {
        let now = CACurrentMediaTime()
        let over = Geo.cassette.contains(p) || (showPanel && Geo.panelZone.contains(p))
            || (showPanel && meterOpen && !drawMode && Geo.drawerZone.contains(p))
        if over {
            lastOver = now
            if !showPanel { withAnimation(.easeOut(duration: 0.18)) { showPanel = true } }
        } else if showPanel && !editingLabel && !drawMode && !Self.keepPanel && transport != .recording && now - lastOver > 0.7 {
            withAnimation(.easeIn(duration: 0.25)) { showPanel = false }
        }
        return over
    }

    // MARK: Label

    func beginLabelEdit() {
        guard !flipping, !drawMode else { return }
        draftTitle = doc.title(side)
        editingLabel = true
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func commitLabel() {
        guard editingLabel else { return }
        editingLabel = false
        let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != doc.title(side) {
            doc.setTitle(t, side)
            if transport != .recording { save() }
        }
    }

    // MARK: Drawing

    func toggleDrawMode() {
        if editingLabel { commitLabel() }
        drawMode.toggle()
        if !drawMode && doc.dirty && transport != .recording { save() }
    }

    func beginStroke(at p: CGPoint) {
        liveStroke = Stroke(color: penColor, width: penWidth, points: [p.x, p.y])
        objectWillChange.send()
    }

    func extendStroke(to p: CGPoint) {
        guard var s = liveStroke else { return }
        let n = s.points.count
        if n >= 2, hypot(p.x - s.points[n - 2], p.y - s.points[n - 1]) < 1.2 { return }
        s.points += [p.x, p.y]
        liveStroke = s
        objectWillChange.send()
    }

    func endStroke() {
        guard let s = liveStroke else { return }
        liveStroke = nil
        doc.setDrawing(doc.drawing(side) + [s], side)
        objectWillChange.send()
    }

    func undoStroke() {
        var d = doc.drawing(side)
        guard !d.isEmpty else { return }
        d.removeLast()
        doc.setDrawing(d, side)
        objectWillChange.send()
    }

    func clearDrawing() {
        guard !doc.drawing(side).isEmpty else { return }
        doc.setDrawing([], side)
        objectWillChange.send()
    }

    // MARK: Files

    func save() {
        do { try doc.save() } catch { showError(L("Die Kassette konnte nicht gespeichert werden.") + " " + error.localizedDescription) }
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        if editingLabel { commitLabel() }
        if transport == .recording { finishRecording() }
        endCue(resume: false)
        audio?.stopPlayback()
        audio?.shutdown()
        ticker?.invalidate()
        ticker = nil
        // A tape that already has a file keeps its position, like a real one.
        if doc.fileURL != nil || doc.dirty { try? doc.save() }
        doc.discard()
    }

    func showError(_ text: String) {
        let a = NSAlert()
        a.messageText = "Mixtape"
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }

    // MARK: Menu

    func makeMenu() -> NSMenu {
        let m = NSMenu()
        let newItem = NSMenuItem(title: L("Neue Kassette"), action: nil, keyEquivalent: "")
        let designs = NSMenu()
        for d in CassetteDesign.all {
            for l in TapeLength.allCases {
                let i = item("\(d.name) \(l.label)", #selector(newTapeItem(_:)))
                i.representedObject = "\(d.id):\(l.rawValue)"
                designs.addItem(i)
            }
            if d.id != CassetteDesign.all.last?.id { designs.addItem(.separator()) }
        }
        newItem.submenu = designs
        m.addItem(newItem)
        m.addItem(item(L("Öffnen …"), #selector(openItem)))
        m.addItem(.separator())
        m.addItem(item(L("Beschriften"), #selector(labelItem)))
        m.addItem(item(drawMode ? L("Malen beenden") : L("Auf die Kassette malen"), #selector(drawItem)))
        m.addItem(item(L("Kassette umdrehen"), #selector(flipItem)))
        let pause = item(L("Pause – geht auch aus jeder App mit ⌥⌘P"), #selector(pauseItem))
        pause.state = paused ? .on : .off
        m.addItem(pause)
        let src = NSMenuItem(title: L("Aufnehmen von"), action: nil, keyEquivalent: "")
        let srcMenu = NSMenu()
        let sys = item(L("Systemton (alles, was der Mac abspielt)"), #selector(sourceSystem))
        sys.state = source == .system ? .on : .off
        let mic = item(L("Mikrofon"), #selector(sourceMic))
        mic.state = source == .mic ? .on : .off
        srcMenu.addItem(sys)
        srcMenu.addItem(mic)
        src.submenu = srcMenu
        m.addItem(src)
        let soundItem = NSMenuItem(title: L("Klang"), action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        let options = [(L("Bandrauschen"), sound.hiss), (L("Leiern"), sound.wow), (L("Bandklang (weiche Höhen)"), sound.tone),
                       (L("Spulgeräusch"), sound.spool), (L("Tastenklacken"), sound.clicks)]
        for (i, (title, on)) in options.enumerated() {
            let it = item(title, #selector(toggleSound(_:)))
            it.tag = i
            it.state = on ? .on : .off
            soundMenu.addItem(it)
        }
        soundMenu.addItem(.separator())
        let note = NSMenuItem(title: L("Wird mit der Kassette gespeichert"), action: nil, keyEquivalent: "")
        note.isEnabled = false
        soundMenu.addItem(note)
        soundItem.submenu = soundMenu
        m.addItem(soundItem)
        m.addItem(.separator())
        m.addItem(item(L("Per E-Mail verschicken …"), #selector(mailItem)))
        m.addItem(item(L("Im Finder zeigen"), #selector(revealItem)))
        m.addItem(.separator())
        let top = item(L("Immer im Vordergrund"), #selector(floatItem))
        top.state = onTop ? .on : .off
        m.addItem(top)
        m.addItem(item(L("Kassette schließen"), #selector(closeItem)))
        m.addItem(item(L("Mixtape beenden"), #selector(quitItem)))
        return m
    }

    func popMenu() {
        guard let w = window, let v = w.contentView else { return }
        let p = v.convert(w.mouseLocationOutsideOfEventStream, from: nil)
        makeMenu().popUp(positioning: nil, at: p, in: v)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func newTapeItem(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let parts = s.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]), let len = TapeLength(rawValue: n) else { return }
        (NSApp.delegate as? AppDelegate)?.newTape(design: String(parts[0]), length: len)
    }

    @objc private func openItem() { (NSApp.delegate as? AppDelegate)?.openDocument(nil) }
    @objc private func labelItem() { beginLabelEdit() }
    @objc private func drawItem() { toggleDrawMode() }
    @objc private func flipItem() { flip() }
    @objc private func pauseItem() { pressPause() }
    @objc private func toggleSound(_ sender: NSMenuItem) {
        var s = doc.sound
        switch sender.tag {
        case 0: s.hiss.toggle()
        case 1: s.wow.toggle()
        case 2: s.tone.toggle()
        case 3: s.spool.toggle()
        default: s.clicks.toggle()
        }
        doc.sound = s
        audio?.setTone(s.tone)
        if transport != .recording && doc.fileURL != nil { save() }
    }

    @objc private func sourceSystem() { source = .system }
    @objc private func sourceMic() { source = .mic }
    @objc private func closeItem() { window?.close() }
    @objc private func quitItem() { NSApp.terminate(nil) }

    @objc private func floatItem() { toggleOnTop() }

    func toggleOnTop() {
        (NSApp.delegate as? AppDelegate)?.setAlwaysOnTop(!onTop)
    }

    @objc private func revealItem() {
        if doc.fileURL == nil { save() }
        if let url = doc.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func mailItem() {
        if transport != .stopped { pressStop() }
        if drawMode { toggleDrawMode() }
        save()
        guard let url = doc.fileURL else { return }
        let subject = doc.data.titleA.isEmpty ? L("Ich hab dir ein Mixtape aufgenommen")
            : String(format: L("Ich hab dir „%@“ aufgenommen"), doc.data.titleA)
        if let svc = NSSharingService(named: .composeEmail) {
            svc.subject = subject
            svc.perform(withItems: [url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
