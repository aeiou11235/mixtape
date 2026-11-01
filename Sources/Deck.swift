import AppKit
import CryptoKit
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
        applySound()
        audio?.setVolume(Self.volumeGain(playVolume))
    }

    var sound: SoundSettings { doc.sound }

    /// Hands the tape's effect settings to the audio engine.
    private func applySound() {
        let s = doc.sound
        audio?.setTone(s.tone, amount: s.level(2))
        audio?.hissScale = Float(s.level(0) * 2)
        audio?.wowScale = s.level(1) * 2
        audio?.spoolScale = Float(s.level(3) * 2)
        audio?.setClickVolume(Float(s.level(4)))
    }

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
                          hideTitle: editingLabel,
                          hint: showPanel && title.isEmpty && !drawMode && doc.drawing(side).isEmpty,
                          strokes: doc.drawing(side) + (liveStroke.map { [$0] } ?? []),
                          writeProtected: doc.writeProtected(side), strips: shownStrips,
                          editingStrip: embossing ? editingStrip : nil,
                          embossCells: embossing ? embossDraft : nil,
                          embossCursor: embossing ? embossCursorPos : nil, embossCursorVisible: cursorOn,
                          editAnchor: editAnchor, hoverStrip: hoverStrip,
                          embossCorner: embossDrag == nil || embossDrag?.rotate == true ? tapeCorner : nil)
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
        // The tab for this side is broken out: the REC key won't go down.
        if doc.writeProtected(side) {
            click(.key)
            return
        }
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

    // MARK: Label tape

    /// Which strip to press: the title strip, one that is already stuck on, or a new one –
    /// where you double-clicked, or below the others.
    enum StripTarget {
        case title
        case existing(Int)
        case new(CGPoint?)
    }

    /// The strip being pressed, its letters so far, where the next one goes, and its colour.
    @Published private(set) var editingStrip: Int?
    @Published private(set) var embossDraft: [String] = []
    @Published private(set) var embossCursorPos = 0
    @Published private(set) var cursorOn = true
    @Published private(set) var editingColor: UInt32 = Deck.lastTapeColor
    private var editAnchor: Painter.EmbossAnchor?
    private var blink: Timer?
    private var stripsChanged = false

    var embossing: Bool { editingLabel && editingStrip != nil }

    static var lastTapeColor: UInt32 {
        get { (UserDefaults.standard.object(forKey: "tapeColor") as? NSNumber)?.uint32Value ?? Painter.embossColors[0] }
        set { UserDefaults.standard.set(NSNumber(value: newValue), forKey: "tapeColor") }
    }

    /// The strips as they are drawn: while one is being pressed, in the colour picked for it.
    private var shownStrips: [EmbossedTape] {
        var s = doc.strips(side)
        if let i = editingStrip, i < s.count { s[i].color = editingColor }
        return s
    }

    func beginLabelEdit(_ target: StripTarget = .title) {
        guard !flipping, !drawMode else { return }
        if editingLabel { commitLabel() }
        var strips = doc.strips(side)
        let i: Int
        var anchor: Painter.EmbossAnchor?
        switch target {
        case .existing(let k) where k < strips.count:
            i = k
        case .title where !strips.isEmpty:
            i = 0
        case .new(let p?):
            // A new strip starts where you double-clicked: its left end there.
            strips.append(EmbossedTape(color: Self.lastTapeColor, cells: []))
            i = strips.count - 1
            anchor = Painter.EmbossAnchor(point: CGPoint(x: min(max(p.x, 4), Painter.W - 60), y: p.y), angle: 0)
        default:
            strips.append(EmbossedTape(color: Self.lastTapeColor, cells: []))
            i = strips.count - 1
        }
        if strips.count != doc.strips(side).count { doc.setStrips(strips, side) }
        let t = strips[i]
        embossDraft = t.cells ?? []
        while embossDraft.last == "" { embossDraft.removeLast() }
        embossCursorPos = embossDraft.count
        editingColor = t.color
        // A strip that already has its place is pressed where it is.
        if anchor == nil, t.x != nil {
            anchor = Painter.anchor(of: Painter.stripFrame(t, index: i, cells: embossDraft, design: doc.design))
        }
        editAnchor = anchor
        editingStrip = i
        editingLabel = true
        cursorOn = true
        blink?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorOn.toggle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        blink = timer
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Cuts the strip after the last letter and sticks it where it is. A strip with nothing on it is thrown away.
    func commitLabel() {
        guard editingLabel else { return }
        editingLabel = false
        blink?.invalidate()
        blink = nil
        if let i = editingStrip {
            var strips = doc.strips(side)
            while embossDraft.last == "" { embossDraft.removeLast() }
            if i < strips.count {
                if embossDraft.isEmpty {
                    strips.remove(at: i)
                } else {
                    var t = strips[i]
                    t.cells = embossDraft
                    t.color = editingColor
                    // Pressed in place, or below the title: it stays exactly there.
                    if editAnchor != nil || i > 0 {
                        let f = Painter.stripFrame(t, index: i, cells: embossDraft, design: doc.design, anchor: editAnchor)
                        t.x = f.center.x
                        t.y = f.center.y
                        t.angle = f.angle
                    }
                    strips[i] = t
                }
                if strips != doc.strips(side) {
                    doc.setStrips(strips, side)
                    stripsChanged = true
                }
            }
        }
        editingStrip = nil
        editAnchor = nil
        if stripsChanged && transport != .recording { save() }
        stripsChanged = false
    }

    /// The colour of the strip being pressed.
    func setEmbossColor(_ c: UInt32) {
        editingColor = c
        Self.lastTapeColor = c
    }

    /// Done with this strip, on to the next one.
    func nextStrip() {
        commitLabel()
        beginLabelEdit(.new(nil))
    }

    /// A key on the embosser. There is no rubbing out: ← and ⌫ only wind the tape back,
    /// so the next letter is pressed over what is already there.
    func embossKey(_ e: NSEvent) -> Bool {
        cursorOn = true
        switch e.keyCode {
        case 123, 51: embossCursorPos = max(0, embossCursorPos - 1)        // ←, ⌫
        case 124: embossCursorPos = min(Painter.embossMaxCells(doc.design), embossCursorPos + 1)   // →
        case 36, 76, 53: commitLabel()                                   // return, enter, esc
        default:
            for ch in Painter.embossChars(e.characters ?? "") { press(ch) }
        }
        return true
    }

    private func press(_ ch: Character) {
        guard embossCursorPos < Painter.embossMaxCells(doc.design) else { return }
        while embossDraft.count <= embossCursorPos { embossDraft.append("") }
        if ch != " " && Painter.embossGlyphs[ch] != nil { embossDraft[embossCursorPos].append(ch) }
        embossCursorPos += 1
    }

    /// A fresh strip in place of this one, for when it is beyond saving.
    func newStrip() {
        embossDraft = []
        embossCursorPos = 0
        cursorOn = true
    }

    /// Where each strip sits, topmost first, for finding the one under the pointer.
    private var stripFrames: [(Int, Painter.EmbossFrame)] {
        guard !editingLabel else { return [] }
        return doc.strips(side).enumerated().compactMap { i, t in
            let cells = t.cells ?? []
            guard cells.contains(where: { !$0.isEmpty }) else { return nil }
            return (i, Painter.stripFrame(t, index: i, cells: cells, design: doc.design))
        }.reversed()
    }

    func stripIndex(at p: CGPoint) -> Int? { stripFrames.first { Painter.embossContains($0.1, p) }?.0 }

    @Published private(set) var hoverStrip: Int?
    @Published private(set) var tapeCorner: Int?

    /// What the pointer is over: a corner of the strip being pressed (turn it), that strip (move it),
    /// or neither. Strips that are stuck on stay put, so dragging them moves the cassette.
    enum TapeHover { case none, move, turn }

    /// The strip being pressed, where it is right now.
    private var editingFrame: Painter.EmbossFrame? {
        guard embossing, let i = editingStrip else { return nil }
        let strips = doc.strips(side)
        guard i < strips.count else { return nil }
        return Painter.stripFrame(strips[i], index: i, cells: embossDraft, design: doc.design, cursor: embossCursorPos, anchor: editAnchor)
    }

    func tapeHover(_ p: CGPoint) -> TapeHover {
        var strip: Int?, corner: Int?, kind = TapeHover.none
        if let f = editingFrame {
            if let c = Painter.embossCorner(f, p) { strip = editingStrip; corner = c; kind = .turn }
            else if Painter.embossContains(f, p) { strip = editingStrip; kind = .move }
        }
        if strip != hoverStrip { hoverStrip = strip }
        if corner != tapeCorner { tapeCorner = corner }
        return kind
    }

    private var embossDrag: (start: CGPoint, frame: Painter.EmbossFrame, rotate: Bool)?

    /// While pressing: dragging the strip moves it, dragging a corner turns it around its centre.
    func beginEmbossDrag(at p: CGPoint, rotate: Bool) {
        guard let f = editingFrame else { return }
        embossDrag = (p, f, rotate)
    }

    func moveEmbossDrag(to p: CGPoint) {
        guard let d = embossDrag else { return }
        var f = d.frame
        if d.rotate {
            let a0 = atan2(d.start.y - f.center.y, d.start.x - f.center.x)
            let a1 = atan2(p.y - f.center.y, p.x - f.center.x)
            f.angle += (a1 - a0) * 180 / .pi
        } else {
            f.center.x = min(max(f.center.x + p.x - d.start.x, 0), Painter.W)
            f.center.y = min(max(f.center.y + p.y - d.start.y, 0), Painter.H)
        }
        // The left end is what stays put while pressing, so the strip keeps growing from there.
        objectWillChange.send()
        editAnchor = Painter.anchor(of: f)
    }

    func endEmbossDrag() {
        embossDrag = nil
        objectWillChange.send()
    }

    /// Turns a strip back to level where it is.
    func straightenStrip(_ i: Int) {
        var strips = doc.strips(side)
        guard i < strips.count, let f = stripFrames.first(where: { $0.0 == i })?.1 else { return }
        objectWillChange.send()
        strips[i].x = f.center.x
        strips[i].y = f.center.y
        strips[i].angle = 0
        doc.setStrips(strips, side)
        if transport != .recording { save() }
    }

    func peelStrip(_ i: Int) {
        var strips = doc.strips(side)
        guard i < strips.count else { return }
        objectWillChange.send()
        strips.remove(at: i)
        doc.setStrips(strips, side)
        if transport != .recording { save() }
    }

    func peelAllStrips() {
        objectWillChange.send()
        doc.setStrips([], side)
        if transport != .recording { save() }
    }

    /// Right-click on a strip.
    func stripMenu(_ i: Int) -> NSMenu {
        let m = NSMenu()
        for (title, action) in [(L("Weiterprägen"), #selector(editStripItem(_:))), (L("Gerade ausrichten"), #selector(straightenItem(_:))),
                                (L("Abziehen"), #selector(peelItem(_:)))] {
            let it = item(title, action)
            it.tag = i
            m.addItem(it)
        }
        return m
    }

    @objc private func editStripItem(_ sender: NSMenuItem) { beginLabelEdit(.existing(sender.tag)) }
    @objc private func straightenItem(_ sender: NSMenuItem) { straightenStrip(sender.tag) }
    @objc private func peelItem(_ sender: NSMenuItem) { peelStrip(sender.tag) }
    @objc private func moreStripItem() { beginLabelEdit(.new(nil)) }
    @objc private func peelAllItem() { peelAllStrips() }

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
        // Each design offers the three lengths; add-on packs follow under their own heading.
        let addDesign = { (d: CassetteDesign) in
            let di = NSMenuItem(title: d.name, action: nil, keyEquivalent: "")
            let lengths = NSMenu()
            for l in TapeLength.allCases {
                let i = self.item(l.label, #selector(self.newTapeItem(_:)))
                i.representedObject = "\(d.id):\(l.rawValue)"
                lengths.addItem(i)
            }
            di.submenu = lengths
            designs.addItem(di)
        }
        CassetteDesign.all.forEach(addDesign)
        for pack in SkinStore.shared.packs {
            designs.addItem(.separator())
            designs.addItem(NSMenuItem.sectionHeader(title: pack.spec.name))
            pack.skins.map(\.design).forEach(addDesign)
        }
        designs.addItem(.separator())
        designs.addItem(item(L("Kassetten-Designs hinzufügen …"), #selector(addDesignsItem)))
        newItem.submenu = designs
        m.addItem(newItem)
        m.addItem(item(L("Öffnen …"), #selector(openItem)))
        m.addItem(.separator())
        m.addItem(item(L("Beschriften"), #selector(labelItem)))
        let tapeItem = NSMenuItem(title: L("Prägeband"), action: nil, keyEquivalent: "")
        let tapeMenu = NSMenu()
        tapeMenu.addItem(item(L("Weiteres Band prägen"), #selector(moreStripItem)))
        if !doc.strips(side).isEmpty { tapeMenu.addItem(item(L("Alle abziehen"), #selector(peelAllItem))) }
        tapeMenu.addItem(.separator())
        for text in [L("Doppelklick auf die Kassette: neues Band an dieser Stelle"),
                     L("Doppelklick aufs Band: prägen, verschieben, an den Ecken drehen"),
                     L("Rechtsklick aufs Band: weiterprägen, ausrichten, abziehen")] {
            let hint = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            tapeMenu.addItem(hint)
        }
        tapeItem.submenu = tapeMenu
        m.addItem(tapeItem)
        m.addItem(item(drawMode ? L("Malen beenden") : L("Auf die Kassette malen"), #selector(drawItem)))
        m.addItem(item(L("Kassette umdrehen"), #selector(flipItem)))
        let protect = NSMenuItem(title: L("Schreibschutz"), action: nil, keyEquivalent: "")
        let protectMenu = NSMenu()
        for sd in [Side.a, .b] {
            let i = item(String(format: L("Seite %@ – Lasche herausgebrochen"), sd.letter), #selector(protectItem(_:)))
            i.representedObject = sd.rawValue
            i.state = doc.writeProtected(sd) ? .on : .off
            protectMenu.addItem(i)
        }
        protect.submenu = protectMenu
        m.addItem(protect)
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
        soundMenu.delegate = self
        soundMenu.addItem(NSMenuItem.sectionHeader(title: L("Effekt und Stärke")))
        let titles = [L("Bandrauschen"), L("Leiern"), L("Bandklang (weiche Höhen)"), L("Spulgeräusch"), L("Tastenklacken")]
        for (i, title) in titles.enumerated() {
            let row = SoundRow(title: title, on: sound.isOn(i), level: sound.level(i))
            row.onToggle = { [weak self] _ in self?.changeSound { $0.toggle(i) } }
            row.onLevel = { [weak self] v in self?.changeSound { $0.setLevel(i, v) } }
            let it = NSMenuItem()
            it.view = row
            soundMenu.addItem(it)
        }
        soundMenu.addItem(.separator())
        let note = NSMenuItem(title: L("Wird mit der Kassette gespeichert"), action: nil, keyEquivalent: "")
        note.isEnabled = false
        soundMenu.addItem(note)
        soundItem.submenu = soundMenu
        m.addItem(soundItem)
        m.addItem(.separator())
        m.addItem(NSMenuItem.sectionHeader(title: L("An Freunde verschicken")))
        if ShareLink.available { m.addItem(item(L("Als Link – ein Klick, und es spielt …"), #selector(linkItem))) }
        m.addItem(item(L("Als Webseite – spielt in jedem Browser …"), #selector(webItem)))
        m.addItem(item(L("Als Mixtape-Datei – für Freunde mit der App …"), #selector(tapeFileItem)))
        m.addItem(.separator())
        let top = item(L("Immer im Vordergrund"), #selector(floatItem))
        top.state = onTop ? .on : .off
        m.addItem(top)
        m.addItem(item(L("Kassette schließen"), #selector(closeItem)))
        m.addItem(.separator())
        m.addItem(item(L("Über Mixtape"), #selector(aboutItem)))
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
    @objc private func addDesignsItem() { (NSApp.delegate as? AppDelegate)?.chooseDesigns() }

    @objc private func protectItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let sd = Side(rawValue: raw) else { return }
        if transport == .recording && sd == side { finishRecording() }
        objectWillChange.send()
        doc.setWriteProtected(!doc.writeProtected(sd), sd)
        if doc.fileURL != nil { save() }
    }
    @objc private func labelItem() { beginLabelEdit() }
    @objc private func drawItem() { toggleDrawMode() }
    @objc private func flipItem() { flip() }
    @objc private func pauseItem() { pressPause() }
    private var soundChanged = false

    /// Applies at once, so you hear it while you move the slider; saved when the menu closes.
    private func changeSound(_ change: (inout SoundSettings) -> Void) {
        var s = doc.sound
        change(&s)
        doc.sound = s
        applySound()
        soundChanged = true
    }

    @objc private func sourceSystem() { source = .system }
    @objc private func sourceMic() { source = .mic }
    @objc private func closeItem() { window?.close() }
    @objc private func quitItem() { NSApp.terminate(nil) }

    @objc private func floatItem() { toggleOnTop() }

    func toggleOnTop() {
        (NSApp.delegate as? AppDelegate)?.setAlwaysOnTop(!onTop)
    }

    @objc private func aboutItem() { AboutScreen.shared.show(briefly: false) }

    /// The .mixtape itself, for friends who have the app: saved and shown in the Finder,
    /// ready to drag into an email or a message.
    @objc private func tapeFileItem() {
        if transport != .stopped { pressStop() }
        if drawMode { toggleDrawMode() }
        save()
        if let url = doc.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// The tape as a web page next to it, for friends without the app: it plays in any browser.
    /// Shown in the Finder when ready, to drag into an email.
    @objc private func webItem() {
        if transport != .stopped { pressStop() }
        if drawMode { toggleDrawMode() }
        save()
        guard let tapeURL = doc.fileURL, busy == nil else { return }
        let url = tapeURL.deletingPathExtension().appendingPathExtension("html")
        var picture = paint
        picture.hint = false
        picture.hideTitle = false
        let source = WebTape.source(doc, picture: picture)
        // Re-encoding the audio takes a few seconds; the deck stays usable meanwhile.
        busy = BusyPanel(L("Webseite wird erstellt …"), near: window)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try WebTape.write(source, to: url) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy?.close()
                self.busy = nil
                switch result {
                case .failure(let error):
                    self.showError(L("Die Webseite konnte nicht erstellt werden.") + " " + error.localizedDescription)
                case .success(let size):
                    WebTape.setIcon(picture, on: url)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    if size >= WebTape.mailLimit {
                        self.showError(String(format: L("Die Webseite ist %d MB groß – zu groß für die meisten E-Mails. Teile sie am besten als Link, z. B. über iCloud Drive oder WeTransfer."),
                                              size / 1_000_000))
                    }
                }
            }
        }
    }
    private var busy: BusyPanel?

    /// Puts the tape's web page online and copies the link: one tap and it plays, on any phone or computer.
    @objc private func linkItem() {
        if transport != .stopped { pressStop() }
        if drawMode { toggleDrawMode() }
        save()
        guard doc.fileURL != nil, busy == nil else { return }
        var picture = paint
        picture.hint = false
        picture.hideTitle = false
        let source = WebTape.source(doc, picture: picture)
        busy = BusyPanel(L("Link wird erstellt …"), near: window)
        Task.detached(priority: .userInitiated) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString).html")
            defer { try? FileManager.default.removeItem(at: file) }
            let result: Result<URL, Error>
            do {
                _ = try WebTape.write(source, to: file)
                result = .success(try await ShareLink.upload(file))
            } catch { result = .failure(error) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy?.close()
                self.busy = nil
                switch result {
                case .failure(let error):
                    self.showError(L("Der Link konnte nicht erstellt werden.") + " " + error.localizedDescription)
                case .success(let link):
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    let a = NSAlert()
                    a.messageText = L("Link kopiert")
                    a.informativeText = link.absoluteString + "\n\n" + L("Füge ihn in eine Mail, WhatsApp oder wo du willst ein. Ein Tipp darauf, und das Tape spielt – 30 Tage lang.")
                    NSApp.activate()
                    a.runModal()
                }
            }
        }
    }
}

/// Uploads a tape's web page to the share service (Share/php) and returns its link. The page is
/// encrypted first with a fresh key that only travels in the link, after the # – the server
/// stores nothing it could read.
enum ShareLink {
    static var endpoint: URL? {
        // MIXTAPE_SHARE_UPLOAD points development tests at a local server.
        (ProcessInfo.processInfo.environment["MIXTAPE_SHARE_UPLOAD"] ?? Bundle.main.object(forInfoDictionaryKey: "MixtapeShareUpload") as? String)
            .flatMap { URL(string: $0) }
    }
    static var key: String? { Bundle.main.object(forInfoDictionaryKey: "MixtapeShareKey") as? String }
    static var available: Bool { endpoint != nil && key != nil }

    struct Reply: Decodable { let id: String }

    static func upload(_ file: URL) async throws -> URL {
        guard let endpoint, let key else { throw TapeError.tool("Share") }
        var req = URLRequest(url: endpoint, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-mixtape-key")
        req.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        let secret = SymmetricKey(size: .bits256)
        guard let sealed = try AES.GCM.seal(try Data(contentsOf: file), using: secret).combined else { throw TapeError.tool("AES") }
        let (data, response) = try await URLSession.shared.upload(for: req, from: sealed)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TapeError.unreadable(String(decoding: data, as: UTF8.self))
        }
        let id = try JSONDecoder().decode(Reply.self, from: data).id
        let linkKey = secret.withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard let link = URL(string: endpoint.deletingLastPathComponent().absoluteString + "#\(id).\(linkKey)") else { throw TapeError.tool("Share") }
        return link
    }
}

extension Deck: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        guard soundChanged else { return }
        soundChanged = false
        if transport != .recording && doc.fileURL != nil { save() }
    }
}

/// One effect in the Sound menu: on or off, and how strong.
final class SoundRow: NSView {
    private let check: NSButton
    private let slider: NSSlider
    var onToggle: (Bool) -> Void = { _ in }
    var onLevel: (Double) -> Void = { _ in }

    init(title: String, on: Bool, level: Double) {
        check = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        slider = NSSlider(value: level, minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        check.state = on ? .on : .off
        check.target = self
        check.action = #selector(toggled)
        check.frame = NSRect(x: 14, y: 4, width: 200, height: 18)
        slider.target = self
        slider.action = #selector(moved)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.isEnabled = on
        slider.frame = NSRect(x: 216, y: 4, width: 110, height: 18)
        addSubview(check)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func toggled() {
        slider.isEnabled = check.state == .on
        onToggle(check.state == .on)
    }

    @objc private func moved() { onLevel(slider.doubleValue) }
}
