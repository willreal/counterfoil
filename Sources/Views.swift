import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private let counterfoilRed = Color(nsColor: .systemRed)
private let counterfoilDarkRed = Color(red: 0.53, green: 0.035, blue: 0.065)

/// Permanent sidebar footer treatment. Preserve the progressive material fade
/// when changing the sidebar button or scroll layout.
private struct ProgressiveSidebarFooterBackground: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.28), location: 0.22),
                            .init(color: .black.opacity(0.72), location: 0.52),
                            .init(color: .black, location: 0.82),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            Rectangle()
                .fill(.bar)
                .frame(height: 48)
                .mask {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.82), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

func formatDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration))
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}

func formatRecordingClock(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration))
    if totalSeconds >= 3600 {
        return String(format: "%d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
    }
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
}

func formatTimestamp(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration))
    return String(format: "%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
}

func formatTranscriptTimestamp(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration))
    if totalSeconds >= 3600 {
        return formatTimestamp(duration)
    }
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}

final class TranscriptPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var rate: Float = 1.0
    @Published var hasAudio = false
    @Published var activeOffset: TimeInterval?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(url: URL) {
        stop()

        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        hasAudio = true
        duration = 0
        if let asset = newPlayer.currentItem?.asset {
            Task { @MainActor [weak self] in
                guard let loaded = try? await asset.load(.duration),
                      loaded.isNumeric,
                      let self,
                      self.player === newPlayer else { return }
                self.duration = max(0, loaded.seconds)
            }
        }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = max(0, CMTimeGetSeconds(time))
            self.currentTime = seconds.isFinite ? seconds : 0
            if self.isPlaying {
                self.activeOffset = self.currentTime
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isPlaying = false
            self.currentTime = self.duration
            self.activeOffset = self.currentTime
        }
    }

    func play(from time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(time, max(duration, time)))
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        player.rate = rate
        currentTime = clamped
        activeOffset = clamped
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        guard let player else { return }
        player.rate = rate
        isPlaying = true
    }

    func toggle() {
        guard hasAudio else { return }
        isPlaying ? pause() : resume()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let upperBound = max(duration, 0.1)
        let clamped = max(0, min(time, upperBound))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        activeOffset = clamped
    }

    func skip(by seconds: TimeInterval) {
        guard let player else { return }
        let target = max(0, currentTime + seconds)
        let upperBound = duration > 0 ? duration : max(target, 0.1)
        let clamped = min(target, upperBound)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        activeOffset = clamped
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    func stop() {
        let oldPlayer = player
        oldPlayer?.pause()
        if let observer = timeObserver, let oldPlayer {
            oldPlayer.removeTimeObserver(observer)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        self.endObserver = nil
        player = nil
        isPlaying = false
        hasAudio = false
        currentTime = 0
        duration = 0
        activeOffset = nil
    }

    deinit {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }
}

private struct PlayerObservedContent<Content: View>: View {
    @ObservedObject var player: TranscriptPlayer
    private let content: () -> Content

    init(
        player: TranscriptPlayer,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.player = player
        self.content = content
    }

    var body: some View {
        content()
    }
}

struct ContentView: View {
    private static let sidebarDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private static let sidebarTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    @ObservedObject var store: TranscriptStore
    @ObservedObject var capture: CaptureManager

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    @State private var player = TranscriptPlayer()
    @State private var showingDeleteAudioConfirm = false
    @State private var showingDeleteEverythingConfirm = false
    @State private var sessionToDelete: Session?
    @State private var searchIsPresented = false

    private var selectedMeeting: Session? {
        guard let id = store.selectedSession else { return nil }
        return store.sessions.first(where: { $0.id == id })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(250)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(
            text: $store.searchQuery,
            isPresented: $searchIsPresented,
            placement: .toolbar,
            prompt: "Titles, Speech, Notes, Flags"
        )
        .toolbar { mainToolbarContent }
        .alert("Low Disk Space", isPresented: $capture.showLowDiskAlert) {
            Button("Cancel", role: .cancel) { capture.cancelLowDiskStart() }
            Button("Continue") { capture.confirmLowDiskStart() }
        } message: {
            Text("Less than 2 GB of free disk space available. Recording may fail if space runs out.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CounterfoilFind"))) { _ in
            searchIsPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CounterfoilOpenSettings"))) { _ in
            openWindow(id: SettingsView.windowID)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CounterfoilShowOnboarding"))) { _ in
            hasSeenOnboarding = false
            openWindow(id: OnboardingView.windowID)
        }
        .onChange(of: capture.phase) { _, phase in
            if phase.presentsRecordingPanel {
                openWindow(id: RecordingWindowView.windowID)
            } else {
                dismissWindow(id: RecordingWindowView.windowID)
            }
        }
        .onChange(of: store.selectedSession) { _, id in
            selectSession(id)
        }
        .onAppear {
            if capture.phase.presentsRecordingPanel {
                openWindow(id: RecordingWindowView.windowID)
            }
            if !hasSeenOnboarding {
                DispatchQueue.main.async {
                    openWindow(id: OnboardingView.windowID)
                }
            }
        }
        .alert("Delete Audio?", isPresented: $showingDeleteAudioConfirm, presenting: sessionToDelete) { session in
            Button("Cancel", role: .cancel) {}
            Button("Delete Audio", role: .destructive) { store.deleteAudioFiles(session) }
        } message: { _ in
            Text("The audio files (.m4a) will be moved to Trash. The transcript will be kept.")
        }
        .alert("Delete Everything?", isPresented: $showingDeleteEverythingConfirm, presenting: sessionToDelete) { session in
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) { store.deleteEverything(session) }
        } message: { _ in
            Text("The audio files and transcript will be moved to Trash.")
        }
    }

    @ToolbarContentBuilder
    private var mainToolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if selectedMeeting != nil {
                meetingToolbarActions
            }
        }
    }

    @ViewBuilder
    private var meetingToolbarActions: some View {
        ControlGroup {
            Button {
                guard let session = selectedMeeting else { return }
                copyTranscript(session: session)
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 36, height: 30)
            }
            .disabled(selectedMeeting?.hasTranscript != true)
            .help("Copy Transcript")
            .accessibilityLabel("Copy Transcript")

            Button {
                guard let session = selectedMeeting else { return }
                revealInFinder(session: session)
            } label: {
                Image(systemName: "folder")
                    .frame(width: 36, height: 30)
            }
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal in Finder")

            Menu {
                Button {
                    guard let session = selectedMeeting else { return }
                    sessionToDelete = session
                    showingDeleteAudioConfirm = true
                } label: {
                    Label("Delete Audio", systemImage: "trash")
                }
                Button(role: .destructive) {
                    guard let session = selectedMeeting else { return }
                    sessionToDelete = session
                    showingDeleteEverythingConfirm = true
                } label: {
                    Label("Delete Everything", systemImage: "trash.fill")
                }
            } label: {
                Image(systemName: "trash")
                    .frame(width: 46, height: 30)
            }
            .help("Delete")
            .accessibilityLabel("Delete")
        }
        .controlSize(.large)
        .controlGroupStyle(.navigation)
    }

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if capture.phase.presentsRecordingPanel {
                    liveRecordingRow
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }

                if !store.orphanSessions.isEmpty && store.searchQuery.isEmpty {
                    Section {
                        ForEach(store.orphanSessions) { orphan in
                            orphanRow(orphan)
                        }
                    } header: {
                        sidebarSectionHeader("Recoverable", color: .orange)
                    }
                }

                if store.displayedSessions.isEmpty {
                    if store.searchQuery.isEmpty && store.sessions.isEmpty && !capture.phase.presentsRecordingPanel {
                        emptySidebar
                    } else if !store.searchQuery.isEmpty {
                        noSearchResults
                    }
                } else {
                    ForEach(groupedDays(), id: \.0) { group in
                        Section {
                            ForEach(group.1) { session in
                                sessionRow(session)
                            }
                        } header: {
                            sidebarSectionHeader(group.0)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
    }

    private func sidebarSectionHeader(_ title: String, color: Color = .secondary) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }

    private var sidebarFooter: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                capture.start()
                openWindow(id: RecordingWindowView.windowID)
            } label: {
                Label("Record Meeting", systemImage: "record.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 42)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(counterfoilRed)
            .glassEffectTransition(.identity)
            .help("Start a recording")
            .disabled(!RecordingTransition.allows(.start, from: capture.phase))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 22)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background { ProgressiveSidebarFooterBackground() }
    }

    private var liveRecordingRow: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.activeTitle.isEmpty ? "Untitled meeting" : capture.activeTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Label(capture.phase.statusText, systemImage: "record.circle.fill")
                    Text(formatRecordingClock(capture.recordingDuration))
                        .monospacedDigit()
                    if capture.flagCount > 0 { Text("\(capture.flagCount) flags") }
                    if capture.noteCount > 0 { Text("\(capture.noteCount) notes") }
                }
                .font(.caption)
                .foregroundStyle(capture.phase.isPaused ? Color.orange : counterfoilRed)
            }
            Spacer(minLength: 0)
            if capture.phase == .preparing || capture.phase == .saving {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var emptySidebar: some View {
        ContentUnavailableView("No meetings yet", systemImage: "waveform")
            .frame(maxWidth: .infinity)
    }

    private var noSearchResults: some View {
        ContentUnavailableView.search(text: store.searchQuery)
        .frame(maxWidth: .infinity)
    }

    private func orphanRow(_ orphan: OrphanInfo) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recoverable recording")
                    .font(.body.weight(.semibold))
                Text(orphan.stem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button {
                    Task { await store.recoverOrphan(orphan) }
                } label: {
                    Label("Transcribe", systemImage: "text.word.spacing")
                }
                Button(role: .destructive) {
                    store.deleteOrphan(orphan)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        let selected = store.selectedSession == session.id
        let rowHeight: CGFloat = store.searchQuery.isEmpty ? 44 : 60

        return Button {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                store.selectedSession = session.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(formatRecordedDate(session.startTime))
                    Text("·")
                    Text(formatDuration(session.duration))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.84) : Color.secondary)

                if !store.searchQuery.isEmpty, let context = store.searchContext(for: session) {
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(selected ? Color.white.opacity(0.84) : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight, alignment: .leading)
            .padding(.horizontal, 8)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? counterfoilRed : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 1)
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button {
                copyTranscript(session: session)
            } label: {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }
            .disabled(!session.hasTranscript)

            Button {
                revealInFinder(session: session)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                sessionToDelete = session
                showingDeleteAudioConfirm = true
            } label: {
                Label("Delete Audio", systemImage: "trash")
            }
            Divider()
            Button(role: .destructive) {
                sessionToDelete = session
                showingDeleteEverythingConfirm = true
            } label: {
                Label("Delete Everything", systemImage: "trash.fill")
            }
        }
    }

    private func groupedDays() -> [(String, [Session])] {
        let calendar = Calendar.current
        var groups: [String: [Session]] = [:]

        for session in store.displayedSessions {
            let label: String
            if calendar.isDateInToday(session.startTime) {
                label = "Today"
            } else if calendar.isDateInYesterday(session.startTime) {
                label = "Yesterday"
            } else {
                label = Self.sidebarDayFormatter.string(from: session.startTime)
            }
            groups[label, default: []].append(session)
        }

        return groups
            .map { ($0.key, $0.value.sorted { $0.startTime > $1.startTime }) }
            .sorted { lhs, rhs in
                guard let left = lhs.1.first, let right = rhs.1.first else { return lhs.0 < rhs.0 }
                return left.startTime > right.startTime
            }
    }

    private var detailPane: some View {
        Group {
            if let id = store.selectedSession,
               let session = store.sessions.first(where: { $0.id == id }) {
                transcriptView(session: session)
            } else if store.sessions.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "waveform")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a meeting", systemImage: "text.alignleft")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func transcriptView(session: Session) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            readingColumn {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.title)
                        .font(.title.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        Label {
                            Text(session.startTime, format: .dateTime.month(.wide).day().year())
                        } icon: {
                            Image(systemName: "calendar")
                        }

                        Label {
                            Text(session.startTime, format: .dateTime.hour().minute())
                        } icon: {
                            Image(systemName: "clock")
                        }

                        if session.duration > 0 {
                            Text("·")
                            Text(formatDuration(session.duration))
                                .font(.callout.monospacedDigit())
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 26)
                .padding(.bottom, 18)
            }

            PlayerObservedContent(player: player) {
                if player.hasAudio {
                    readingColumn {
                        transportBar(session: session)
                            .padding(.bottom, 14)
                    }
                }
            }

            Divider()

            if session.processingState == .transcribing {
                processingSessionView(session)
            } else if session.processingState == .failed {
                failedSessionView(session)
            } else if store.transcriptContent[session.id] == nil {
                if session.hasTranscript {
                    ProgressView("Loading transcript…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyTranscribing
                }
            } else {
                transcriptBody(session: session)
            }

        }
    }

    private func processingSessionView(_ session: Session) -> some View {
        ContentUnavailableView {
            Label("Creating transcript", systemImage: "text.word.spacing")
        } description: {
            Text("Local transcription is running. The finalized audio is ready in Finder.")
        } actions: {
            ProgressView()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedSessionView(_ session: Session) -> some View {
        ContentUnavailableView {
            Label("Transcription failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(session.failureMessage ?? "The finalized audio is preserved.")
        } actions: {
            HStack(spacing: 8) {
                Button("Retry") {
                    store.retryTranscription(for: session)
                }
                .buttonStyle(.borderedProminent)

                Button("Change Model") {
                    UserDefaults.standard.set(true, forKey: "openModelsSettings")
                    openWindow(id: SettingsView.windowID)
                }

                Button("Reveal Audio") {
                    revealInFinder(session: session)
                }

                Button("Copy Diagnostics") {
                    copyDiagnostics(session: session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readingColumn<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
    }

    private func transportBar(session: Session) -> some View {
        let total = max(session.duration, max(player.duration, 0.1))
        return HStack(spacing: 12) {
            ControlGroup {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20, height: 20)
                }
                .help(player.isPlaying ? "Pause" : "Play")

                Button {
                    player.skip(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .frame(width: 20, height: 20)
                }
                .help("Rewind 10 seconds")

                Button {
                    player.skip(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .frame(width: 20, height: 20)
                }
                .help("Forward 10 seconds")
            }
            .controlSize(.large)

            Text(formatDuration(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: Binding(
                get: { min(player.currentTime, total) },
                set: { player.seek(to: $0) }
            ), in: 0...total)
            .tint(counterfoilRed)

            Text(formatDuration(total))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Picker("Playback speed", selection: Binding(
                get: { Double(player.rate) },
                set: { player.setRate(Float($0)) }
            )) {
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
                Text("1.5×").tag(1.5)
                Text("2×").tag(2.0)
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .controlSize(.regular)
        .frame(maxWidth: .infinity)
    }

    private func transcriptBody(session: Session) -> some View {
        AccessibleTranscriptBodyView(
            session: session,
            store: store,
            player: player,
            reduceMotion: reduceMotion
        )
        .id(session.id)
    }

    private var transcriptEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.badge.xmark")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("No transcript available")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var emptyTranscribing: some View {
        Group {
            if !Transcriber.shared.modelsAvailable {
                ContentUnavailableView {
                    Label("Models needed for transcription", systemImage: "square.stack.3d.up.trianglebadge.exclamationmark")
                } description: {
                    Text("Download a model in Settings → Models.")
                } actions: {
                    Button("Open Settings") { openWindow(id: SettingsView.windowID) }
                        .buttonStyle(.borderedProminent)
                        .tint(counterfoilRed)
                }
            } else {
                transcriptEmptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectSession(_ id: String?) {
        player.stop()
        guard let id, let session = store.sessions.first(where: { $0.id == id }) else { return }
        store.loadTranscript(for: session)
        DispatchQueue.main.async {
            guard store.selectedSession == session.id else { return }
            loadPlayer(for: session)
        }
    }

    private func loadPlayer(for session: Session) {
        let directory = URL(fileURLWithPath: session.dayDir, isDirectory: true)
        let m4a = directory.appendingPathComponent(session.systemAudioFilename ?? "\(session.stem).m4a")
        let mp4 = directory.appendingPathComponent("\(session.stem).mp4")
        if FileManager.default.fileExists(atPath: m4a.path) {
            player.load(url: m4a)
        } else if FileManager.default.fileExists(atPath: mp4.path) {
            player.load(url: mp4)
        }
    }

    private func copyTranscript(session: Session) {
        let content: String?
        if let loaded = store.transcriptContent[session.id] {
            content = loaded
        } else {
            let path = (session.dayDir as NSString).appendingPathComponent(session.transcriptFilename)
            content = try? String(contentsOfFile: path, encoding: .utf8)
        }
        guard let content else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    private func revealInFinder(session: Session) {
        let directory = URL(fileURLWithPath: session.dayDir, isDirectory: true)
        let names = [
            session.transcriptFilename,
            session.systemAudioFilename ?? "\(session.stem).m4a",
            "\(session.stem).mp4",
            session.microphoneAudioFilename ?? "\(session.stem).mic.m4a",
            session.metadataFilename ?? ""
        ]
        let urls = names
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func copyDiagnostics(session: Session) {
        let message = [
            "Counterfoil session: \(session.id)",
            "Title: \(session.title)",
            "Started: \(session.startTime.formatted(.iso8601))",
            "Duration: \(session.duration)",
            "State: \(session.processingState.rawValue)",
            "Model: \(SettingsStore.shared.selectedModel)",
            "System audio: \(session.systemAudioFilename ?? "Unavailable")",
            "Microphone audio: \(session.microphoneAudioFilename ?? "Unavailable")",
            "Failure: \(session.failureMessage ?? "Unavailable")"
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }

    private func formatRecordedDate(_ date: Date) -> String {
        Self.sidebarTimeFormatter.string(from: date)
    }

}

struct SettingsView: View {
    static let windowID = "settings"

    private enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case vocabulary = "Vocabulary"
        case models = "Models"
        case permissions = "Permissions"
        case about = "About"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .vocabulary: return "textformat.abc"
            case .models: return "waveform"
            case .permissions: return "checkmark.shield"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: Section = .general

    var body: some View {
        HStack(spacing: 0) {
            List {
                ForEach(Section.allCases) { section in
                    settingsSidebarRow(section)
                        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(counterfoilRed)
            .accentColor(counterfoilRed)
            .frame(width: 155)
            .background(.bar)

            Divider()

            Group {
                switch selection {
                case .general:
                    GeneralSettingsView()
                case .vocabulary:
                    VocabSettingsView()
                case .models:
                    ModelsSettingsView()
                case .permissions:
                    PermissionsSettingsView()
                case .about:
                    AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .tint(counterfoilRed)
        .frame(width: 510, height: 420)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CounterfoilOpenModelsSettings"))) { _ in
            selection = .models
        }
        .onAppear {
            if UserDefaults.standard.bool(forKey: "openModelsSettings") {
                selection = .models
                UserDefaults.standard.set(false, forKey: "openModelsSettings")
            }
        }
    }

    private func settingsSidebarRow(_ section: Section) -> some View {
        let selected = selection == section
        return Button {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selection = section
            }
        } label: {
            Label(section.rawValue, systemImage: section.symbol)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 30)
                .padding(.horizontal, 7)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? counterfoilRed : Color.clear)
                }
        }
        .buttonStyle(.plain)
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "")
    }

}

enum CounterfoilPermissionState: String {
    case granted = "Granted"
    case notGranted = "Not Granted"
    case unknown = "Unknown"

    var color: Color {
        switch self {
        case .granted: return .green
        case .notGranted: return .orange
        case .unknown: return .secondary
        }
    }
}

enum CounterfoilPermissions {
    static let microphoneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let screenRecordingURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    static func microphoneState() -> CounterfoilPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .notGranted
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    static func screenRecordingState() -> CounterfoilPermissionState {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        }
        return .unknown
    }

    static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct PermissionRowView: View {
    let name: String
    let systemImage: String
    let state: CounterfoilPermissionState
    let explanation: String
    let settingsURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(name, systemImage: systemImage)
                    .font(.body)
                Spacer(minLength: 6)
                Text(state.rawValue)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(state.color)
            }

            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open System Settings") {
                CounterfoilPermissions.open(settingsURL)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PermissionsSettingsView: View {
    @State private var microphoneState = CounterfoilPermissionState.unknown
    @State private var screenRecordingState = CounterfoilPermissionState.unknown

    var body: some View {
        Form {
            Section {
                PermissionRowView(
                    name: "Microphone",
                    systemImage: "mic.fill",
                    state: microphoneState,
                    explanation: "Counterfoil records your voice locally so transcripts can distinguish what you say.",
                    settingsURL: CounterfoilPermissions.microphoneURL
                )

                PermissionRowView(
                    name: "Screen Recording",
                    systemImage: "rectangle.inset.filled",
                    state: screenRecordingState,
                    explanation: "macOS requires screen recording permission to capture system audio, even though Counterfoil records audio only.",
                    settingsURL: CounterfoilPermissions.screenRecordingURL
                )
            } header: {
                Text("Access")
            } footer: {
                Text("Counterfoil asks only for the access needed to record both sides of a meeting.")
            }

            Section {
                HStack {
                    Text("Permission changes may require restarting Counterfoil.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check status") {
                        refresh()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func refresh() {
        microphoneState = CounterfoilPermissions.microphoneState()
        screenRecordingState = CounterfoilPermissions.screenRecordingState()
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Automatically delete audio after 30 days", isOn: $settings.autoDeleteEnabled)
            } header: {
                Text("Storage")
            } footer: {
                Text("Transcripts are always kept. Older audio is moved to Trash when this is enabled.")
            }

            Section {
                Label("Private by default", systemImage: "lock.shield")
                Text("100% local. Audio and transcripts stay on this Mac. No accounts, cloud service, or tracking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .textCase(nil)
        }
        .formStyle(.grouped)
    }
}

struct ModelsSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var selectedModel: String
    @State private var v2Downloading = false
    @State private var v3Downloading = false
    @State private var v2Progress: Double = 0
    @State private var v3Progress: Double = 0
    @State private var v2Error: String?
    @State private var v3Error: String?
    @State private var v2Completed = false
    @State private var v3Completed = false

    private let v3Name = "parakeet-tdt-0.6b-v3-coreml"

    init() {
        _selectedModel = State(initialValue: SettingsStore.shared.selectedModel)
    }

    private var installedModels: [String] {
        ["Parakeet V2", v3Name].filter { settings.hasModel(named: $0) }
    }

    var body: some View {
        Form {
            Section {
                if installedModels.isEmpty {
                    Label("Install a model below to enable transcription", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Picker("Default model", selection: $selectedModel) {
                        ForEach(installedModels, id: \.self) { model in
                            Text(model == v3Name ? "Parakeet V3" : "Parakeet V2")
                                .tag(model)
                        }
                    }
                    .onChange(of: selectedModel) { _, model in
                        settings.selectedModel = model
                    }
                }
            } header: {
                Text("Default model")
            } footer: {
                Text("The selected model is used for future transcriptions. Models are stored outside the app bundle.")
            }

            Section("Available models") {
                modelCard(
                    title: "Parakeet V2",
                    detail: "~450 MB · default model",
                    installed: v2Completed || settings.hasModel(named: "Parakeet V2"),
                    downloading: v2Downloading,
                    progress: v2Progress,
                    error: v2Error,
                    download: downloadV2
                )
                modelCard(
                    title: "Parakeet V3",
                    detail: "~461 MB · improved accuracy",
                    installed: v3Completed || settings.hasModel(named: v3Name),
                    downloading: v3Downloading,
                    progress: v3Progress,
                    error: v3Error,
                    download: downloadV3
                )
            }

            Section {
                Text("Models live in ~/Library/Application Support/Counterfoil/Models/.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { syncSelection() }
    }

    private func syncSelection() {
        guard !installedModels.contains(selectedModel), let first = installedModels.first else { return }
        selectedModel = first
        settings.selectedModel = first
    }

    private func modelCard(title: String, detail: String, installed: Bool, downloading: Bool, progress: Double, error: String?, download: @escaping () -> Void) -> some View {
        LabeledContent {
            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if downloading {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: progress)
                        .frame(width: 105)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Download") { download() }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func downloadV2() {
        v2Error = nil
        v2Downloading = true
        v2Progress = 0
        performDownload(urlString: Transcriber.modelDownloadURLv2, label: "parakeet-v2") { progress in
            DispatchQueue.main.async { v2Progress = progress }
        } completion: { result in
            DispatchQueue.main.async {
                v2Downloading = false
                switch result {
                case .success:
                    v2Completed = true
                    v2Progress = 1
                    settings.refreshAvailableModels()
                case .failure(let error):
                    v2Error = error.localizedDescription
                }
            }
        }
    }

    private func downloadV3() {
        v3Error = nil
        v3Downloading = true
        v3Progress = 0
        performDownload(urlString: Transcriber.modelDownloadURLv3, label: "parakeet-v3") { progress in
            DispatchQueue.main.async { v3Progress = progress }
        } completion: { result in
            DispatchQueue.main.async {
                v3Downloading = false
                switch result {
                case .success:
                    v3Completed = true
                    v3Progress = 1
                    settings.refreshAvailableModels()
                case .failure(let error):
                    v3Error = error.localizedDescription
                }
            }
        }
    }

    private func performDownload(urlString: String, label: String, progress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                guard let url = URL(string: urlString) else {
                    throw NSError(domain: "download", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
                }

                let archivePath = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString).tar.gz")
                let (downloadedURL, response) = try await withProgressDownload(url: url, progress: progress)

                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                    try? FileManager.default.removeItem(at: downloadedURL)
                    throw NSError(domain: "download", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download failed with HTTP error"])
                }

                try? FileManager.default.removeItem(at: archivePath)
                try FileManager.default.moveItem(at: downloadedURL, to: archivePath)
                defer { try? FileManager.default.removeItem(at: archivePath) }

                let modelsDirectory = Transcriber.modelsDir
                try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
                let extracted = try await extractTarGz(at: archivePath, to: modelsDirectory)
                guard let extracted else {
                    throw NSError(domain: "download", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to extract archive"])
                }

                for name in ["Preprocessor", "Encoder", "Decoder", "JointDecision"] {
                    guard FileManager.default.fileExists(atPath: extracted.appendingPathComponent("\(name).mlmodelc").path) else {
                        throw NSError(domain: "download", code: 4, userInfo: [NSLocalizedDescriptionKey: "Archive missing \(name).mlmodelc"])
                    }
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func withProgressDownload(url: URL, progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        progress(1)
        return (temporaryURL, response)
    }

    private func extractTarGz(at archivePath: URL, to destination: URL) async throws -> URL? {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archivePath.path, "-C", destination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let fileManager = FileManager.default
            let contents = try? fileManager.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
            let sorted = (contents ?? []).sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return left > right
            }
            for item in sorted {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory),
                   isDirectory.boolValue,
                   fileManager.fileExists(atPath: item.appendingPathComponent("Preprocessor.mlmodelc").path) {
                    return item
                }
            }
            return destination
        }.value
    }
}

struct VocabSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                if settings.vocabularyPairs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No replacement pairs", systemImage: "textformat.abc")
                            .foregroundStyle(.secondary)
                        Text("Add a pair to replace names and terms after transcription.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text("Find")
                            Color.clear.frame(width: 18, height: 1)
                            Text("Replace with")
                            Color.clear.frame(width: 26, height: 1)
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                        ForEach($settings.vocabularyPairs) { $pair in
                            GridRow {
                                TextField("", text: $pair.from, prompt: Text("Term"))
                                    .labelsHidden()
                                    .accessibilityLabel("Term to find")
                                    .frame(width: 100)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                TextField("", text: $pair.to, prompt: Text("Replacement"))
                                    .labelsHidden()
                                    .accessibilityLabel("Replacement")
                                    .frame(width: 100)
                                Button(role: .destructive) {
                                    remove(pair)
                                } label: {
                                    Label("Remove replacement", systemImage: "minus.circle")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .frame(width: 26, height: 26)
                                .help("Remove replacement")
                            }
                        }
                    }
                }
            } header: {
                Text("Replacement pairs")
            } footer: {
                Text("Pairs apply after local transcription, with word boundaries respected.")
            }

            Section {
                Button {
                    settings.vocabularyPairs.append(VocabularyPair(from: "", to: ""))
                } label: {
                    Label("Add Replacement", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func remove(_ pair: VocabularyPair) {
        if let index = settings.vocabularyPairs.firstIndex(where: { $0.id == pair.id }) {
            settings.vocabularyPairs.remove(at: index)
        }
    }
}

struct AboutSettingsView: View {
    private static let cachedIcon: Image = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return Image(systemName: "waveform.and.mic")
        }
        return Image(cgImage, scale: 1.0, orientation: .up, label: Text("Counterfoil"))
    }()

    var body: some View {
        Form {
            Section {
                LabeledContent("Application") {
                    HStack(spacing: 9) {
                        aboutIcon
                            .resizable()
                            .frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Counterfoil")
                                .font(.headline)
                            Text("Version \(bundleVersion()) (\(bundleBuild()))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("100% local. Audio and transcripts stay on this Mac. No accounts, cloud service, or tracking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Show onboarding again") {
                    UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
                    NotificationCenter.default.post(name: NSNotification.Name("CounterfoilShowOnboarding"), object: nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func bundleVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var aboutIcon: Image {
        Self.cachedIcon
    }

    private func bundleBuild() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

struct OnboardingView: View {
    static let windowID = "onboarding"

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var settings = SettingsStore.shared
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var page = 0
    @State private var microphoneState = CounterfoilPermissionState.unknown
    @State private var screenRecordingState = CounterfoilPermissionState.unknown
    @State private var retentionChoice: Bool?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0:
                    welcomePage
                case 1:
                    permissionsPage
                case 2:
                    retentionPage
                default:
                    readyPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Picker("Onboarding page", selection: $page) {
                Text("Welcome").tag(0)
                Text("Permissions").tag(1)
                Text("Storage").tag(2)
                Text("Ready").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 24)

            HStack {
                if settings.hasChosenAudioRetention {
                    Button("Skip") { skip() }
                        .buttonStyle(.borderless)
                }
                Spacer()

                if page > 0 {
                    Button("Back") { page -= 1 }
                        .buttonStyle(.bordered)
                }

                Button(page == 3 ? "Start using Counterfoil" : "Continue") {
                    if page == 3 {
                        finish()
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) { page += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(page == 2 && retentionChoice == nil)
            }
            .controlSize(.large)
            .padding()
        }
        .frame(width: 520, height: 460)
        .onAppear {
            refreshPermissions()
            if settings.hasChosenAudioRetention {
                retentionChoice = settings.autoDeleteEnabled
            }
        }
        .onExitCommand {
            if settings.hasChosenAudioRetention { skip() }
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(counterfoilRed)
                .padding(.top, 8)

            Text("Meetings, kept local.")
                .font(.title2.weight(.semibold))

            Text("Counterfoil records both sides of a meeting and transcribes them on this Mac. Your audio and transcripts stay private: no accounts, no cloud, no tracking.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 370)

            Label("100% local", systemImage: "lock.shield.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
    }

    private var permissionsPage: some View {
        Form {
            Section {
                PermissionRowView(
                    name: "Microphone",
                    systemImage: "mic.fill",
                    state: microphoneState,
                    explanation: "Captures your voice locally for the You channel.",
                    settingsURL: CounterfoilPermissions.microphoneURL
                )

                PermissionRowView(
                    name: "Screen Recording",
                    systemImage: "rectangle.inset.filled",
                    state: screenRecordingState,
                    explanation: "macOS requires screen recording permission to capture system audio, even though Counterfoil records audio only.",
                    settingsURL: CounterfoilPermissions.screenRecordingURL
                )
            } header: {
                Text("A couple of permissions")
            } footer: {
                Text("Counterfoil needs these to hear you and the meeting audio. macOS keeps the final decision in your hands.")
            }

            Section {
                HStack {
                    Text("Status: \(microphoneState.rawValue) · \(screenRecordingState.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check status") { refreshPermissions() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var readyPage: some View {
        VStack(spacing: 13) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 43, weight: .medium))
                .foregroundStyle(.green)
                .padding(.top, 7)

            Text("You're ready")
                .font(.title2.weight(.semibold))

            Text("Press Record Meeting to begin immediately. The floating panel opens in Preparing with an editable title while audio channels initialize.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 365)

            Button {
                finish()
            } label: {
                Label("Record Meeting", systemImage: "record.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.red)

            if settings.hasAnyModels {
                Label("A local transcription model is installed", systemImage: "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: 7) {
                    Text("Install a local model to enable transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Download models") {
                        openModelsSettings()
                    }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 136, minHeight: 30)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 30)
    }

    private func refreshPermissions() {
        microphoneState = CounterfoilPermissions.microphoneState()
        screenRecordingState = CounterfoilPermissions.screenRecordingState()
    }

    private var retentionPage: some View {
        Form {
            Section {
                Picker("Audio retention", selection: $retentionChoice) {
                    VStack(alignment: .leading) {
                        Text("Keep audio")
                        Text("Audio remains until you delete it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(false))

                    VStack(alignment: .leading) {
                        Text("Move audio to Trash after 30 days")
                        Text("Transcripts remain available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(true))
                }
                .pickerStyle(.radioGroup)
                .onChange(of: retentionChoice) { _, choice in
                    if let choice {
                        settings.chooseAudioRetention(autoDelete: choice)
                    }
                }
            } header: {
                Text("Choose how long audio stays")
            } footer: {
                Text("You can change this choice later in General Settings.")
            }
        }
        .formStyle(.grouped)
    }

    private func openModelsSettings() {
        UserDefaults.standard.set(true, forKey: "openModelsSettings")
        finish()
        DispatchQueue.main.async {
            openWindow(id: SettingsView.windowID)
        }
    }

    private func finish() {
        guard settings.hasChosenAudioRetention else {
            page = 2
            return
        }
        hasSeenOnboarding = true
        dismissWindow(id: Self.windowID)
    }

    private func skip() {
        finish()
    }
}
