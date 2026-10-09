import SwiftUI
import AVKit
import MediaPlayer

struct NowPlayingView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    private enum Panel: String, Identifiable {
        case queue, lyrics, settings, playlist, info
        var id: String { rawValue }
    }
    @State private var panel: Panel?
    @AppStorage("player.visualizer") private var showsVisualizer = true
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var tick: (elapsed: TimeInterval, at: Date) = (0, .distantPast)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppBackground(strength: 0.34)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        HStack {
                            GlassIcon(symbol: "chevron.down", label: "Close now playing") { dismiss() }
                            Spacer()
                            VStack(spacing: 5) {
                                Text("NOW PLAYING").font(.system(size: 9, weight: .semibold)).tracking(2.5)
                                Text(player.contextName).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            Spacer()
                            Menu {
                                Button("Add to playlist", systemImage: "text.badge.plus") { panel = .playlist }
                                Button("Lyrics", systemImage: "music.note") { panel = .lyrics }
                                Button("Sleep timer & playback", systemImage: "slider.horizontal.3") { panel = .settings }
                                Button("Track details", systemImage: "info.circle") { panel = .info }
                                if let url = player.url(for: player.current) { ShareLink(item: url) { Label("Share audio file", systemImage: "square.and.arrow.up") } }
                            } label: {
                                Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 46, height: 46)
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }.accessibilityLabel("Player options")
                        }
                        .padding(.top, 10)

                        let artworkWidth = min(geometry.size.width - 56, max(200, geometry.size.height * (showsVisualizer ? 0.35 : 0.39)))
                        PlayerArtworkView()
                            .frame(width: artworkWidth)
                            .padding(.top, geometry.size.height < 750 ? 20 : 28)
                            .padding(.bottom, showsVisualizer ? 14 : 24)
                        if showsVisualizer {
                            AudioVisualizerView(visualizer: player.visualizer, isPlaying: player.isPlaying, isVisible: panel == nil)
                                .frame(width: artworkWidth, height: geometry.size.height < 750 ? 56 : 72)
                                .padding(.bottom, 12)
                                .transition(.opacity)
                        }

                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(player.current.title).font(.system(size: 30, weight: .semibold)).tracking(-1).lineLimit(2)
                                Text(player.current.artist).font(.system(size: 16)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button { withAnimation(.easeInOut(duration: 0.25)) { showsVisualizer.toggle() } } label: {
                                Image(systemName: "chart.bar.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(showsVisualizer ? Theme.accent : .white.opacity(0.45))
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(showsVisualizer ? "Turn visualizer off" : "Turn visualizer on")
                            .accessibilityValue(showsVisualizer ? "On" : "Off")
                            .accessibilityIdentifier("player.visualizerToggle")
                            Button { player.toggleFavorite(player.current) } label: {
                                Image(systemName: player.favorites.contains(player.current.id) ? "heart.fill" : "heart")
                                    .font(.system(size: 22))
                                    .foregroundStyle(player.favorites.contains(player.current.id) ? Theme.accent : .white.opacity(0.7))
                                    .frame(width: 44, height: 44)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .accessibilityLabel(player.favorites.contains(player.current.id) ? "Remove from favorites" : "Add to favorites")
                        }

                        Button {
                            panel = .info
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                Text(player.url(for: player.current)?.pathExtension.uppercased() ?? "Audio")
                                if let bits = player.current.bitDepth { Text("\(bits)-bit") }
                                if let rate = player.current.sampleRate { Text("\((rate / 1000).formatted()) kHz") }
                                Image(systemName: "info.circle")
                            }.font(.caption).foregroundStyle(Theme.secondary)
                        }.buttonStyle(.plain).padding(.top, 12).accessibilityLabel("Audio quality and output details")

                        VStack(spacing: 0) {
                            // The player publishes elapsed every 0.25s; interpolate between ticks so the bar glides.
                            TimelineView(.animation(paused: !player.isPlaying || scrubbing)) { context in
                                let live = player.isPlaying
                                    ? min(tick.elapsed + min(context.date.timeIntervalSince(tick.at), 0.5), player.duration)
                                    : player.elapsed
                                ScrubBar(value: Binding(get: { scrubbing ? scrubPosition : live }, set: { scrubPosition = $0 }),
                                         range: 0...max(player.duration, 1), time: context.date) { editing in
                                    if editing { scrubPosition = live; scrubbing = true }
                                    else { player.seek(to: scrubPosition); scrubbing = false }
                                }
                            }
                            .accessibilityLabel("Playback position")
                            HStack {
                                Text(time(scrubbing ? scrubPosition : player.elapsed))
                                Spacer()
                                Text("−" + time(player.duration - (scrubbing ? scrubPosition : player.elapsed)))
                            }
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                        }
                        .padding(.top, 24)

                        HStack {
                            Button { player.setShuffle(!player.shuffle) } label: {
                                Image(systemName: "shuffle").font(.system(size: 20))
                                    .foregroundStyle(player.shuffle ? Theme.accent : Theme.secondary).frame(width: 44, height: 48)
                            }
                            .accessibilityLabel("Shuffle").accessibilityValue(player.shuffle ? "On" : "Off").accessibilityIdentifier("player.shuffle")
                            Spacer(minLength: 4)
                            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 27)).frame(width: 46, height: 60) }
                                .accessibilityLabel("Previous track")
                            Spacer(minLength: 10)
                            Button { player.toggle() } label: {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 29, weight: .semibold))
                                    .offset(x: player.isPlaying ? 0 : 2)
                                    .frame(width: 78, height: 78)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.tint(Theme.accent.opacity(0.65)).interactive(), in: .circle)
                            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                            .accessibilityIdentifier("player.playPause")
                            Spacer(minLength: 10)
                            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 27)).frame(width: 46, height: 60) }
                                .accessibilityLabel("Next track")
                                .accessibilityIdentifier("player.next")
                            Spacer(minLength: 4)
                            Button { player.cycleRepeat() } label: {
                                Image(systemName: player.repeatMode.symbol).font(.system(size: 20))
                                    .foregroundStyle(player.repeatMode == .off ? Theme.secondary : Theme.accent).frame(width: 44, height: 48)
                            }
                            .accessibilityLabel(player.repeatMode.label).accessibilityValue(player.repeatMode.rawValue).accessibilityIdentifier("player.repeat")
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 25)

                        HStack(spacing: 16) {
                            Image(systemName: "speaker.fill").font(.system(size: 12))
                            // MPVolumeView has no audio route in Simulator.
                            #if targetEnvironment(simulator)
                            ThinSlider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), range: 0...1,
                                       tint: .white.opacity(0.55))
                                .accessibilityLabel("Track volume")
                            #else
                            SystemVolumeSlider()
                            #endif
                            Image(systemName: "speaker.wave.3.fill").font(.system(size: 13))
                        }
                        .foregroundStyle(Theme.secondary).padding(.horizontal, 20).padding(.top, 22)

                        HStack {
                            Button { panel = .lyrics } label: { Image(systemName: "music.note").font(.system(size: 20)).frame(width: 44, height: 44) }
                                .accessibilityLabel("Show lyrics").accessibilityIdentifier("player.lyrics")
                            Spacer()
                            AirPlayButton().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
                            Spacer()
                            Button { panel = .settings } label: {
                                Image(systemName: player.sleepDeadline != nil || player.sleepAtEndOfTrack ? "moon.zzz.fill" : "moon.zzz")
                                    .font(.system(size: 20)).frame(width: 44, height: 44)
                            }.accessibilityLabel("Sleep timer and playback settings").accessibilityIdentifier("player.settings")
                            Spacer()
                            Button { panel = .queue } label: { Image(systemName: "list.bullet").font(.system(size: 20)).frame(width: 44, height: 44) }
                                .accessibilityLabel("Show queue").accessibilityIdentifier("player.queue")
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                        .padding(.top, 15).padding(.bottom, 16)
                    }
                    .padding(.horizontal, 28)
                    .frame(maxWidth: 500).frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(item: $panel) { panel in
            switch panel {
            case .queue: QueueView()
            case .lyrics: LyricsView(track: player.current)
            case .settings: PlayerSettingsView()
            case .playlist: AddToPlaylistView(tracks: [player.current])
            case .info: TrackInfoView(track: player.current)
            }
        }
        .modifier(PlayerFeedback(active: panel == nil))
        .onChange(of: player.current.id) { _, _ in scrubbing = false; scrubPosition = 0 }
        .onChange(of: player.elapsed, initial: true) { _, value in tick = (value, Date()) }
    }

    private func time(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .lightGray
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Device volume drawn with the app's own ThinSlider so it lines up with the speaker icons and matches
/// the other sliders. A hidden MPVolumeView carries the change to the system, which is the only
/// supported route, and keeps the system volume HUD from covering the player.
struct SystemVolumeSlider: View {
    @State private var volume = SystemVolume()

    var body: some View {
        ThinSlider(value: Binding(get: { Double(volume.level) }, set: { volume.set(Float($0)) }), range: 0...1,
                   tint: .white.opacity(0.55))
            .background { HiddenVolumeView(view: volume.volumeView).frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true) }
            .accessibilityLabel("Volume")
    }
}

@MainActor @Observable
final class SystemVolume {
    private(set) var level = AVAudioSession.sharedInstance().outputVolume
    @ObservationIgnored let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        // Follows the hardware buttons and Control Center as well as our own slider.
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] session, _ in
            let value = session.outputVolume
            Task { @MainActor in self?.level = value }
        }
    }

    func set(_ value: Float) {
        level = value
        guard let slider = Self.slider(in: volumeView) else { return }
        slider.value = value
        slider.sendActions(for: .valueChanged)
    }

    private static func slider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews { if let slider = slider(in: subview) { return slider } }
        return nil
    }
}

private struct HiddenVolumeView: UIViewRepresentable {
    let view: MPVolumeView
    func makeUIView(context: Context) -> MPVolumeView { view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Thin capsule slider with a small knob; both grow while dragged.
struct ThinSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color = Theme.accent
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }
    private var fraction: Double { min(max((value - range.lowerBound) / span, 0), 1) }

    var body: some View {
        GeometryReader { geometry in
            let filled = geometry.size.width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(tint).frame(width: filled)
            }
            .frame(height: dragging ? 8 : 4)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                let size: CGFloat = dragging ? 14 : 10
                Circle().fill(.white)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: min(max(filled - size / 2, 0), geometry.size.width - size))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .horizontalScrub(width: geometry.size.width, dragging: $dragging, onEditingChanged: onEditingChanged) { position in
                value = range.lowerBound + position * span
            }
            .animation(.spring(duration: 0.25), value: dragging)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let delta = span * 0.05 * (direction == .increment ? 1 : -1)
            onEditingChanged(true)
            value = min(max(value + delta, range.lowerBound), range.upperBound)
            onEditingChanged(false)
        }
    }
}

/// Playback scrubber matching liquid-glass-ui's GlassSlider with `shimmer` (as in the desktop app),
/// minus the thumb: a white gradient fill with a band of light pushing through it every 2 s.
/// Motion follows `time`, which only advances while playing.
struct ScrubBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var time: Date = .distantPast
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height: CGFloat = dragging ? 9 : 6
            let fill = width * fraction
            let t = time.timeIntervalSinceReferenceDate
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                    .overlay { Capsule().strokeBorder(.white.opacity(0.05), lineWidth: 1) }
                    .frame(height: height)
                if fill > 0 {
                    // progress-push: the band spans the whole fill and travels from -100% to +100%, ease-in-out.
                    let cycle = (t / 2).truncatingRemainder(dividingBy: 1)
                    let eased = cycle * cycle * (3 - 2 * cycle)
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                        .overlay(alignment: .leading) {
                            LinearGradient(colors: [.clear, .white.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: fill)
                                .offset(x: fill * (2 * eased - 1))
                        }
                        .clipShape(Capsule())
                        .frame(width: fill, height: height)
                }
            }
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .horizontalScrub(width: width, dragging: $dragging, onEditingChanged: onEditingChanged) { position in
                value = range.lowerBound + position * (range.upperBound - range.lowerBound)
            }
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityValue("\(Int(fraction * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            onEditingChanged(true)
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }
}

extension View {
    /// Tap or drag sideways to set a 0...1 position. Vertical drags are left to an enclosing
    /// scroll view, which a SwiftUI DragGesture would swallow.
    func horizontalScrub(width: CGFloat, dragging: Binding<Bool>, onEditingChanged: @escaping (Bool) -> Void,
                         onChange: @escaping (Double) -> Void) -> some View {
        let position = { (x: CGFloat) in Double(min(max(x / max(width, 1), 0), 1)) }
        return self
            .onTapGesture(coordinateSpace: .local) { location in
                onEditingChanged(true)
                onChange(position(location.x))
                onEditingChanged(false)
            }
            .gesture(HorizontalPan { phase, x in
                switch phase {
                case .changed:
                    if !dragging.wrappedValue { dragging.wrappedValue = true; onEditingChanged(true) }
                    onChange(position(x))
                case .ended:
                    if dragging.wrappedValue { dragging.wrappedValue = false; onEditingChanged(false) }
                }
            })
    }
}

/// Pan recognizer that only begins when the movement is mostly horizontal.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    enum Phase { case changed, ended }
    var action: (Phase, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: action(.changed, context.converter.localLocation.x)
        case .ended, .cancelled, .failed: action(.ended, context.converter.localLocation.x)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
