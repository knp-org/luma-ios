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
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0

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
                                Button("Lyrics", systemImage: "quote.bubble") { panel = .lyrics }
                                Button("Sleep timer & playback", systemImage: "slider.horizontal.3") { panel = .settings }
                                Button("Track details", systemImage: "info.circle") { panel = .info }
                                if let url = player.url(for: player.current) { ShareLink(item: url) { Label("Share audio file", systemImage: "square.and.arrow.up") } }
                            } label: {
                                Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 46, height: 46)
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }.accessibilityLabel("Player options")
                        }
                        .padding(.top, 10)

                        PlayerArtworkView(isVisible: panel == nil)
                            .frame(width: min(geometry.size.width - 56, max(200, geometry.size.height * 0.39)))
                            .padding(.top, geometry.size.height < 750 ? 20 : 28)
                            .padding(.bottom, 24)

                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(player.current.title).font(.system(size: 30, weight: .semibold)).tracking(-1).lineLimit(2)
                                Text(player.current.artist).font(.system(size: 16)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
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
                            Slider(value: Binding(get: { scrubbing ? scrubPosition : player.elapsed }, set: { scrubPosition = $0 }), in: 0...max(player.duration, 1)) { editing in
                                if editing { scrubPosition = player.elapsed; scrubbing = true }
                                else { player.seek(to: scrubPosition); scrubbing = false }
                            }
                            .tint(Theme.accent)
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
                            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 27)).frame(width: 46, height: 60) }
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
                            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 27)).frame(width: 46, height: 60) }
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
                            Slider(value: Binding(get: { player.volume }, set: { player.volume = $0 }), in: 0...1)
                                .tint(.white.opacity(0.55))
                                .accessibilityLabel("Track volume")
                            #else
                            SystemVolumeSlider().frame(height: 32)
                            #endif
                            Image(systemName: "speaker.wave.3.fill").font(.system(size: 13))
                        }
                        .foregroundStyle(Theme.secondary).padding(.horizontal, 20).padding(.top, 22)

                        HStack {
                            Button { panel = .lyrics } label: { Image(systemName: "quote.bubble").font(.system(size: 20)).frame(width: 44, height: 44) }
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

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.tintColor = .lightGray
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
