import SwiftUI
import Charts

struct AnalyticsView: View {
    @Environment(MusicPlayer.self) private var player
    @State private var period: AnalyticsPeriod = .week
    @State private var ranking: Ranking = .tracks
    @State private var leastPlayed = false
    @State private var showInfo = false
    @State private var confirmReset = false
    @State private var chartMetric: ChartMetric = .time
    @State private var selectedDate: Date?
    @Binding var showPlayer: Bool
    private enum Ranking: String, CaseIterable { case tracks = "Tracks", artists = "Artists", albums = "Albums" }
    private enum ChartMetric: String, CaseIterable { case time = "Time", plays = "Plays" }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let summary = player.analytics.summary(period: period, library: player.tracks, now: context.date)
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        Picker("Time period", selection: $period) { ForEach(AnalyticsPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("insights.period")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            statCard("Plays", value: "\(summary.totalPlays)", symbol: "play.circle", identifier: "insights.plays")
                            statCard("Listening time", value: listeningTime(summary.listeningSeconds), symbol: "headphones", identifier: "insights.time")
                            statCard("Different tracks", value: "\(summary.uniqueTracks)", symbol: "music.note", identifier: "insights.tracks")
                            statCard("Finished plays", value: "\(summary.completedPlays)", symbol: "checkmark.circle", identifier: "insights.finished")
                        }
                        activityChart(summary)
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text("In your rotation").font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                                Spacer()
                                Text("\(summary.activeDays) active days").font(.caption).foregroundStyle(Theme.secondary)
                            }
                            Picker("Rankings", selection: $ranking) { ForEach(Ranking.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                            if ranking == .tracks {
                                HStack(spacing: 18) {
                                    Button("Most played") { leastPlayed = false }.foregroundStyle(leastPlayed ? Theme.secondary : .white)
                                    Button("Least played") { leastPlayed = true }.foregroundStyle(leastPlayed ? .white : Theme.secondary).accessibilityIdentifier("insights.leastPlayed")
                                }.font(.subheadline.weight(.medium)).buttonStyle(.plain)
                            } else {
                                Text(ranking == .artists ? "TOP ARTISTS" : "TOP ALBUMS").font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(Theme.secondary)
                            }
                            let items = ranking == .artists ? summary.artists : (ranking == .albums ? summary.albums : (leastPlayed ? summary.leastPlayed : summary.mostPlayed))
                            if items.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "waveform.path").font(.system(size: 30, weight: .light))
                                    Text("Your story starts with a song.").font(.system(size: 23, design: .serif))
                                    Text("A play counts after 30 seconds, or half of a shorter track. Listen a little longer to see your favorites take shape.")
                                        .font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                                }.frame(maxWidth: .infinity).padding(.vertical, 22)
                            }
                            ForEach(Array(items.prefix(10).enumerated()), id: \.element.id) { index, item in
                                rankingRow(item, index: index)
                            }
                        }
                        Text("Your listening history stays on this device. Rankings start when playback tracking is enabled; earlier listens are not estimated.")
                            .font(.footnote).foregroundStyle(Theme.secondary).padding(.bottom, 12)
                    }.padding(24).frame(maxWidth: 650).frame(maxWidth: .infinity)
                }.background { AppBackground() }
            }
            .navigationTitle("Playback Insights").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("How plays are counted", systemImage: "info.circle") { showInfo = true }
                        Button("Reset playback insights", systemImage: "trash", role: .destructive) { confirmReset = true }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Insights options")
                }
            }
            .sheet(isPresented: $showInfo) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Every listen,\ncounted carefully.").font(.system(size: 32, design: .serif))
                            Text("A play is counted once per listening session after 30 seconds of audio, or half the duration of a shorter song. Pausing and resuming keeps the same session. Seeking does not add listening time.")
                            Text("Listening time measures actual playback time and includes partial listens. At 2× speed, 60 seconds of audio contributes 30 seconds of listening time. Finished plays are counted when a qualified session reaches the natural end.")
                            Text("Most played, top artists, and top albums use qualified plays. Least played includes tracks in your current library that have never qualified as a play. Historical totals remain when an imported song is removed.")
                            Text("The 7-day and 30-day ranges include today. All-time totals cover recorded history; the all-time activity chart shows the last 30 days. Resetting insights clears analytics only.")
                        }.font(.subheadline).padding(24)
                    }.navigationTitle("About Insights").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showInfo = false } } }
                }
            }
            .confirmationDialog("Reset playback insights?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset insights", role: .destructive) { player.resetAnalytics() }
            } message: { Text("This clears play counts and listening time. Your music, favorites, playlists, and recent track list stay intact.") }
        }
    }

    private func statCard(_ title: String, value: String, symbol: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(Theme.accent)
            Text(value).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityIdentifier(identifier)
            Text(title).font(.caption).foregroundStyle(Theme.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(.white.opacity(0.045), in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.07)))
    }

    private func activityChart(_ summary: AnalyticsSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Daily activity").font(.headline)
                    Text(period == .week ? "LAST 7 DAYS" : "LAST 30 DAYS").font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Picker("Chart metric", selection: $chartMetric) { ForEach(ChartMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 125)
            }
            if let selectedDate, let day = summary.activity.first(where: { Calendar.current.isDate($0.day, inSameDayAs: selectedDate) }) {
                Text("\(day.day.formatted(date: .abbreviated, time: .omitted)) · \(day.plays) plays · \(listeningTime(day.seconds))")
                    .font(.caption).foregroundStyle(Theme.accent)
            }
            Chart(summary.activity) { day in
                BarMark(x: .value("Day", day.day, unit: .day), y: .value(chartMetric == .time ? "Minutes" : "Plays", chartMetric == .time ? day.seconds / 60 : Double(day.plays)))
                    .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.4)], startPoint: .top, endPoint: .bottom))
                    .cornerRadius(4)
                    .accessibilityLabel(day.day.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue("\(day.plays) plays, \(listeningTime(day.seconds))")
            }
            .chartXSelection(value: $selectedDate)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .chartYScale(domain: 0...max(1, summary.activity.map { chartMetric == .time ? $0.seconds / 60 : Double($0.plays) }.max() ?? 1))
            .frame(height: 165)
            Text(chartMetric == .time ? "Minutes listened · touch the chart to explore" : "Qualified plays · touch the chart to explore").font(.caption2).foregroundStyle(Theme.secondary)
        }.padding(18).background(.white.opacity(0.035), in: .rect(cornerRadius: 20))
    }

    private func rankingRow(_ item: RankedListening, index: Int) -> some View {
        let available = availableTracks(for: item)
        return Button {
            if ranking == .tracks, let track = available.first { player.select(track); showPlayer = true }
            else { player.playCollection(available, named: item.title); showPlayer = true }
        } label: {
            HStack(spacing: 12) {
                Text(String(format: "%02d", index + 1)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary).frame(width: 23)
                if let track = player.track(item.trackID) ?? available.first {
                    TrackArtwork(track: track).frame(width: 45, height: 45).clipShape(.rect(cornerRadius: ranking == .artists ? 23 : 9))
                } else {
                    Image(systemName: ranking == .artists ? "person.fill" : "music.note").frame(width: 45, height: 45).background(.white.opacity(0.06), in: .rect(cornerRadius: 9))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(item.subtitle).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(item.plays == 0 ? "Unplayed" : "\(item.plays) \(item.plays == 1 ? "play" : "plays")").font(.caption.weight(.medium))
                    if item.seconds > 0 { Text(listeningTime(item.seconds)).font(.caption2).foregroundStyle(Theme.secondary) }
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(available.isEmpty)
    }

    private func availableTracks(for item: RankedListening) -> [Track] {
        switch ranking {
        case .tracks: player.track(item.trackID).map { [$0] } ?? []
        case .artists: player.tracks.filter { $0.artist == item.title }
        case .albums: player.tracks.filter { $0.album == item.title && $0.artist == item.subtitle }
        }
    }
}
