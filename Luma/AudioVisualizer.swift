import AVFoundation
import Accelerate
import Observation

/// Live frequency-spectrum bars, bass on the left to treble on the right, with falling peak caps.
/// Matches the desktop app: 48 log bands from 40 Hz to 16 kHz, scaled by playback volume.
/// AVAudioPlayer exposes no sample tap, so the playing file is read separately at the
/// audible position and analysed with an FFT. Kept separate from playback state so
/// updates only redraw the visualizer.
@MainActor @Observable
final class AudioVisualizer {
    static let sampleCount = 48
    private(set) var levels = Array(repeating: Float.zero, count: sampleCount)
    private(set) var peaks = Array(repeating: Float.zero, count: sampleCount)
    @ObservationIgnored private weak var audio: AVAudioPlayer?
    @ObservationIgnored private var analyzer: SpectrumAnalyzer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var targets = Array(repeating: Float.zero, count: sampleCount)
    @ObservationIgnored private var lastFrame: TimeInterval?

    func attach(_ audio: AVAudioPlayer?) {
        self.audio = audio
        analyzer = audio?.url.map { SpectrumAnalyzer(url: $0, bandCount: Self.sampleCount) }
        reset()
    }

    func setActive(_ active: Bool) {
        guard active else {
            timer?.invalidate(); timer = nil
            reset()
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func reset() {
        generation += 1
        inFlight = false
        lastFrame = nil
        targets = Array(repeating: 0, count: Self.sampleCount)
        levels = targets
        peaks = targets
    }

    func sample() {
        guard timer != nil else { return }
        guard let audio, audio.isPlaying, audio.volume > 0, let analyzer else {
            // Paused or muted: let the bars and caps fall away rather than freezing.
            targets = Array(repeating: 0, count: Self.sampleCount)
            if peaks.contains(where: { $0 > 0 }) { step() } else { lastFrame = nil }
            return
        }
        step()
        guard !inFlight else { return }
        let gain = 20 * log10(min(1, audio.volume))
        // Analyse what is reaching the ears, not what was just handed to the hardware (matters for Bluetooth).
        let time = max(0, audio.currentTime - AVAudioSession.sharedInstance().outputLatency * Double(audio.rate))
        let generation = generation
        inFlight = true
        analyzer.bands(at: time) { [weak self] decibels in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.inFlight = false
                guard let decibels else { return }
                self.targets = decibels.map { Self.displayLevel(decibels: $0 + gain) }
            }
        }
    }

    /// Time-based easing: bars rise with a 48 ms time constant and fall with 170 ms;
    /// peak caps hold the highest level and drop a full bar height in 1.1 s.
    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(min(0.064, max(0.001, now - (lastFrame ?? now - 1.0 / 60))))
        lastFrame = now
        var levels = levels, peaks = peaks
        for index in levels.indices {
            let speed: Float = targets[index] > levels[index] ? 0.048 : 0.170
            levels[index] += (targets[index] - levels[index]) * (1 - exp(-dt / speed))
            if levels[index] < 0.001 { levels[index] = 0 }
            peaks[index] = max(levels[index], peaks[index] - dt / 1.1)
        }
        self.levels = levels
        self.peaks = peaks
    }

    /// Maps a band level in dBFS onto 0...1, linear in decibels with a -70 dB floor.
    static func displayLevel(decibels: Float) -> Float {
        guard decibels.isFinite, decibels > -70 else { return 0 }
        return min(1, (decibels + 70) / 70)
    }

    isolated deinit {
        timer?.invalidate()
    }
}

/// Reads a window of samples from an audio file and reduces its spectrum to log-spaced bands.
/// All state is confined to `queue`.
final class SpectrumAnalyzer: @unchecked Sendable {
    private static let log2n: vDSP_Length = 12
    private static let size = 1 << Int(log2n)
    private let queue = DispatchQueue(label: "studio.luma.visualizer", qos: .userInteractive)
    private let url: URL
    private let bandCount: Int
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?
    private var bandBins: [Range<Int>] = []
    private let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
    private var mono = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imag = [Float](repeating: 0, count: size / 2)
    private var power = [Float](repeating: 0, count: size / 2)

    init(url: URL, bandCount: Int) {
        self.url = url
        self.bandCount = bandCount
    }

    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

    /// Calls back on a background queue with each band's level in dBFS, or nil if the file can't be read.
    func bands(at time: TimeInterval, completion: @escaping @Sendable ([Float]?) -> Void) {
        queue.async { completion(self.analyse(at: time)) }
    }

    private func open() -> Bool {
        if file != nil { return true }
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Self.size)) else { return false }
        self.file = file
        self.buffer = buffer
        let rate = file.processingFormat.sampleRate
        let binWidth = rate / Double(Self.size)
        let low = 40.0, high = min(16_000, rate / 2)
        // Log-spaced edges; every band gets at least one bin, and adjacent bands never share one.
        var previousEnd = 1
        bandBins = (0..<bandCount).map { index in
            let upper = low * pow(high / low, Double(index + 1) / Double(bandCount))
            let start = previousEnd
            let end = max(start + 1, min(Self.size / 2, Int((upper / binWidth).rounded())))
            previousEnd = end
            return start..<end
        }
        return true
    }

    private func analyse(at time: TimeInterval) -> [Float]? {
        guard let setup, open(), let file, let buffer else { return nil }
        let rate = file.processingFormat.sampleRate
        let centre = AVAudioFramePosition(time * rate)
        let start = max(0, min(centre - AVAudioFramePosition(Self.size / 2), file.length - AVAudioFramePosition(Self.size)))
        file.framePosition = max(0, start)
        do { try file.read(into: buffer, frameCount: AVAudioFrameCount(Self.size)) } catch { return nil }
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        // Mix down to mono, zero-padding a short final read.
        vDSP.fill(&mono, with: 0)
        for channel in 0..<channelCount {
            mono.withUnsafeMutableBufferPointer { output in
                vDSP_vsma(channels[channel], 1, [1 / Float(channelCount)], output.baseAddress!, 1, output.baseAddress!, 1, vDSP_Length(frames))
            }
        }
        vDSP.multiply(mono, window, result: &mono)

        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                mono.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(Self.size / 2))
            }
        }
        // Scale so a full-scale sine reads 0 dBFS: zrip doubles the output and the Hann window halves the amplitude.
        let scale = 4 / Float(Self.size * Self.size)
        return bandBins.map { bins in
            let peak = power[bins].max() ?? 0
            return 10 * log10(peak * scale + 1e-12)
        }
    }
}
