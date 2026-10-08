import AVFoundation

/// One successor is decoded/prepared in advance and starts on the shared output clock.
/// Different rates/channels fall back to normal playback so the route can be reconfigured.
@MainActor
final class GaplessScheduler {
    private(set) var trackID: String?
    private var player: AVAudioPlayer?
    private(set) var scheduledTime: TimeInterval?

    func cancel() { player?.stop(); player = nil; trackID = nil; scheduledTime = nil }

    func schedule(_ track: Track, url: URL, after current: AVAudioPlayer, volume: Float, rate: Float, endTime: TimeInterval? = nil) {
        if trackID == track.id, let player { player.volume = volume; return }
        cancel()
        guard current.isPlaying, current.duration - current.currentTime > 0.15,
              let next = try? AVAudioPlayer(contentsOf: url),
              next.format.sampleRate == current.format.sampleRate,
              next.numberOfChannels == current.numberOfChannels else { return }
        next.enableRate = true; next.rate = rate; next.volume = volume
        guard next.prepareToPlay() else { return }
        let start = endTime ?? (current.deviceCurrentTime + (current.duration - current.currentTime) / Double(rate))
        guard start > current.deviceCurrentTime else { return }
        guard next.play(atTime: start) else { return }
        player = next; trackID = track.id; scheduledTime = start
    }

    func take(for id: String) -> AVAudioPlayer? {
        guard trackID == id else { cancel(); return nil }
        let result = player
        player = nil; trackID = nil; scheduledTime = nil
        return result
    }
    isolated deinit { player?.stop() }
}
