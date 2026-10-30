import AVFoundation
import CoreAudio

enum TapeFormat {
    static let sampleRate = 48_000.0
    static let pcm = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    /// HE-AAC keeps a C60 around 20 MB, small enough to mail. Tape never sounded like a CD anyway.
    static let encoderSettings: [[String: Any]] = [
        [AVFormatIDKey: kAudioFormatMPEG4AAC_HE, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 48_000],
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000],
    ]
}

enum RecordSource: String { case system, mic }

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameLength, 1)) else { return nil }
        c.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            let bytes = min(src[i].mDataByteSize, dst[i].mDataByteSize)
            memcpy(d, s, Int(bytes))
            dst[i].mDataByteSize = bytes
        }
        return c
    }
}

// MARK: - Playback

/// State shared with the noise generator on the render thread.
final class NoiseState {
    var hissTarget: Float = 0, spoolTarget: Float = 0, spoolHz: Float = 4
    var hiss: Float = 0, spool: Float = 0
    var seedL: UInt32 = 22_222, seedR: UInt32 = 987_654
    var lpL: Float = 0, lpR: Float = 0, brown: Float = 0, phase: Float = 0
}

enum Clunk { case key, stop, eject, insert }

/// Peak levels handed from the audio threads to the VU meters.
final class LevelMeter {
    private let lock = NSLock()
    private var l: Float = 0, r: Float = 0

    func feed(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let right = buf.format.channelCount > 1 ? ch[1] : ch[0]
        var pl: Float = 0, pr: Float = 0
        for i in 0..<Int(buf.frameLength) {
            pl = max(pl, abs(ch[0][i]))
            pr = max(pr, abs(right[i]))
        }
        lock.lock()
        l = max(l, pl)
        r = max(r, pr)
        lock.unlock()
    }

    /// Peaks since the last call.
    func take() -> (Float, Float) {
        lock.lock()
        defer { l = 0; r = 0; lock.unlock() }
        return (l, r)
    }
}

/// Signal level that reads 0 VU (about −6 dBFS). Tape starts to saturate a little above it.
let zeroVU: Float = 0.5

/// Magnetic tape doesn't clip, it squashes: clean up to a point, then ever softer and dirtier.
@inline(__always) func tapeSaturate(_ x: Float) -> Float {
    let t: Float = 0.6
    let a = abs(x)
    if a <= t { return x }
    let y = t + (1 - t) * tanhf((a - t) / (1 - t))
    return x < 0 ? -y : y
}

/// The deck's sound: tape playback through a slightly wobbly, band-limited chain,
/// plus hiss, the whirr of spooling and the mechanical clunks of the keys.
final class DeckAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private let fx = AVAudioPlayerNode()
    private let cuePlayer = AVAudioPlayerNode()
    private let tapeMix = AVAudioMixerNode()
    private let volumeMix = AVAudioMixerNode()
    private var noiseNode: AVAudioSourceNode!
    private let noise = NoiseState()
    private var clunks: [Clunk: AVAudioPCMBuffer] = [:]
    private var cueFiles: [String: AVAudioFile] = [:]
    /// What comes off the tape, for the VU meters.
    let meter = LevelMeter()
    var onRestart: (() -> Void)?

    static let hissLevel: Float = 0.014
    /// Cue and review run the tape at this multiple of play speed.
    static let cueFactor = 8

    init() {
        let fmt = TapeFormat.pcm
        let st = noise
        noiseNode = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            let l = bufs[0].mData!.assumingMemoryBound(to: Float.self)
            let r = bufs.count > 1 ? bufs[1].mData!.assumingMemoryBound(to: Float.self) : l
            for i in 0..<Int(frameCount) {
                st.hiss += (st.hissTarget - st.hiss) * 0.0004
                st.spool += (st.spoolTarget - st.spool) * 0.0004
                st.seedL = st.seedL &* 1_664_525 &+ 1_013_904_223
                st.seedR = st.seedR &* 22_695_477 &+ 1
                let wl = Float(Int32(bitPattern: st.seedL)) / 2_147_483_648
                let wr = Float(Int32(bitPattern: st.seedR)) / 2_147_483_648
                st.lpL += (wl - st.lpL) * 0.45
                st.lpR += (wr - st.lpR) * 0.45
                st.brown = (st.brown + wl * 0.03) * 0.996
                st.phase += st.spoolHz / 48_000
                if st.phase > 1 { st.phase -= 1 }
                let whirr = st.brown * st.spool * (0.75 + 0.25 * sinf(st.phase * 2 * .pi))
                l[i] = st.lpL * st.hiss + whirr
                r[i] = st.lpR * st.hiss + whirr
            }
            return noErr
        }
        for n: AVAudioNode in [player, varispeed, cuePlayer, tapeMix, eq, volumeMix, fx, noiseNode] { engine.attach(n) }
        eq.bands[0].filterType = .lowPass
        eq.bands[0].frequency = 12_500
        eq.bands[0].bypass = false
        eq.bands[1].filterType = .highPass
        eq.bands[1].frequency = 35
        eq.bands[1].bypass = false
        engine.connect(player, to: varispeed, format: fmt)
        engine.connect(varispeed, to: tapeMix, format: fmt)
        engine.connect(cuePlayer, to: tapeMix, format: fmt)
        engine.connect(tapeMix, to: eq, format: fmt)
        // The meters read the tape before the volume control, like on a real deck.
        engine.connect(eq, to: volumeMix, format: fmt)
        engine.connect(volumeMix, to: engine.mainMixerNode, format: fmt)
        eq.installTap(onBus: 0, bufferSize: 1024, format: nil) { [meter] b, _ in meter.feed(b) }
        engine.connect(noiseNode, to: engine.mainMixerNode, format: fmt)
        engine.connect(fx, to: engine.mainMixerNode, format: fmt)

        clunks = [
            .key: Self.makeClunk(thump: 160, decay: 0.02, snap: 0.004, gain: 0.25),
            .stop: Self.makeClunk(thump: 110, decay: 0.05, snap: 0.006, gain: 0.35),
            .eject: Self.makeClunk(thump: 140, decay: 0.03, snap: 0.008, gain: 0.3, second: 0.07),
            .insert: Self.makeClunk(thump: 120, decay: 0.03, snap: 0.005, gain: 0.28, second: 0.05),
        ]
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.start()
            self?.onRestart?()
        }
        start()
    }

    private func start() {
        engine.prepare()
        try? engine.start()
        fx.play()
    }

    func clunk(_ kind: Clunk) {
        guard let b = clunks[kind] else { return }
        if !engine.isRunning { start() }
        if !fx.isPlaying { fx.play() }
        fx.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// Schedules every segment of a side from position `e0` on; gaps stay silent (just hiss).
    func play(_ segments: [Segment], from e0: Double, in dir: URL) {
        player.stop()
        let sr = TapeFormat.sampleRate
        for s in segments where s.end > e0 + 0.001 {
            guard let f = try? AVAudioFile(forReading: dir.appendingPathComponent(s.file)),
                  f.processingFormat.channelCount == 2, f.processingFormat.sampleRate == sr else { continue }
            let into = max(0, e0 - s.start)
            let first = AVAudioFramePosition((s.fileOffset + into) * sr)
            let count = min(AVAudioFramePosition((s.duration - into) * sr), f.length - first)
            guard count > 0 else { continue }
            let when = AVAudioTime(sampleTime: AVAudioFramePosition(max(0, s.start - e0) * sr), atRate: sr)
            player.scheduleSegment(f, startingFrame: first, frameCount: AVAudioFrameCount(count), at: when, completionHandler: nil)
        }
        if !engine.isRunning { start() }
        player.play()
    }

    // MARK: Cue and review

    func startCue() {
        cueFiles = [:]
        cuePlayer.stop()
        if !engine.isRunning { start() }
        cuePlayer.play()
    }

    func stopCue() {
        cuePlayer.stop()
        cueFiles = [:]
    }

    /// Queues the stretch of tape from `a` to `b` squeezed to 1/8 of its length, the way you
    /// hear it when holding FF during play – and backwards for REW.
    func queueCue(_ segments: [Segment], from a: Double, to b: Double, reverse: Bool, in dir: URL) {
        let sr = TapeFormat.sampleRate
        let k = Self.cueFactor
        let outFrames = Int((b - a) * sr) / k
        guard outFrames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: TapeFormat.pcm, frameCapacity: AVAudioFrameCount(outFrames)) else { return }
        out.frameLength = AVAudioFrameCount(outFrames)
        let oL = out.floatChannelData![0], oR = out.floatChannelData![1]
        for i in 0..<outFrames { oL[i] = 0; oR[i] = 0 }
        for s in segments where s.end > a && s.start < b {
            let lo = max(a, s.start), hi = min(b, s.end)
            guard let f = cueFile(s.file, in: dir) else { continue }
            let first = AVAudioFramePosition((s.fileOffset + lo - s.start) * sr)
            let count = min(AVAudioFramePosition((hi - lo) * sr), f.length - first)
            guard first >= 0, count > 0,
                  let tmp = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { continue }
            f.framePosition = first
            guard (try? f.read(into: tmp, frameCount: AVAudioFrameCount(count))) != nil else { continue }
            let iL = tmp.floatChannelData![0], iR = tmp.floatChannelData![1]
            let base = Int((lo - a) * sr) / k
            // Averaging each group of samples keeps the speed-up from aliasing too harshly.
            for j in 0..<(Int(tmp.frameLength) / k) {
                let o = base + j
                guard o < outFrames else { break }
                var sl: Float = 0, sr2: Float = 0
                for q in 0..<k { sl += iL[j * k + q]; sr2 += iR[j * k + q] }
                oL[o] = sl / Float(k)
                oR[o] = sr2 / Float(k)
            }
        }
        if reverse {
            var i = 0, j = outFrames - 1
            while i < j {
                (oL[i], oL[j]) = (oL[j], oL[i])
                (oR[i], oR[j]) = (oR[j], oR[i])
                i += 1; j -= 1
            }
        }
        cuePlayer.scheduleBuffer(out, completionHandler: nil)
    }

    private func cueFile(_ name: String, in dir: URL) -> AVAudioFile? {
        if let f = cueFiles[name] { return f }
        guard let f = try? AVAudioFile(forReading: dir.appendingPathComponent(name)),
              f.processingFormat.channelCount == 2, f.processingFormat.sampleRate == TapeFormat.sampleRate else { return nil }
        cueFiles[name] = f
        return f
    }

    /// Hiss only comes off magnetic tape, never off the leader.
    func setHiss(_ on: Bool) {
        noise.hissTarget = on ? Self.hissLevel : 0
    }

    /// The gentle top-end loss of tape; off means the recording plays back as it went in.
    /// Playback volume for everything coming off the tape, hiss included – not the key clunks.
    func setVolume(_ gain: Float) {
        volumeMix.outputVolume = gain
        noiseNode.volume = gain
    }

    func setRate(_ rate: Float) {
        varispeed.rate = rate
    }

    func setTone(_ on: Bool) {
        eq.bypass = !on
    }

    func stopPlayback() {
        player.stop()
        noise.hissTarget = 0
        varispeed.rate = 1
    }

    /// Wow: the slow pitch drift of a not-quite-perfect capstan.
    func wobble(_ t: Double, on: Bool) {
        varispeed.rate = on ? Float(1 + 0.0022 * sin(2 * .pi * 0.55 * t) + 0.0009 * sin(2 * .pi * 1.7 * t + 1)) : 1
    }

    func spool(_ on: Bool, speed: Double = 0) {
        noise.spoolTarget = on ? Float(0.05 * (0.4 + 0.6 * speed)) : 0
        noise.spoolHz = Float(3 + 9 * speed)
    }

    func shutdown() {
        player.stop()
        cuePlayer.stop()
        fx.stop()
        engine.stop()
    }

    private static func makeClunk(thump: Double, decay: Double, snap: Double, gain: Float, second: Double? = nil) -> AVAudioPCMBuffer {
        let sr = TapeFormat.sampleRate
        let len = Int(sr * 0.25)
        let b = AVAudioPCMBuffer(pcmFormat: TapeFormat.pcm, frameCapacity: AVAudioFrameCount(len))!
        b.frameLength = AVAudioFrameCount(len)
        let l = b.floatChannelData![0], r = b.floatChannelData![1]
        for i in 0..<len { l[i] = 0; r[i] = 0 }
        var seed: UInt32 = 12_345
        for (k, start) in ([0.0] + (second.map { [$0] } ?? [])).enumerated() {
            let off = Int(start * sr)
            let g = k == 0 ? gain : gain * 0.6
            for i in 0..<(len - off) {
                let t = Double(i) / sr
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let w = Float(Int32(bitPattern: seed)) / 2_147_483_648
                let v = (Float(sin(2 * .pi * thump * t) * exp(-t / decay)) * 0.8 + w * Float(exp(-t / snap))) * g
                l[off + i] += v
                r[off + i] += v
            }
        }
        return b
    }
}

// MARK: - Recording

/// The record level fader on its way onto the tape. Up to the unity mark (about 7 on the scale)
/// it is a plain level control. Beyond that it drives the tape into saturation: the sound gets
/// fatter, dirtier, more squashed and duller, while makeup gain behind the tape keeps it from
/// getting much louder – like overdriving a cassette deck, where the needles pin in the red
/// but the volume hardly rises.
final class TapeDrive {
    static let unityFader = 30.0 / 42.0
    private(set) var input: Float = 1
    private(set) var makeup: Float = 1
    private(set) var overdrive: Float = 0     // 0 clean … 1 fully driven
    private var lpL: Float = 0, lpR: Float = 0
    private var dcInL: Float = 0, dcOutL: Float = 0, dcInR: Float = 0, dcOutR: Float = 0

    func setFader(_ p: Double) {
        if p <= 0.001 {
            input = 0; makeup = 1; overdrive = 0
        } else if p <= Self.unityFader {
            input = Float(pow(10, (p * 42 - 30) / 20))   // −30 … 0 dB
            makeup = 1
            overdrive = 0
        } else {
            let o = (p - Self.unityFader) / (1 - Self.unityFader)
            input = Float(pow(10, 34 * o / 20))           // up to +34 dB into the tape
            makeup = Float(pow(10, -9 * o.squareRoot() / 20))
            overdrive = Float(o)
        }
    }

    /// Level going into the tape – what the VU meters show.
    func applyInput(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            l[i] *= input
            r[i] *= input
        }
    }

    /// What the tape makes of it.
    func saturate(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        let o = overdrive
        let coef = 1 - 0.5 * o          // overdriven tape loses its top end first
        for i in 0..<n {
            l[i] = shape(l[i], o, coef, &lpL, &dcInL, &dcOutL)
            r[i] = shape(r[i], o, coef, &lpR, &dcInR, &dcOutR)
        }
    }

    @inline(__always) private func shape(_ x: Float, _ o: Float, _ coef: Float,
                                         _ lp: inout Float, _ dcIn: inout Float, _ dcOut: inout Float) -> Float {
        var y = tapeSaturate(x)
        if o > 0 {
            // Asymmetric curve: adds the even harmonics that make tape distortion sound warm.
            let bias: Float = 0.2
            let warm = tanhf(0.9 * x + bias) - tanhf(bias)
            y += (warm - y) * o
            // Asymmetry leaves a DC offset; block it.
            let hp = y - dcIn + 0.995 * dcOut
            dcIn = y
            dcOut = hp
            y = hp
        }
        lp += (y - lp) * coef
        return lp * makeup
    }
}

/// Converts whatever comes in to 48 kHz stereo and encodes it, stopping when the tape runs out.
final class TapeWriter {
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let maxFrames: AVAudioFramePosition
    private var written: AVAudioFramePosition = 0
    private var ended = false
    /// False in record-pause: the input is still metered but the tape stands still.
    var writing = true
    private var squeal = 0, squealTotal = 0
    private var pauseAfterSqueal = false
    var onEnd: (() -> Void)?

    /// When the pause key went in or out, the tape lurched for a moment. These put that
    /// lurch on the recording: a fraction of a second squeezed and pitched up.
    static let squealFrames = Int(TapeFormat.sampleRate * 0.12)

    func squealThenPause() {
        guard writing else { return }
        squeal = Self.squealFrames
        squealTotal = squeal
        pauseAfterSqueal = true
    }

    func squealThenResume() {
        writing = true
        pauseAfterSqueal = false
        squeal = Self.squealFrames
        squealTotal = squeal
    }

    init(url: URL, maxFrames: AVAudioFramePosition) throws {
        self.maxFrames = maxFrames
        var lastError: Error = TapeError.tool("AAC")
        for s in TapeFormat.encoderSettings {
            do {
                file = try AVAudioFile(forWriting: url, settings: s, commonFormat: .pcmFormatFloat32, interleaved: false)
                break
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: url)
            }
        }
        if file == nil { throw lastError }
    }

    private let drive = TapeDrive()

    /// Applies the record level, shows it on the meters and – unless paused – puts it on tape
    /// through the tape's saturation. Returns the frames on tape so far.
    func append(_ input: AVAudioPCMBuffer, fader: Double, meter: LevelMeter) -> AVAudioFramePosition {
        guard !ended, let file, var buf = toTape(input) else { return written }
        drive.setFader(fader)
        drive.applyInput(buf.floatChannelData![0], buf.floatChannelData![1], Int(buf.frameLength))
        meter.feed(buf)
        guard writing else { return written }
        if squeal > 0 {
            buf = squealed(buf)
            if squeal == 0 && pauseAfterSqueal {
                pauseAfterSqueal = false
                writing = false
            }
        }
        drive.saturate(buf.floatChannelData![0], buf.floatChannelData![1], Int(buf.frameLength))
        let room = maxFrames - written
        if AVAudioFramePosition(buf.frameLength) >= room {
            buf.frameLength = AVAudioFrameCount(max(0, room))
            ended = true
        }
        if buf.frameLength > 0 {
            do {
                try file.write(from: buf)
                written += AVAudioFramePosition(buf.frameLength)
            } catch {
                ended = true
            }
        }
        if ended { onEnd?() }
        return written
    }

    /// Blank tape running past the head: what gets recorded while the source delivers nothing.
    func appendSilence(seconds: Double) -> AVAudioFramePosition {
        guard !ended, writing, let file else { return written }
        var n = AVAudioFramePosition(seconds * TapeFormat.sampleRate)
        n = min(n, maxFrames - written)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: TapeFormat.pcm, frameCapacity: AVAudioFrameCount(n)) else { return written }
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<2 { memset(buf.floatChannelData![c], 0, Int(n) * MemoryLayout<Float>.size) }
        do {
            try file.write(from: buf)
            written += n
        } catch {
            ended = true
        }
        if written >= maxFrames { ended = true }
        if ended { onEnd?() }
        return written
    }

    func finish() -> AVAudioFramePosition {
        file = nil   // closes and finalises the m4a
        return written
    }

    /// Reads through the buffer faster for the rest of the squeal (speed rising to 1.7× and
    /// back), so that stretch comes out shorter and higher.
    private func squealed(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let n = Int(b.frameLength)
        guard n > 1, let out = AVAudioPCMBuffer(pcmFormat: TapeFormat.pcm, frameCapacity: AVAudioFrameCount(n)) else { return b }
        let l = b.floatChannelData![0], r = b.floatChannelData![1]
        let oL = out.floatChannelData![0], oR = out.floatChannelData![1]
        var pos = 0.0
        var o = 0
        while o < n {
            let i = Int(pos)
            guard i + 1 < n else { break }
            let f = Float(pos - Double(i))
            oL[o] = l[i] + (l[i + 1] - l[i]) * f
            oR[o] = r[i] + (r[i + 1] - r[i]) * f
            o += 1
            if squeal > 0 {
                let p = 1 - Double(squeal) / Double(squealTotal)
                pos += 1 + 0.7 * sin(.pi * p)
                squeal -= 1
            } else {
                pos += 1
            }
        }
        out.frameLength = AVAudioFrameCount(o)
        return out
    }

    private func toTape(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inF = b.format
        let channels: AVAudioChannelCount = inF.channelCount >= 2 ? 2 : 1
        let mid = AVAudioFormat(standardFormatWithSampleRate: TapeFormat.sampleRate, channels: channels)!
        var out = b
        if inF != mid {
            if converter == nil || converterInput != inF {
                converter = AVAudioConverter(from: inF, to: mid)
                converter?.downmix = inF.channelCount > 2
                converterInput = inF
            }
            guard let conv = converter else { return nil }
            let cap = AVAudioFrameCount(Double(b.frameLength) * TapeFormat.sampleRate / inF.sampleRate) + 256
            guard let o = AVAudioPCMBuffer(pcmFormat: mid, frameCapacity: cap) else { return nil }
            var fed = false
            var err: NSError?
            conv.convert(to: o, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return b
            }
            if err != nil { return nil }
            out = o
        }
        if channels == 2 { return out }
        // Mono in → same signal on both channels.
        guard let st = AVAudioPCMBuffer(pcmFormat: TapeFormat.pcm, frameCapacity: max(out.frameLength, 1)) else { return nil }
        st.frameLength = out.frameLength
        let bytes = Int(out.frameLength) * MemoryLayout<Float>.size
        memcpy(st.floatChannelData![0], out.floatChannelData![0], bytes)
        memcpy(st.floatChannelData![1], out.floatChannelData![0], bytes)
        return st
    }
}

/// Records into one new audio file on the tape. Microphone and system audio are separate
/// captures; once a source has been used in a take it stays open, so the selector flips
/// between them instantly. The system capture heals itself if it drops out, e.g. while
/// headphones are being switched.
final class TapeRecorder {
    let url: URL
    private let writer: TapeWriter
    private let queue = DispatchQueue(label: "mixtape.recorder")
    private let startQueue = DispatchQueue(label: "mixtape.recorder.start", qos: .userInitiated)
    /// Called (on a background queue) when system audio could not be had for a long while.
    var onStartFailure: ((Error) -> Void)?
    var onEnd: (() -> Void)?
    /// Start in record-pause (standby): metering, but nothing goes on tape yet.
    var startPaused = false
    /// The active source after the record level, for the VU meters.
    let meter = LevelMeter()

    private var tap: SystemAudioTap?
    private var mic: MicCapture?
    private var watchdog: DispatchSourceTimer?
    private var transportClock: DispatchSourceTimer?
    private var lastActiveBuffer = CFAbsoluteTimeGetCurrent()
    private var lastClockTick = CFAbsoluteTimeGetCurrent()
    private let lock = NSLock()
    private var frames: AVAudioFramePosition = 0
    private var _fader = TapeDrive.unityFader
    private var _source: RecordSource
    private var received = 0
    private var lastSystemBuffer = CFAbsoluteTimeGetCurrent()
    private var tapStarting = false
    private var stopped = false

    init(url: URL, maxFrames: AVAudioFramePosition, source: RecordSource) throws {
        self.url = url
        _source = source
        writer = try TapeWriter(url: url, maxFrames: maxFrames)
    }

    var source: RecordSource {
        lock.lock(); defer { lock.unlock() }
        return _source
    }

    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(frames) / TapeFormat.sampleRate
    }

    /// Whether any sound has arrived from the active source.
    var hasInput: Bool {
        lock.lock(); defer { lock.unlock() }
        return received > 0
    }

    /// Record level fader position, 0…1.
    var fader: Double {
        get { lock.lock(); defer { lock.unlock() }; return _fader }
        set { lock.lock(); _fader = newValue; lock.unlock() }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [writer] in
            if paused { writer.squealThenPause() } else { writer.squealThenResume() }
        }
    }

    func start() throws {
        writer.onEnd = { [weak self] in self?.onEnd?() }
        writer.writing = !startPaused
        lastActiveBuffer = CFAbsoluteTimeGetCurrent() - 1   // blank tape until the first sound
        lastClockTick = CFAbsoluteTimeGetCurrent()
        try open(source)
        startWatchdog()
        startTransportClock()
    }

    /// The tape runs at a steady speed whether or not sound arrives, like a real deck: when the
    /// active source goes quiet (still starting up, headphones switching), blank tape is recorded.
    private func startTransportClock() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let dt = now - self.lastClockTick
            self.lastClockTick = now
            self.lock.lock()
            let starving = now - self.lastActiveBuffer > 0.3
            self.lock.unlock()
            guard starving else { return }
            let n = self.writer.appendSilence(seconds: dt)
            self.lock.lock()
            self.frames = n
            self.lock.unlock()
        }
        timer.resume()
        transportClock = timer
    }

    /// Like the input selector on a deck: what is recorded changes at once, the tape keeps running.
    func switchSource(to newSource: RecordSource) throws {
        lock.lock()
        _source = newSource
        received = 0
        lastSystemBuffer = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        try open(newSource)
    }

    private func open(_ s: RecordSource) throws {
        switch s {
        case .system:
            if tap == nil { startTap() }
        case .mic:
            if mic == nil { mic = try startMic() }
        }
    }

    private func startTap() {
        let t = SystemAudioTap()
        tap = t
        lock.lock(); tapStarting = true; lock.unlock()
        startQueue.async { [weak self] in
            do {
                try t.start { b in self?.receive(b, from: .system) }
            } catch {
                // Reported for the log only; the watchdog keeps trying.
                if !t.cancelled { self?.onStartFailure?(error) }
            }
            guard let self else { return }
            self.lock.lock()
            self.tapStarting = false
            self.lastSystemBuffer = CFAbsoluteTimeGetCurrent()
            self.lock.unlock()
        }
    }

    private func startMic() throws -> MicCapture {
        let m = MicCapture()
        try m.start { [weak self] b in self?.receive(b, from: .mic) }
        return m
    }

    /// If system audio is the active source but stops arriving – the output device changed,
    /// a Bluetooth headset switched modes – quietly set the capture up again.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: startQueue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let quiet = CFAbsoluteTimeGetCurrent() - self.lastSystemBuffer
            let due = self._source == .system && !self.tapStarting && !self.stopped && quiet > 1.5
            self.lock.unlock()
            guard due, let old = self.tap else { return }
            DiagnosticLog.write("system tap: no audio for \(String(format: "%.1f", quiet)) s, restarting")
            old.cancelled = true
            old.stop()
            self.startTap()
        }
        timer.resume()
        watchdog = timer
    }

    private func receive(_ b: AVAudioPCMBuffer, from s: RecordSource) {
        lock.lock()
        if s == .system { lastSystemBuffer = CFAbsoluteTimeGetCurrent() }
        let active = s == _source
        if active {
            received += 1
            lastActiveBuffer = CFAbsoluteTimeGetCurrent()
        }
        lock.unlock()
        guard active, let copy = b.deepCopy() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let n = self.writer.append(copy, fader: self.fader, meter: self.meter)
            self.lock.lock()
            self.frames = n
            self.lock.unlock()
        }
    }

    /// Stops capturing, flushes the file and returns how many frames went onto the tape.
    func stop() -> AVAudioFramePosition {
        lock.lock(); stopped = true; lock.unlock()
        watchdog?.cancel()
        watchdog = nil
        transportClock?.cancel()
        transportClock = nil
        if let t = tap {
            t.cancelled = true
            startQueue.sync { t.stop() }   // waits for a start still in progress
        }
        tap = nil
        mic?.stop()
        mic = nil
        return queue.sync { writer.finish() }
    }
}

/// Records straight from a microphone device. A Bluetooth headset's microphone forces the
/// headset into its telephone mode: the music in your ears drops to 16 kHz mono, the device
/// reconfigures and audio engines stall. So when the default input is Bluetooth, the Mac's
/// built-in microphone is used instead.
final class MicCapture {
    private var device = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "mixtape.mic", qos: .userInitiated)

    func start(_ handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let dev = Self.chosenDevice() else { throw TapeError.noInput }
        device = dev
        var streamsAddr = Self.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &streamsAddr, 0, nil, &size) == noErr, size > 0 else { throw TapeError.noInput }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(dev, &streamsAddr, 0, nil, &size, &streams) == noErr, let stream = streams.first else {
            throw TapeError.noInput
        }
        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = Self.address(kAudioStreamPropertyVirtualFormat)
        guard AudioObjectGetPropertyData(stream, &formatAddr, 0, nil, &size, &asbd) == noErr else { throw TapeError.noInput }
        var rate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = Self.address(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectGetPropertyData(dev, &rateAddr, 0, nil, &size, &rate) == noErr, rate > 0 { asbd.mSampleRate = rate }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw TapeError.noInput }
        let buffersNeeded = format.isInterleaved ? 1 : Int(format.channelCount)
        DiagnosticLog.write("microphone: device \(dev) \(Self.name(dev)), \(format)")

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, ioQueue) { _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard list.count >= buffersNeeded else { return }
            if list.count == buffersNeeded {
                if let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) { handler(buf) }
                return
            }
            // Several input streams: the first one is the one we described.
            let head = AudioBufferList.allocate(maximumBuffers: buffersNeeded)
            defer { free(head.unsafeMutablePointer) }
            for i in 0..<buffersNeeded { head[i] = list[i] }
            if let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: head.unsafePointer, deallocator: nil) { handler(buf) }
        }
        guard status == noErr else { throw TapeError.capture("Mic IOProc", status) }
        let started = AudioDeviceStart(dev, procID)
        guard started == noErr else { stop(); throw TapeError.capture("Mic Start", started) }
    }

    func stop() {
        if let p = procID {
            AudioDeviceStop(device, p)
            AudioDeviceDestroyIOProcID(device, p)
        }
        procID = nil
    }

    /// The default input – unless that is a Bluetooth headset, then the built-in microphone.
    static func chosenDevice() -> AudioDeviceID? {
        let current = defaultInput()
        if let c = current, !isBluetooth(c) { return c }
        if let builtIn = devices().first(where: { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }) {
            if current != nil { DiagnosticLog.write("microphone: default input is Bluetooth, using the built-in microphone") }
            return builtIn
        }
        return current
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        let ok = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        return ok && id != 0 ? id : nil
    }

    private static func devices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyTransportType)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr ? t : 0
    }

    private static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let t = transport(id)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func name(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var n: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &n) == noErr, let s = n else { return "?" }
        return s.takeRetainedValue() as String
    }
}

/// A small log at ~/Library/Logs/Mixtape.log, so failures on someone's Mac can be traced.
enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "mixtape.log")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Mixtape.log")

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            let data = Data("\(stamp) \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// Trips exactly once, from any thread.
final class OnceFlag {
    private let lock = NSLock()
    private var done = false

    func trip() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Captures everything the Mac plays (Spotify, YouTube in the browser, Music …)
/// through a Core Audio process tap, like taping songs off the radio.
final class SystemAudioTap {
    private static let unknown = AudioObjectID(kAudioObjectUnknown)
    static var excludeSelf = true
    /// Whether the aggregate also contains the output device (as clock source) or only the tap.
    /// Tap-only keeps capture independent of the output device, which may switch rate or
    /// mode at any moment (Bluetooth headsets do) – and it reports its true rate.
    static var withOutputDevice = false
    private(set) var lastFormat: AVAudioFormat?
    private var tapID = unknown
    private var aggregateID = unknown
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "mixtape.systemtap", qos: .userInitiated)

    /// Starts capturing. A freshly made aggregate device sometimes isn't ready yet when its
    /// IO starts – then it runs silently and delivers nothing. So wait for the first buffer
    /// and, if none comes, tear down and try again.
    /// Set from another thread to give up between attempts.
    var cancelled = false

    /// Blocking; call it off the main thread – the HAL may need the main thread to finish
    /// setting up the new device, and waiting there would starve it.
    func start(_ handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        var lastError: Error?
        for attempt in 0..<5 where !cancelled {
            do {
                if try startOnce(handler) {
                    DiagnosticLog.write("system tap: running after attempt \(attempt + 1)")
                    return
                }
                DiagnosticLog.write("system tap: attempt \(attempt + 1) delivered no audio")
            } catch {
                lastError = error
                DiagnosticLog.write("system tap: attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
            stop()
            Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
        }
        throw lastError ?? TapeError.noSystemAudio
    }

    /// One try, for measuring: did audio arrive, and how long did it take?
    func benchmarkOnce(timeout: Double = 1.5) -> (ok: Bool, seconds: Double) {
        let t0 = Date()
        let ok = (try? startOnce(timeout: timeout) { _ in }) ?? false
        let dt = Date().timeIntervalSince(t0)
        stop()
        return (ok, dt)
    }

    private func startOnce(timeout: Double = 1.5, _ handler: @escaping (AVAudioPCMBuffer) -> Void) throws -> Bool {
        // Leave our own clunks and hiss out of the recording.
        let exclude = Self.excludeSelf ? (Self.ownProcessObject().map { [$0] } ?? []) : []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.name = "Mixtape"
        desc.isPrivate = true   // unmuted by default: you keep hearing what you record
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "Tap")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "Format")

        let outputUID: String
        do { outputUID = try Self.defaultOutputUID() } catch { stop(); throw error }
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixtape Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        if !Self.withOutputDevice {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = nil
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = nil
            aggregate[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapDriftCompensationKey: false,
                                                           kAudioSubTapUIDKey: desc.uuid.uuidString]]
        }
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Aggregate")
        let inputs = Self.waitUntilReady(aggregateID)
        // The tap may claim 48 kHz while the device actually runs at, say, 44.1 kHz. Trust the
        // device: otherwise every recording plays back too fast and too high.
        let deviceRate = Self.nominalSampleRate(aggregateID)
        if deviceRate > 0 { asbd.mSampleRate = deviceRate }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw TapeError.capture("Format", -1)
        }
        lastFormat = format
        DiagnosticLog.write("system tap: aggregate \(aggregateID) ready with \(inputs) input stream(s), device rate \(deviceRate), format \(format)")

        let first = DispatchSemaphore(value: 0)
        let seen = OnceFlag()
        let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard list.count >= tapBuffers else { return }
            if seen.trip() { first.signal() }
            if list.count == tapBuffers {
                if let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) { handler(buf) }
                return
            }
            // If the output device has inputs of its own (a headset's microphone), those come
            // first in the aggregate. The tap is always last.
            let tail = AudioBufferList.allocate(maximumBuffers: tapBuffers)
            defer { free(tail.unsafeMutablePointer) }
            for i in 0..<tapBuffers { tail[i] = list[list.count - tapBuffers + i] }
            if let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: tail.unsafePointer, deallocator: nil) { handler(buf) }
        }, "IOProc")
        try check(AudioDeviceStart(aggregateID, procID), "Start")
        return first.wait(timeout: .now() + timeout) == .success
    }

    private static func nominalSampleRate(_ id: AudioObjectID) -> Double {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr ? rate : 0
    }

    /// A fresh aggregate device needs a moment before it is alive and has its input streams.
    /// Returns how many input streams it ended up with.
    private static func waitUntilReady(_ id: AudioObjectID) -> Int {
        var alive = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var count = 0
        for _ in 0..<50 {
            var isAlive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let ok = AudioObjectGetPropertyData(id, &alive, 0, nil, &size, &isAlive) == noErr && isAlive != 0
            var bytes: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr {
                count = Int(bytes) / MemoryLayout<AudioStreamID>.size
            }
            if ok && count > 0 { return count }
            usleep(20_000)
        }
        return count
    }

    /// Lets the HAL deliver device notifications on its own thread instead of waiting for
    /// our main run loop. Must happen before anything else in the app touches Core Audio.
    static func useOwnNotificationThread() {
        var runLoop: CFRunLoop? = nil
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyRunLoop,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<CFRunLoop?>.size), &runLoop)
    }

    func stop() {
        if aggregateID != Self.unknown {
            if let p = procID {
                AudioDeviceStop(aggregateID, p)
                AudioDeviceDestroyIOProcID(aggregateID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != Self.unknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = Self.unknown
        tapID = Self.unknown
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr {
            stop()
            throw TapeError.capture(step, status)
        }
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var obj = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return status == noErr && obj != unknown ? obj : nil
    }

    private static func defaultOutputUID() throws -> String {
        var device = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard status == noErr else { throw TapeError.capture("Output", status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard status == noErr, let u = uid else { throw TapeError.capture("Output UID", status) }
        return u.takeRetainedValue() as String
    }
}
