import SwiftUI

struct PlayerArtworkView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsVisualizer = false
    var isVisible: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if showsVisualizer {
                AudioVisualizerView(visualizer: player.visualizer, isPlaying: player.isPlaying, isVisible: isVisible)
            } else {
                TrackArtwork(track: player.current, showType: true)
            }
            Button {
                showsVisualizer.toggle()
            } label: {
                Label(showsVisualizer ? "Artwork" : "Visualizer", systemImage: showsVisualizer ? "square.stack" : "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel(showsVisualizer ? "Show artwork" : "Show visualizer")
            .accessibilityIdentifier("player.visualizerToggle")
            .padding(14)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 20)
        .scaleEffect(player.isPlaying || showsVisualizer ? 1 : 0.96)
        .animation(reduceMotion ? nil : .spring(duration: 0.5), value: player.isPlaying)
    }
}

struct AudioVisualizerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let visualizer: AudioVisualizer
    let isPlaying: Bool
    let isVisible: Bool

    private var sampling: Bool { isVisible && isPlaying && scenePhase == .active && !reduceMotion }
    private var status: String { reduceMotion ? "Reduce Motion is on" : isPlaying ? "Live audio" : "Paused" }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.06)).blur(radius: 40).padding(45)
            VStack(alignment: .leading, spacing: 6) {
                Text("AUDIO VISUALIZER").font(.system(size: 9, weight: .semibold)).tracking(2)
                Text(status).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
            }.padding(22)
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<AudioVisualizer.sampleCount, id: \.self) { index in
                        Capsule()
                            .fill(LinearGradient(colors: [.white.opacity(0.95), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                            .frame(height: max(2, CGFloat(visualizer.levels[index]) * geometry.size.height))
                            .animation(sampling ? .linear(duration: 1.0 / 30) : nil, value: visualizer.levels[index])
                    }
                }.frame(height: geometry.size.height, alignment: .bottom)
            }
            .padding(.horizontal, 22).padding(.vertical, 76)
            .accessibilityHidden(true)
        }
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio visualizer")
        .accessibilityValue(status)
        .accessibilityIdentifier("player.visualizer")
        .onChange(of: sampling, initial: true) { _, active in visualizer.setActive(active) }
        .onDisappear { visualizer.setActive(false) }
    }
}
