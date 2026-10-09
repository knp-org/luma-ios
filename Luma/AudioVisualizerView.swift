import SwiftUI

struct PlayerArtworkView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TrackArtwork(track: player.current, showType: true)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 20)
            .scaleEffect(player.isPlaying ? 1 : 0.96)
            .animation(reduceMotion ? nil : .spring(duration: 0.5), value: player.isPlaying)
    }
}

/// Thin silver spectrum strip that sits under the artwork, with a faint reflection and falling peak caps.
struct AudioVisualizerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let visualizer: AudioVisualizer
    let isPlaying: Bool
    let isVisible: Bool

    // Sampling continues briefly after pausing so the bars fall instead of vanishing.
    private var sampling: Bool { isVisible && scenePhase == .active && !reduceMotion }
    private var status: String { reduceMotion ? "Reduce Motion is on" : isPlaying ? "Live audio" : "Paused" }

    var body: some View {
        Canvas { context, size in
            Self.paint(context, size: size, levels: visualizer.levels, peaks: visualizer.peaks)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio visualizer")
        .accessibilityValue(status)
        .accessibilityIdentifier("player.visualizer")
        .onChange(of: sampling, initial: true) { _, active in visualizer.setActive(active) }
        .onDisappear { visualizer.setActive(false) }
    }

    private static func paint(_ context: GraphicsContext, size: CGSize, levels: [Float], peaks: [Float]) {
        let count = levels.count
        let step = size.width / CGFloat(count)
        let baseline = size.height * 0.78
        let maximum = max(1, baseline - 10)
        let barWidth = max(2, step * 0.48)
        let silver = Gradient(stops: [
            .init(color: .white.opacity(0.28), location: 0),
            .init(color: .white.opacity(0.72), location: 0.45),
            .init(color: .white, location: 1),
        ])
        let reflection = Gradient(colors: [.white.opacity(0.16), .white.opacity(0)])
        let barStyle = StrokeStyle(lineWidth: barWidth, lineCap: .round)

        for index in 0..<count {
            let x = step * (CGFloat(index) + 0.5)
            let level = CGFloat(levels[index])
            let bar = max(1, level * maximum)
            var context = context

            context.opacity = 0.45 + level * 0.55
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: baseline)); $0.addLine(to: CGPoint(x: x, y: baseline - bar)) },
                           with: .linearGradient(silver, startPoint: CGPoint(x: 0, y: baseline), endPoint: CGPoint(x: 0, y: 6)),
                           style: barStyle)

            // A quiet reflection grounds the bars without competing with the art.
            context.opacity = level
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: baseline + 5)); $0.addLine(to: CGPoint(x: x, y: baseline + 5 + bar * 0.18)) },
                           with: .linearGradient(reflection, startPoint: CGPoint(x: 0, y: baseline + 5), endPoint: CGPoint(x: 0, y: size.height)),
                           style: barStyle)

            let peak = CGFloat(peaks[index])
            if peak > 0.03 {
                let tip = baseline - peak * maximum - 4
                let half = (barWidth - 1.5) / 2
                context.opacity = min(0.7, peak * 0.85)
                context.stroke(Path { $0.move(to: CGPoint(x: x - half, y: tip)); $0.addLine(to: CGPoint(x: x + half, y: tip)) },
                               with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}
