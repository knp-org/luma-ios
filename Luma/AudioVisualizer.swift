import AVFoundation
import Observation

/// Live amplitude bars driven by channel levels and peaks, not a frequency spectrum.
/// Kept separate from playback state so meter updates only redraw the visualizer.
@MainActor @Observable
final class AudioVisualizer {
    static let sampleCount = 32
    private(set) var levels = Array(repeating: Float.zero, count: sampleCount)
    @ObservationIgnored private weak var audio: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func attach(_ audio: AVAudioPlayer?) {
        self.audio?.isMeteringEnabled = false
        self.audio = audio
        audio?.isMeteringEnabled = timer != nil
        reset()
    }

    func setActive(_ active: Bool) {
        guard active else {
            timer?.invalidate(); timer = nil
            audio?.isMeteringEnabled = false
            reset()
            return
        }
        guard timer == nil else { return }
        audio?.isMeteringEnabled = true
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func reset() {
        levels = Array(repeating: 0, count: Self.sampleCount)
    }

    func sample() {
        guard timer != nil, let audio, audio.isPlaying else { return }
        audio.updateMeters()
        let averages = (0..<audio.numberOfChannels).map { Self.displayLevel(decibels: audio.averagePower(forChannel: $0)) }
        let peaks = (0..<audio.numberOfChannels).map { Self.displayLevel(decibels: audio.peakPower(forChannel: $0)) }
        guard !averages.isEmpty else { reset(); return }
        // Each fixed bar follows the current audio, with varied peak sensitivity and
        // release. No scrolling samples, random heights, or time-based oscillation.
        levels = levels.enumerated().map { index, previous in
            let channel = index % averages.count
            let peakWeight = Float(index % 4) / 3
            // Peak meters can hold a transient after the signal falls. Bound their
            // contribution by the current average so quiet passages settle down.
            let peak = min(peaks[channel], averages[channel] * 1.5)
            let energy = averages[channel] * (1 - peakWeight) + peak * peakWeight
            let position = Float(index) / Float(Self.sampleCount - 1)
            let shape = 0.45 + 0.55 * sin(.pi * position)
            let target = min(1, energy * shape)
            let response: Float = target > previous ? 0.85 : 0.18 + Float(index % 5) * 0.035
            return previous + (target - previous) * response
        }
    }

    static func displayLevel(decibels: Float) -> Float {
        guard decibels.isFinite, decibels > -60 else { return 0 }
        return min(1, pow(10, min(0, decibels) / 40))
    }

    isolated deinit {
        timer?.invalidate()
        audio?.isMeteringEnabled = false
    }
}
