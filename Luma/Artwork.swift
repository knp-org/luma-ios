import SwiftUI

struct TrackArtwork: View {
    @Environment(MusicPlayer.self) private var player
    let track: Track
    var showType = false
    @State private var asset: ArtworkAsset?
    @State private var loadedURL: ArtworkSource?
    private var artworkURL: ArtworkSource? { player.artworkSource(for: track) }

    var body: some View {
        GeometryReader { geometry in
            if loadedURL == artworkURL, let asset {
                Image(uiImage: asset.image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped().accessibilityHidden(true)
            } else { AlbumArtwork(style: track.style, showType: showType) }
        }
        .task(id: artworkURL) {
            asset = nil; loadedURL = nil
            guard let url = artworkURL else { return }
            let loaded = await ArtworkLoader.shared.load(url)
            guard !Task.isCancelled else { return }
            loadedURL = url; asset = loaded
        }
        .onDisappear { asset = nil; loadedURL = nil }
    }
}

struct PlaylistArtwork: View {
    @Environment(MusicPlayer.self) private var player
    let playlist: Playlist
    var body: some View {
        let tracks = player.tracks(in: playlist)
        GeometryReader { geometry in
            if tracks.count >= 4 {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(tracks.prefix(4)) { track in
                        TrackArtwork(track: track).frame(height: (geometry.size.width - 2) / 2)
                    }
                }
            } else if let track = tracks.first { TrackArtwork(track: track) }
            else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.28), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note.list").font(.system(size: geometry.size.width * 0.28, weight: .light)).foregroundStyle(Theme.accent)
                }
            }
        }.clipped().accessibilityHidden(true)
    }
}

/// Resolution-independent artwork, drawn locally without network requests.
struct AlbumArtwork: View {
    var style: Int = 0
    var showType = true

    private var palettes: [[Color]] {
        [
            [Color(white: 0.13), Color(white: 0.42), Color(white: 0.79)],
            [Color(white: 0.06), Color(white: 0.29), Color(white: 0.65)],
            [Color(white: 0.22), Color(white: 0.52), Color(white: 0.91)]
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            let colors = palettes[style % 3]
            ZStack {
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
                Canvas { context, size in
                    let sun = CGRect(x: size.width * 0.33, y: size.height * 0.20, width: size.width * 0.34, height: size.width * 0.34)
                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: size.width * 0.10))
                        glow.fill(Path(ellipseIn: sun.insetBy(dx: -15, dy: -15)), with: .color(colors[2].opacity(0.5)))
                    }
                    context.fill(Path(ellipseIn: sun), with: .linearGradient(Gradient(colors: [Color(white: 0.98), colors[2]]), startPoint: CGPoint(x: 0, y: sun.minY), endPoint: CGPoint(x: 0, y: sun.maxY)))
                    for layer in 0..<7 {
                        var dune = Path()
                        let base = size.height * (0.54 + Double(layer) * 0.065)
                        dune.move(to: CGPoint(x: 0, y: size.height))
                        dune.addLine(to: CGPoint(x: 0, y: base))
                        dune.addCurve(to: CGPoint(x: size.width, y: base + size.height * 0.08), control1: CGPoint(x: size.width * 0.35, y: base - size.height * (layer.isMultiple(of: 2) ? 0.23 : -0.15)), control2: CGPoint(x: size.width * 0.7, y: base + size.height * (layer.isMultiple(of: 2) ? 0.18 : -0.2)))
                        dune.addLine(to: CGPoint(x: size.width, y: size.height))
                        dune.closeSubpath()
                        context.fill(dune, with: .linearGradient(Gradient(colors: [colors[0].opacity(0.35 + Double(layer) * 0.075), Color.black.opacity(0.6)]), startPoint: CGPoint(x: 0, y: base), endPoint: CGPoint(x: size.width, y: size.height)))
                    }
                    // Fixed noise gives the artwork a quiet printed-paper texture.
                    var seed: UInt64 = 42
                    for _ in 0..<Int(size.width * size.height / 24) {
                        seed = seed &* 6364136223846793005 &+ 1
                        let x = Double(seed % 10000) / 10000 * size.width
                        seed = seed &* 6364136223846793005 &+ 1
                        let y = Double(seed % 10000) / 10000 * size.height
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.8, height: 0.8)), with: .color(.white.opacity(0.12)))
                    }
                    var orbit = Path(ellipseIn: CGRect(x: size.width * 0.13, y: size.height * 0.1, width: size.width * 0.74, height: size.height * 0.75))
                    orbit = orbit.applying(CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2).concatenating(CGAffineTransform(rotationAngle: -0.4)).concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2)))
                    context.stroke(orbit, with: .color(.white.opacity(0.24)), lineWidth: 0.65)
                }

            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

struct GlassIcon: View {
    let symbol: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

struct Equalizer: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    private var animating: Bool { active && isVisible && scenePhase == .active && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating)) { context in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<4) { index in
                    let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                    let phase = time * (3 + Double(index) * 0.35) + Double(index) * 1.8
                    let height = active ? 5 + 14 * (0.5 + 0.5 * sin(phase)) : 5
                    // Animate the drawing without relaying out the song row each frame.
                    Capsule().frame(width: 3, height: 19)
                        .scaleEffect(x: 1, y: height / 19, anchor: .bottom)
                }
            }
            .frame(width: 22, height: 22)
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityHidden(true)
    }
}
