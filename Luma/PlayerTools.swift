import SwiftUI
import AVFoundation

struct QueueView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Now playing") {
                    TrackRow(track: player.current) { player.toggle() }
                }
                Section {
                    if player.queue.isEmpty { Text("Your queue is clear. Add a song with Play next or Play later.").font(.subheadline).foregroundStyle(Theme.secondary) }
                    ForEach(player.queue) { entry in
                        if let track = player.track(entry.trackID) { TrackRow(track: track) { player.playQueued(entry) } }
                    }
                    .onMove { player.moveQueue(from: $0, to: $1) }
                    .onDelete { player.removeQueue(at: $0) }
                } header: {
                    HStack { Text("Up next · \(player.queue.count)"); Spacer(); if !player.queue.isEmpty { Button("Clear") { player.clearQueue() }.textCase(nil) } }
                } footer: {
                    Text("From \(player.contextName). \(player.shuffle ? "Shuffle is on. " : "")\(player.repeatMode.label). Edit to reorder your queue.")
                }
            }
            .scrollContentBackground(.hidden).background { AppBackground() }
            .navigationTitle("Play queue").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .modifier(PlayerFeedback())
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

struct PlayerSettingsView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var clearHistory = false
    var body: some View {
        @Bindable var player = player
        NavigationStack {
            Form {
                Section("Playback") {
                    Toggle("Gapless playback", isOn: $player.gapless).tint(Theme.accent)
                    Picker("ReplayGain", selection: $player.replayGain) {
                        ForEach(ReplayGainMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if player.replayGain != .off {
                        Text("Uses embedded ReplayGain tags and shared headroom to balance tagged songs without clipping. Untagged files keep their original gain. Audio files are never changed.")
                            .font(.footnote).foregroundStyle(Theme.secondary)
                    }
                    Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { player.setShuffle($0) })).tint(Theme.accent)
                    Picker("Repeat", selection: $player.repeatMode) { ForEach(RepeatMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                    Picker("Playback speed", selection: $player.playbackRate) {
                        ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in Text("\(value.formatted())×").tag(value) }
                    }.accessibilityIdentifier("settings.speed")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Track volume").font(.body)
                        Slider(value: $player.volume, in: 0...1).accessibilityLabel("Track volume")
                    }
                }
                Section {
                    if let deadline = player.sleepDeadline {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            LabeledContent("Stopping in", value: formattedTime(deadline.timeIntervalSince(context.date))).monospacedDigit()
                        }
                    } else if player.sleepAtEndOfTrack { Label("Stopping after this track", systemImage: "moon.zzz") }
                    ForEach([15, 30, 45, 60], id: \.self) { minutes in
                        Button { player.setSleepTimer(minutes: minutes) } label: { HStack { Text("\(minutes) minutes"); Spacer(); Image(systemName: "moon") } }.accessibilityIdentifier("sleep.\(minutes)")
                    }
                    Button("End of current track") { player.setSleepTimer(endOfTrack: true) }.accessibilityIdentifier("sleep.endOfTrack")
                    if player.sleepDeadline != nil || player.sleepAtEndOfTrack { Button("Cancel sleep timer") { player.cancelSleepTimer() }.accessibilityIdentifier("sleep.cancel") }
                } header: { Text("Sleep timer") } footer: { Text("Playback pauses when the timer ends. Sleep timers reset when the app closes.") }
                Section("Your library") {
                    LabeledContent("Tracks", value: "\(player.tracks.count)")
                    LabeledContent("Playlists", value: "\(player.playlists.count)")
                    LabeledContent("Favorites", value: "\(player.favorites.count)")
                    Button(player.refreshingMetadata ? "Refreshing metadata…" : "Refresh FLAC metadata") {
                        Task { await player.refreshFLACMetadata(force: true) }
                    }.disabled(player.refreshingMetadata || player.importing)
                    Button("Clear listening history", role: .destructive) { clearHistory = true }.disabled(player.recentIDs.isEmpty)
                }
                LibraryBackupView()
                Section { Text("Luma\n\nYour audio, playlists, and lyrics are stored on this device.").font(.footnote).foregroundStyle(Theme.secondary) }
            }
            .scrollContentBackground(.hidden).background { AppBackground() }
            .navigationTitle("Player settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear listening history?", isPresented: $clearHistory, titleVisibility: .visible) { Button("Clear history", role: .destructive) { player.clearHistory() } }
        }
    }
}

struct TrackInfoView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var audioDetails = ""
    @State private var fileSize = ""
    var body: some View {
        let track = player.track(track.id) ?? track
        NavigationStack {
            Form {
                Section {
                    TrackArtwork(track: track, showType: true).frame(width: 180, height: 180).clipShape(.rect(cornerRadius: 20)).frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                Section("Track") {
                    LabeledContent("Title", value: track.title)
                    LabeledContent("Artist", value: track.artist)
                    LabeledContent("Album", value: track.album)
                    if let albumArtist = track.albumArtist { LabeledContent("Album artist", value: albumArtist) }
                    LabeledContent("Genre", value: track.genre ?? "Unknown")
                    LabeledContent("Year", value: track.year ?? "Unknown")
                    if let disc = track.discNumber { LabeledContent("Disc", value: "\(disc)") }
                    if let number = track.trackNumber { LabeledContent("Track number", value: "\(number)") }
                    LabeledContent("Duration", value: track.length.map(formattedTime) ?? "Unknown")
                    LabeledContent("Lyrics", value: player.lyrics[track.id] == nil ? "Not added" : (LyricsDocument(player.lyrics[track.id]!).isSynchronized ? "Synchronized" : "Plain text"))
                }
                Section("Audio file") {
                    LabeledContent("Format", value: player.url(for: track)?.pathExtension.uppercased() ?? "Unknown")
                    if !audioDetails.isEmpty { LabeledContent("Audio", value: audioDetails) }
                    if let bits = track.bitDepth { LabeledContent("Source bit depth", value: "\(bits)-bit") }
                    if let rate = track.sampleRate { LabeledContent("Source sample rate", value: "\(rate.formatted()) Hz") }
                    if !fileSize.isEmpty { LabeledContent("Size", value: fileSize) }
                    LabeledContent("Source", value: "Your files")
                    if let url = player.url(for: track) { ShareLink(item: url) { Label("Share audio file", systemImage: "square.and.arrow.up") } }
                }
                if player.current.id == track.id {
                    Section("Audio output") {
                        LabeledContent("Device", value: player.outputName)
                        LabeledContent("Actual sample rate", value: player.outputSampleRate > 0 ? "\(player.outputSampleRate.formatted()) Hz" : "Not active")
                        if let rate = track.sampleRate, player.outputSampleRate > 0, rate != player.outputSampleRate {
                            Text("The output uses a different sample rate from this file.").font(.footnote).foregroundStyle(Theme.secondary)
                        }
                        if player.bluetoothOutput {
                            Text("Bluetooth may encode audio with a lossy codec. Use a compatible wired output for lossless listening.").font(.footnote).foregroundStyle(Theme.secondary)
                        }
                        LabeledContent("ReplayGain", value: player.replayGain.rawValue)
                    }
                }
            }.scrollContentBackground(.hidden).background { AppBackground() }
            .navigationTitle("Track details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task {
                    player.updateOutputRoute()
                    guard let url = player.url(for: track) else { return }
                    if let file = try? AVAudioFile(forReading: url) { audioDetails = "\(Int(file.fileFormat.sampleRate)) Hz · \(file.fileFormat.channelCount) channels" }
                    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { fileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
                }
        }
    }
}
