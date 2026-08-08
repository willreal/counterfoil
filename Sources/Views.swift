import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

private let counterfoilRed = Color(red: 1.0, green: 0.231, blue: 0.188)
private let counterfoilCoral = Color(red: 0.86, green: 0.43, blue: 0.37)
private let counterfoilRecordingNoteAccent = Color.white.opacity(0.88)
// Notes carry a real accent color (not gray) so they stand out from
// flags in the transcript: warm blue, adapted for the transcript background.
private let counterfoilTranscriptNoteAccent = Color(red: 0.25, green: 0.55, blue: 0.92)

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

enum TranscriptSpeaker: String {
    case you = "You"
    case them = "Them"
}

struct TranscriptLineItem: Identifiable {
    let id = UUID()
    let text: String
    let timestamp: TimeInterval?
    let raw: String
    let speaker: TranscriptSpeaker?
    let isAnnotation: Bool
    let isFlag: Bool
    let isNote: Bool
    let isHeader: Bool
    let isMeta: Bool
    let isEmpty: Bool

    init(
        text: String,
        timestamp: TimeInterval?,
        raw: String,
        speaker: TranscriptSpeaker?,
        isAnnotation: Bool,
        isFlag: Bool,
        isHeader: Bool,
        isMeta: Bool,
        isEmpty: Bool,
        isNote: Bool = false,
        lineIndex: Int = 0
    ) {
        self.text = text
        self.timestamp = timestamp
        self.raw = raw
        self.speaker = speaker
        self.isAnnotation = isAnnotation
        self.isFlag = isFlag
        self.isNote = isNote
        self.isHeader = isHeader
        self.isMeta = isMeta
        self.isEmpty = isEmpty
        self.lineIndex = lineIndex
    }

    let lineIndex: Int
}

struct ContentView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var capture: CaptureManager

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    @StateObject private var player = TranscriptPlayer()
    @State private var showingDeleteAudioConfirm = false
    @State private var showingDeleteEverythingConfirm = false
    @State private var sessionToDelete: Session?
    @State private var titleText = ""
    @State private var collapsedDays: Set<String> = []
    @State private var editingNoteSessionID: String?
    @State private var editingNoteLineIndex: Int?
    @State private var noteEditText = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var noteEditFocused: Bool

    private var selectedMeeting: Session? {
        guard let id = store.selectedSession else { return nil }
        return store.sessions.first(where: { $0.id == id })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    sidebarFooter
                }
                .frame(minWidth: 250)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .tint(counterfoilRed)
        .sheet(isPresented: $capture.showTitlePrompt) {
            titleSheet
        }
        .alert("Low Disk Space", isPresented: $capture.showLowDiskAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") { capture.confirmLowDiskStart() }
        } message: {
            Text("Less than 2 GB of free disk space available. Recording may fail if space runs out.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CounterfoilFind"))) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CounterfoilShowOnboarding"))) { _ in
            hasSeenOnboarding = false
            openWindow(id: OnboardingView.windowID)
        }
        .onChange(of: capture.isRecording) { _, isRecording in
            if isRecording {
                openWindow(id: RecordingPanelView.windowID)
            } else {
                dismissWindow(id: RecordingPanelView.windowID)
            }
        }
        .onChange(of: store.selectedSession) { _, id in
            selectSession(id)
        }
        .onAppear {
            if capture.isRecording {
                openWindow(id: RecordingPanelView.windowID)
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { store.selectedSession },
                set: { store.selectedSession = $0 }
            )) {
                if capture.isRecording {
                    liveRecordingRow
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 7, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if !store.orphanSessions.isEmpty && store.searchQuery.isEmpty {
                    Section {
                        ForEach(store.orphanSessions) { orphan in
                            orphanRow(orphan)
                        }
                    } header: {
                        Text("Recoverable")
                            .foregroundStyle(.orange)
                    }
                }

                if store.displayedSessions.isEmpty {
                    if store.searchQuery.isEmpty && store.sessions.isEmpty && !capture.isRecording {
                        emptySidebar
                    } else if !store.searchQuery.isEmpty {
                        noSearchResults
                    }
                } else {
                    ForEach(groupedDays(), id: \.0) { group in
                        DisclosureGroup(isExpanded: dayBinding(for: group.0)) {
                            ForEach(group.1) { session in
                                sessionRow(session)
                            }
                        } label: {
                            Text(group.0)
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var toolbarSearch: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Titles, Transcripts", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !store.searchQuery.isEmpty {
                Button {
                    store.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 215, height: 28)
        // Single-layer field: plain fill + one stroke. No nested material
        // capsule (the toolbar glass strip is the outer surface already).
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .padding(.trailing, 10)
        .help("Search titles and transcripts")
    }

    private func toolbarButtonLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 27)
            .contentShape(RoundedRectangle(cornerRadius: 7))   // hit area = whole pill
            // Same single-layer treatment as the search field: no nested
            // material capsule inside the toolbar's glass strip.
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            }
    }

    private var toolbarDeleteLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "trash")
            Text("Delete")
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 12, weight: .medium))
        // Neutral, not red: red is reserved for Record Meeting (primary
        // action) and the destructive items inside the menu itself.
        // (QA: "red serves destructive, primary action, and status roles".)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(height: 27)
        .contentShape(RoundedRectangle(cornerRadius: 7))   // hit area = whole pill
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Button {
                titleText = ""
                capture.showTitlePrompt = true
            } label: {
                Label("Record Meeting", systemImage: "record.circle.fill")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Capsule())   // hit area = whole pill
            }
            .buttonStyle(.plain)
            // Solid red primary action (user: "make the record button solid red")
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .background {
                Capsule()
                    .fill(counterfoilRed)
            }
            .overlay {
                Capsule().stroke(counterfoilRed.opacity(0.9), lineWidth: 1)
            }
            .help("Start a recording")
            .disabled(capture.isRecording)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var liveRecordingRow: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.activeTitle.isEmpty ? "Meeting" : capture.activeTitle)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                Text("Recording now")
                    .font(.caption)
                    .foregroundStyle(counterfoilRed)
                MicWaveformView(samples: capture.micSamples, color: counterfoilRed.opacity(0.62))
                    .frame(height: 13)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(counterfoilRed)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
    }

    private var emptySidebar: some View {
        EmptyMeetingState()
            .frame(maxWidth: .infinity)
            .padding(.top, 120)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var noSearchResults: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19))
                .foregroundStyle(.tertiary)
            Text("No matches")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
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
        .padding(.vertical, 2)
    }

    private func sessionRow(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(formatDuration(session.duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(formatRecordedDate(session.startTime))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !store.searchQuery.isEmpty, let context = store.searchContext(for: session) {
                Text(context)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .tag(session.id)
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

            Button {
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

    private func dayBinding(for day: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedDays.contains(day) },
            set: { expanded in
                if expanded {
                    collapsedDays.remove(day)
                } else {
                    collapsedDays.insert(day)
                }
            }
        )
    }

    private func groupedDays() -> [(String, [Session])] {
        let calendar = Calendar.current
        var groups: [String: [Session]] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"

        for session in store.displayedSessions {
            let label: String
            if calendar.isDateInToday(session.startTime) {
                label = "Today"
            } else if calendar.isDateInYesterday(session.startTime) {
                label = "Yesterday"
            } else {
                label = formatter.string(from: session.startTime)
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

    private var titleSheet: some View {
        VStack(spacing: 17) {
            VStack(spacing: 5) {
                Text("Start a meeting")
                    .font(.title3.weight(.semibold))
                Text("Audio stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Meeting title", text: $titleText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { startWithTitle() }

            HStack(spacing: 12) {
                Button("Cancel") { capture.showTitlePrompt = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Start Recording") { startWithTitle() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .tint(counterfoilRed)
            }
        }
        .padding(26)
        .frame(width: 370)
    }

    private func startWithTitle() {
        var title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            title = "Meeting \(formatter.string(from: Date()))"
        }
        capture.showTitlePrompt = false
        capture.start(title: title)
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            // Custom top bar — NOT the native toolbar, which collapses
            // labeled buttons into icon-only squares (user: "liquid glass
            // buttons are containers for old styling buttons").
            HStack(spacing: 8) {
                Text("Counterfoil")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    guard let session = selectedMeeting else { return }
                    copyTranscript(session: session)
                } label: {
                    toolbarButtonLabel("Copy Transcript", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(selectedMeeting == nil || selectedMeeting?.hasTranscript != true)
                .help("Copy Transcript")

                Button {
                    guard let session = selectedMeeting else { return }
                    revealInFinder(session: session)
                } label: {
                    toolbarButtonLabel("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .disabled(selectedMeeting == nil)
                .help("Reveal in Finder")

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
                    toolbarDeleteLabel
                }
                .menuStyle(.borderlessButton)
                .disabled(selectedMeeting == nil)
                .help("Delete")

                toolbarSearch
            }
            .padding(.horizontal, 14)
            .frame(height: 52)

            Divider()

            Group {
                if let id = store.selectedSession,
                   let session = store.sessions.first(where: { $0.id == id }) {
                    transcriptView(session: session)
                } else if store.sessions.isEmpty {
                    EmptyMeetingState()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("Select a meeting")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func transcriptView(session: Session) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Meeting identity: title is the anchor, meta line below it.
            // (User + ChatGPT QA: main pane must show which meeting is open.)
            Text(session.title)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 31)
                .padding(.top, 14)

            HStack(spacing: 9) {
                Text(session.startTime, style: .date)
                Text("·")
                if session.duration > 0 {
                    Text(formatDuration(session.duration))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 31)
            .padding(.top, 3)
            .padding(.bottom, 4)

            if player.hasAudio {
                transportBar(session: session)
                    .padding(.horizontal, 31)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
            }

            Divider()

            if store.transcriptContent[session.id] == nil {
                if session.hasTranscript {
                    ProgressView("Loading transcript…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyTranscribing
                }
            } else {
                transcriptBody(session: session)
            }

            if capture.status.contains("Transcribing") {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(capture.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(9)
            }
        }
    }

    private func transportBar(session: Session) -> some View {
        let total = max(session.duration, max(player.duration, 0.1))
        return HStack(spacing: 11) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.9), in: Circle())
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Play")

            Text(formatDuration(player.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 43, alignment: .leading)

            Slider(value: Binding(
                get: { min(player.currentTime, total) },
                set: { player.seek(to: $0) }
            ), in: 0...total)
            .tint(counterfoilRed)

            Text(formatDuration(total))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 43, alignment: .trailing)

            Divider()
                .frame(height: 18)

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
            .frame(minWidth: 76)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.14))
        }
    }

    private func transcriptBody(session: Session) -> some View {
        let lines = parseTranscriptLines(store.transcriptContent[session.id] ?? "")
            .filter { !$0.isHeader && !$0.isMeta }
        let flags = lines.filter { $0.isFlag && $0.timestamp != nil }
        let latestTimestamp = lines.compactMap(\.timestamp).max() ?? 0
        let totalTime = max(session.duration, max(player.duration, max(latestTimestamp, 1)))
        let activeLineID = player.isPlaying ? findActiveLine(in: lines, time: player.currentTime)?.id : nil

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines) { line in
                        transcriptLine(line, session: session, activeLineID: activeLineID)
                    }
                }
                .padding(.horizontal, 31)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    FlagRail(flags: flags, totalTime: totalTime) { time in
                        player.play(from: time)
                    }
                    .frame(width: 20)
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
            .onChange(of: player.currentTime) { _, newTime in
                guard player.isPlaying,
                      let activeLine = findActiveLine(in: lines, time: newTime) else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(activeLine.id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptLine(
        _ line: TranscriptLineItem,
        session: Session,
        activeLineID: UUID?
    ) -> some View {
        if line.isEmpty {
            Spacer().frame(height: 7).id(line.id)
        } else if line.text == "No transcript available" {
            // Old-format placeholder: render as a quiet centered message,
            // not as an annotation line with a coral bar (QA: coral line
            // read as a stray caret; message looked disabled).
            Text("No transcript available")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
                .id(line.id)
        } else if line.isAnnotation {
            annotationLine(line, session: session)
            .id(line.id)
        } else {
            Button {
                if let timestamp = line.timestamp, player.hasAudio {
                    player.play(from: timestamp)
                }
            } label: {
                speakerLine(line, activeLineID: activeLineID)
            }
            .buttonStyle(.plain)
            .disabled(!player.hasAudio || line.timestamp == nil)
            .id(line.id)
        }
    }

    @ViewBuilder
    private func annotationLine(_ line: TranscriptLineItem, session: Session) -> some View {
        if line.isNote && editingNoteSessionID == session.id && editingNoteLineIndex == line.lineIndex {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Capsule()
                        .fill(counterfoilTranscriptNoteAccent)
                        .frame(width: 3)
                    Image(systemName: "note.text")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(counterfoilTranscriptNoteAccent)
                    Text("Note")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    if let timestamp = line.timestamp {
                        Text(formatTimestamp(timestamp))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                TextEditor(text: $noteEditText)
                    .font(.caption)
                    .scrollContentBackground(.hidden)
                    .focused($noteEditFocused)
                    .frame(minHeight: 42, maxHeight: 110)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") {
                        cancelNoteEditing()
                    }
                    .buttonStyle(.bordered)
                    Button("Save") {
                        saveNoteEditing(session: session, line: line)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(counterfoilRed)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(counterfoilTranscriptNoteAccent.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
            .padding(.vertical, 4)
        } else {
            HStack(alignment: .top, spacing: 9) {
                Capsule()
                    .fill(line.isFlag ? Color.secondary.opacity(0.62) : counterfoilTranscriptNoteAccent)
                    .frame(width: 3)

                Image(systemName: line.isFlag ? "flag.fill" : "note.text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(line.isFlag ? Color.secondary : counterfoilTranscriptNoteAccent)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(line.text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let timestamp = line.timestamp {
                        Text(formatTimestamp(timestamp))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                (line.isFlag ? Color.primary.opacity(0.045) : counterfoilTranscriptNoteAccent.opacity(0.11)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if line.isNote {
                    beginNoteEditing(session: session, line: line)
                }
            }
            .contextMenu {
                if line.isFlag {
                    Button(role: .destructive) {
                        store.removeFlag(from: session, at: line.lineIndex)
                    } label: {
                        Label("Remove Flag", systemImage: "flag.slash")
                    }
                } else if line.isNote {
                    Button {
                        beginNoteEditing(session: session, line: line)
                    } label: {
                        Label("Edit Note", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        store.removeNote(from: session, at: line.lineIndex)
                    } label: {
                        Label("Remove Note", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func speakerLine(_ line: TranscriptLineItem, activeLineID: UUID?) -> some View {
        let active = activeLineID == line.id
        let isThem = line.speaker == .them
        let ribbon = isThem ? counterfoilCoral.opacity(0.48) : counterfoilRed
        let searchHit = !store.searchQuery.isEmpty && line.raw.localizedCaseInsensitiveContains(store.searchQuery)

        return HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(ribbon)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text((line.speaker?.rawValue ?? "").uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isThem ? counterfoilCoral.opacity(0.85) : .secondary)
                    if let timestamp = line.timestamp {
                        Text(formatTimestamp(timestamp))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                Text(line.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 7)
        .padding(.trailing, 17)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(searchHit ? Color.yellow.opacity(0.13) : (isThem ? counterfoilCoral.opacity(0.045) : .clear))
        }
        .overlay(alignment: .leading) {
            if active {
                Capsule()
                    .fill(counterfoilRed)
                    .frame(width: 2)
                    .shadow(color: counterfoilRed.opacity(0.72), radius: 6)
                    .offset(x: -7)
            }
        }
        .contentShape(Rectangle())
    }

    private func findActiveLine(in lines: [TranscriptLineItem], time: TimeInterval) -> TranscriptLineItem? {
        var active: TranscriptLineItem?
        for line in lines where line.speaker != nil {
            guard let timestamp = line.timestamp, timestamp <= time + 0.05 else { continue }
            active = line
        }
        return active
    }

    private func beginNoteEditing(session: Session, line: TranscriptLineItem) {
        guard line.isNote else { return }
        editingNoteSessionID = session.id
        editingNoteLineIndex = line.lineIndex
        noteEditText = line.text
        DispatchQueue.main.async {
            noteEditFocused = true
        }
    }

    private func cancelNoteEditing() {
        noteEditFocused = false
        editingNoteSessionID = nil
        editingNoteLineIndex = nil
        noteEditText = ""
    }

    private func saveNoteEditing(session: Session, line: TranscriptLineItem) {
        store.updateNote(in: session, at: line.lineIndex, with: noteEditText)
        cancelNoteEditing()
    }

    private func parseTranscriptLines(_ markdown: String) -> [TranscriptLineItem] {
        var items: [TranscriptLineItem] = []
        let trimmedMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMarkdown = trimmedMarkdown.trimmingCharacters(in: CharacterSet(charactersIn: "_")) == "No transcript available"
            ? "No transcript available"
            : markdown

        for (lineIndex, raw) in normalizedMarkdown.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                items.append(TranscriptLineItem(text: "", timestamp: nil, raw: raw, speaker: nil, isAnnotation: false, isFlag: false, isHeader: false, isMeta: false, isEmpty: true, lineIndex: lineIndex))
                continue
            }
            // Old transcripts wrote "_No transcript available_" (markdown
            // emphasis). Normalize the line so it never renders raw underscores.
            if trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "_")) == "No transcript available" {
                items.append(TranscriptLineItem(text: "No transcript available", timestamp: nil, raw: "No transcript available", speaker: nil, isAnnotation: false, isFlag: false, isHeader: false, isMeta: false, isEmpty: false, lineIndex: lineIndex))
                continue
            }
            if trimmed.hasPrefix("# ") {
                items.append(TranscriptLineItem(text: trimmed, timestamp: nil, raw: raw, speaker: nil, isAnnotation: false, isFlag: false, isHeader: true, isMeta: false, isEmpty: false, lineIndex: lineIndex))
                continue
            }
            if trimmed.hasPrefix("*") && trimmed.hasSuffix("*") && !trimmed.hasPrefix("**[") {
                items.append(TranscriptLineItem(text: trimmed, timestamp: nil, raw: raw, speaker: nil, isAnnotation: false, isFlag: false, isHeader: false, isMeta: true, isEmpty: false, lineIndex: lineIndex))
                continue
            }

            guard let open = trimmed.firstIndex(of: "["),
                  let close = trimmed.firstIndex(of: "]"), close > open else {
                items.append(TranscriptLineItem(text: trimmed, timestamp: nil, raw: raw, speaker: nil, isAnnotation: false, isFlag: false, isHeader: false, isMeta: false, isEmpty: false, lineIndex: lineIndex))
                continue
            }

            let timestampText = String(trimmed[trimmed.index(after: open)..<close])
            let parts = timestampText.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 3 else {
                items.append(TranscriptLineItem(text: trimmed, timestamp: nil, raw: raw, speaker: nil, isAnnotation: false, isFlag: false, isHeader: false, isMeta: false, isEmpty: false, lineIndex: lineIndex))
                continue
            }
            let timestamp = TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])

            if let annotation = transcriptAnnotation(from: raw) {
                switch annotation.kind {
                case .flag:
                    items.append(TranscriptLineItem(text: "Flagged moment", timestamp: timestamp, raw: raw, speaker: nil, isAnnotation: true, isFlag: true, isHeader: false, isMeta: false, isEmpty: false, lineIndex: lineIndex))
                case .note:
                    items.append(TranscriptLineItem(text: annotation.text ?? "", timestamp: timestamp, raw: raw, speaker: nil, isAnnotation: true, isFlag: false, isHeader: false, isMeta: false, isEmpty: false, isNote: true, lineIndex: lineIndex))
                }
                continue
            }

            var payload = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if payload.hasPrefix("**") { payload.removeFirst(2) }
            if payload.hasSuffix("**") { payload.removeLast(2) }
            payload = payload.trimmingCharacters(in: .whitespaces)

            if payload.hasPrefix("You:**") {
                let text = String(payload.dropFirst("You:**".count)).trimmingCharacters(in: .whitespaces)
                items.append(TranscriptLineItem(text: text, timestamp: timestamp, raw: raw, speaker: .you, isAnnotation: false, isFlag: false, isHeader: false, isMeta: false, isEmpty: false, lineIndex: lineIndex))
            } else if payload.hasPrefix("Them:**") {
                let text = String(payload.dropFirst("Them:**".count)).trimmingCharacters(in: .whitespaces)
                items.append(TranscriptLineItem(text: text, timestamp: timestamp, raw: raw, speaker: .them, isAnnotation: false, isFlag: false, isHeader: false, isMeta: false, isEmpty: false, lineIndex: lineIndex))
            } else if payload.hasPrefix("You:") {
                let text = String(payload.dropFirst("You:".count)).trimmingCharacters(in: .whitespaces)
                items.append(TranscriptLineItem(text: text, timestamp: timestamp, raw: raw, speaker: .you, isAnnotation: false, isFlag: false, isHeader: false, isMeta: false, isEmpty: false, lineIndex: lineIndex))
            } else if payload.hasPrefix("Them:") {
                let text = String(payload.dropFirst("Them:".count)).trimmingCharacters(in: .whitespaces)
                items.append(TranscriptLineItem(text: text, timestamp: timestamp, raw: raw, speaker: .them, isAnnotation: false, isFlag: false, isHeader: false, isMeta: false, isEmpty: false, lineIndex: lineIndex))
            } else {
                items.append(TranscriptLineItem(text: payload, timestamp: timestamp, raw: raw, speaker: nil, isAnnotation: true, isFlag: false, isHeader: false, isMeta: false, isEmpty: false, lineIndex: lineIndex))
            }
        }
        return items
    }

    private var emptyTranscribing: some View {
        VStack(spacing: 14) {
            if !Transcriber.shared.modelsAvailable {
                Image(systemName: "square.stack.3d.up.trianglebadge.exclamationmark")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text("Models needed for transcription")
                    .font(.headline)
                Text("Download a model in Settings → Models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Settings") { showSettingsWindow() }
                    .buttonStyle(.borderedProminent)
                    .tint(counterfoilRed)
            } else {
                Image(systemName: "text.badge.xmark")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("No transcript yet")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectSession(_ id: String?) {
        player.stop()
        guard let id, let session = store.sessions.first(where: { $0.id == id }) else { return }
        store.loadTranscript(for: session)
        loadPlayer(for: session)
    }

    private func loadPlayer(for session: Session) {
        let directory = URL(fileURLWithPath: session.dayDir, isDirectory: true)
        let m4a = directory.appendingPathComponent("\(session.stem).m4a")
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
            let path = (session.dayDir as NSString).appendingPathComponent("\(session.stem).md")
            content = try? String(contentsOfFile: path, encoding: .utf8)
        }
        guard let content else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    private func revealInFinder(session: Session) {
        let directory = URL(fileURLWithPath: session.dayDir, isDirectory: true)
        let names = [
            "\(session.stem).md",
            "\(session.stem).m4a",
            "\(session.stem).mp4",
            "\(session.stem).mic.m4a"
        ]
        let urls = names
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func formatRecordedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"

        let hour = Calendar.current.component(.hour, from: date)
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let period = hour >= 12 ? "pm" : "am"
        return formatter.string(from: date) + " · ~" + String(displayHour) + period
    }

    private func showSettingsWindow() {
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

struct EmptyMeetingState: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.primary.opacity(0.045))
                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.65))
            }
            .frame(width: 78, height: 78)

            Text("No meetings yet")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct WaveformStrip: View {
    let peaks: [CGFloat]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let barWidth = max(1.0, (size.width - CGFloat(peaks.count - 1)) / CGFloat(peaks.count))
            for (index, peak) in peaks.enumerated() {
                let height = max(2, min(size.height, size.height * max(0.08, peak)))
                let x = CGFloat(index) * (barWidth + 1)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
            }
        }
    }
}

struct MicWaveformView: View {
    let samples: [CGFloat]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let values = samples.isEmpty ? [CGFloat(0)] : samples
            let step = size.width / CGFloat(max(values.count - 1, 1))
            let mid = size.height / 2
            for (index, sample) in values.enumerated() {
                let amplitude = max(1.4, min(size.height * 0.48, sample * size.height * 1.55))
                let x = CGFloat(index) * step
                let rect = CGRect(x: x, y: mid - amplitude, width: 1.5, height: amplitude * 2)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.75), with: .color(color))
            }
        }
    }
}

struct FlagRail: View {
    let flags: [TranscriptLineItem]
    let totalTime: TimeInterval
    let onSelect: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // Only draw the rail when there are flags to show; an empty
                // rail reads as a stray artifact (QA: "unclear vertical line").
                if !flags.isEmpty {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }

                ForEach(flags) { flag in
                    if let time = flag.timestamp {
                        Button {
                            onSelect(time)
                        } label: {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(counterfoilRed)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .position(x: geometry.size.width / 2, y: max(10, min(max(10, geometry.size.height - 10), geometry.size.height * CGFloat(time / max(totalTime, 1)))))
                        .help("Jump to \(formatTimestamp(time))")
                    }
                }
            }
        }
    }
}

struct RecordingPanelView: View {
    static let windowID = "recording-panel"

    @ObservedObject var capture: CaptureManager
    @ObservedObject var store: TranscriptStore
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var draftTitle = ""
    @State private var editingTitle = false
    @State private var noteDraft = ""
    @State private var noteExpanded = false
    @State private var flagPulse = false
    @FocusState private var titleFocused: Bool
    @FocusState private var noteFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            mainPanel

            if noteExpanded {
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 1)
                    .padding(.vertical, 18)

                noteTray
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.72))
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.12, green: 0.08, blue: 0.09).opacity(0.3))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 26, y: 12)
        .onAppear {
            if capture.isRecording {
                draftTitle = capture.activeTitle
            } else {
                dismissPanelWindow()
            }
        }
        .onChange(of: capture.activeTitle) { _, title in
            if !editingTitle { draftTitle = title }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused && editingTitle { commitTitle() }
        }
        .onChange(of: noteExpanded) { _, expanded in
            if expanded {
                DispatchQueue.main.async { noteFocused = true }
            } else {
                noteFocused = false
            }
            resizeWindow(expanded: expanded)
        }
        .onChange(of: capture.isRecording) { _, isRecording in
            if !isRecording {
                dismissPanelWindow()
            }
        }
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            titleHeader

            Text(formatRecordingClock(capture.recordingDuration))
                .font(.system(size: 42, weight: .medium, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(capture.isPaused ? Color.yellow.opacity(0.98) : counterfoilRed)
                .padding(.top, 22)

            MicWaveformView(
                samples: capture.micSamples,
                color: CaptureManager.hasMic ? counterfoilRed.opacity(0.92) : Color.white.opacity(0.42)
            )
            .frame(height: 38)
            .padding(.horizontal, 8)
            .padding(.top, 18)
            .padding(.bottom, 16)

            controlRow

            Button {
                capture.stop(store: store)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(counterfoilRed, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: counterfoilRed.opacity(0.32), radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .padding(.top, 16)
        }
        .padding(.horizontal, 17)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(width: 316)
    }

    private var titleHeader: some View {
        Group {
            if editingTitle {
                HStack(spacing: 5) {
                    TextField("Meeting title", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .focused($titleFocused)
                        .onSubmit { commitTitle() }
                    Button {
                        commitTitle()
                    } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.9))
                    .contentShape(Rectangle())
                }
            } else {
                Button {
                    draftTitle = capture.activeTitle
                    editingTitle = true
                    DispatchQueue.main.async { titleFocused = true }
                } label: {
                    HStack(spacing: 5) {
                        Text(capture.activeTitle.isEmpty ? "Meeting" : capture.activeTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                    .frame(maxWidth: 232, minHeight: 32)
                    .contentShape(Rectangle())   // hit area = whole title row
                }
                .buttonStyle(.plain)
                .help("Edit meeting title")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var controlRow: some View {
        HStack(spacing: 0) {
            panelControl(
                systemName: capture.isPaused ? "play.fill" : "pause.fill",
                tint: .yellow,
                help: capture.isPaused ? "Resume recording" : "Pause recording"
            ) {
                if capture.isPaused {
                    capture.resumeCapture()
                } else {
                    capture.pauseCapture()
                }
            }

            panelControl(
                systemName: "flag",
                tint: flagPulse ? counterfoilRed : Color.white.opacity(0.88),
                help: "Flag moment"
            ) {
                guard !capture.isPaused else { return }
                capture.flagCurrentMoment()
                withAnimation(.easeOut(duration: 0.12)) { flagPulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.easeIn(duration: 0.18)) { flagPulse = false }
                }
            }

            panelControl(
                systemName: noteExpanded ? "note.text" : "note.text.badge.plus",
                tint: counterfoilRecordingNoteAccent,
                help: "Add note"
            ) {
                noteExpanded.toggle()
                if !noteExpanded { noteDraft = "" }
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.18)) }
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.18)) }
    }

    private func panelControl(systemName: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())   // hit area = full cell, not just the glyph
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: 44)
        .help(help)
    }

    private var noteTray: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Notes")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer()
                Button {
                    noteExpanded = false
                    noteDraft = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())   // hit area = whole 32pt cell
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.75))
                .help("Close notes")
            }

            ZStack(alignment: .topLeading) {
                if noteDraft.isEmpty {
                    Text("Write a note…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $noteDraft)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.92))
                    .scrollContentBackground(.hidden)
                    .focused($noteFocused)
            }
            .frame(height: 142)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }

            Text("⌘↩ saves a timestamped note")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))

            Button {
                commitNote()
            } label: {
                Label("Save Note", systemImage: "arrow.up.circle.fill")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(RoundedRectangle(cornerRadius: 9))   // hit area = whole button
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(counterfoilRed, in: RoundedRectangle(cornerRadius: 9))
            .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.48 : 1)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Commit note (⌘↩)")
        }
        .padding(16)
        .frame(width: 260, alignment: .top)
    }

    private func commitTitle() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            capture.updateActiveTitle(trimmed)
        }
        draftTitle = capture.activeTitle
        editingTitle = false
        titleFocused = false
    }

    private func commitNote() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        capture.addNote(trimmed)
        noteDraft = ""
        // Keep the tray open: sending a note shouldn't close the notepad.
        // (User: "note panel closes after initial send" was a bug.)
        noteFocused = true
    }

    private func dismissPanelWindow() {
        dismissWindow(id: Self.windowID)
        DispatchQueue.main.async {
            NSApp.windows.first { $0.identifier?.rawValue == Self.windowID }?.close()
        }
    }

    private func resizeWindow(expanded: Bool) {
        let targetWidth: CGFloat = expanded ? 577 : 316
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == Self.windowID }) else { return }
            var frame = window.frame
            let rightEdge = frame.maxX
            frame.size.width = targetWidth
            frame.origin.x = rightEdge - targetWidth
            window.setFrame(frame, display: true, animate: true)
        }
    }
}

struct RecordingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.remove(.closable)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

struct SettingsView: View {
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
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Section.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: section.symbol)
                                .font(.system(size: 13, weight: .medium))
                            Text(section.rawValue)
                                .font(.system(size: 11, weight: selection == section ? .semibold : .regular))
                        }
                        .foregroundStyle(selection == section ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .overlay(alignment: .bottom) {
                            Capsule()
                                .fill(selection == section ? counterfoilRed : .clear)
                                .frame(height: 2)
                                .padding(.horizontal, 18)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .help(section.rawValue)
                }
            }

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
        }
        .frame(minWidth: 680, minHeight: 485)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(name, systemImage: systemImage)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 6)
                Text(state.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.color)
            }

            HStack(alignment: .top, spacing: 12) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button("Open System Settings") {
                    CounterfoilPermissions.open(settingsURL)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct PermissionsSettingsView: View {
    @State private var microphoneState = CounterfoilPermissionState.unknown
    @State private var screenRecordingState = CounterfoilPermissionState.unknown

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                settingsHeading

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

                HStack {
                    Text("Permission changes may require restarting Counterfoil.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check status") {
                        refresh()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(counterfoilRed)
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { refresh() }
    }

    private var settingsHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Permissions")
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Text("Counterfoil asks only for the access needed to record both sides of a meeting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refresh() {
        microphoneState = CounterfoilPermissions.microphoneState()
        screenRecordingState = CounterfoilPermissions.screenRecordingState()
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("General")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text("Keep Counterfoil quiet and local.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    Toggle("Automatically delete audio after 30 days", isOn: $settings.autoDeleteEnabled)
                    Text("Transcripts are always kept. Older audio is moved to Trash when this is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 5)
                }

                GroupBox {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 18))
                            .foregroundStyle(counterfoilCoral)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Private by default")
                                .font(.body.weight(.semibold))
                            Text("100% local. Audio and transcripts never leave your Mac. No accounts, no cloud, no tracking.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(28)
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsHeading("Models", subtitle: "Choose the local model used for new meetings.")

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
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
                                Task { await Transcriber.shared.preloadModels() }
                            }
                        }
                        Text("The selected model is used for future transcriptions. Models are stored outside the app bundle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Models")
                        .font(.headline)
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

                Text("Models live in ~/Library/Application Support/Counterfoil/Models/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .onAppear { syncSelection() }
    }

    private func settingsHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func syncSelection() {
        guard !installedModels.contains(selectedModel), let first = installedModels.first else { return }
        selectedModel = first
        settings.selectedModel = first
    }

    private func modelCard(title: String, detail: String, installed: Bool, downloading: Bool, progress: Double, error: String?, download: @escaping () -> Void) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 19))
                        .foregroundStyle(installed ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.body.weight(.semibold))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installed {
                        Text("Installed")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    } else if downloading {
                        VStack(alignment: .trailing, spacing: 3) {
                            ProgressView(value: progress)
                                .frame(width: 95)
                            Text("\(Int(progress * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Download") { download() }
                            .buttonStyle(.bordered)
                    }
                }
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
                    Task { await Transcriber.shared.preloadModels() }
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
                    Task { await Transcriber.shared.preloadModels() }
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
                let (bytes, response) = try await withProgressDownload(url: url, progress: progress)
                try bytes.write(to: archivePath)

                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                    throw NSError(domain: "download", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download failed with HTTP error"])
                }

                let modelsDirectory = Transcriber.modelsDir
                try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
                let extracted = try await extractTarGz(at: archivePath, to: modelsDirectory)
                try? FileManager.default.removeItem(at: archivePath)
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

    private func withProgressDownload(url: URL, progress: @escaping (Double) -> Void) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        let (data, response) = try await URLSession.shared.data(for: request)
        progress(1)
        return (data, response)
    }

    private func extractTarGz(at archivePath: URL, to destination: URL) async throws -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archivePath.path, "-C", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let fileManager = FileManager.default
        let contents = try? fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.contentModificationDateKey])
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
    }
}

struct VocabSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Vocabulary")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text("Replace names and terms after local transcription, with word boundaries respected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 16)

            HStack {
                Text("From")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("To")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 28, height: 1)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 5)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(settings.vocabularyPairs) { pair in
                        vocabRow(pair)
                    }
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    settings.vocabularyPairs.append(VocabularyPair(from: "", to: ""))
                } label: {
                    Label("Add Replacement", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(28)
        }
    }

    private func vocabRow(_ pair: VocabularyPair) -> some View {
        HStack(spacing: 8) {
            TextField("e.g. tachy board", text: Binding(
                get: { pair.from },
                set: { value in
                    if let index = settings.vocabularyPairs.firstIndex(where: { $0.id == pair.id }) {
                        settings.vocabularyPairs[index].from = value
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)

            TextField("e.g. Tachyboard", text: Binding(
                get: { pair.to },
                set: { value in
                    if let index = settings.vocabularyPairs.firstIndex(where: { $0.id == pair.id }) {
                        settings.vocabularyPairs[index].to = value
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)

            Button {
                if let index = settings.vocabularyPairs.firstIndex(where: { $0.id == pair.id }) {
                    settings.vocabularyPairs.remove(at: index)
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 32)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 13) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Counterfoil")
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Text("Version \(bundleVersion()) (\(bundleBuild()))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider().frame(width: 210)
            Text("100% local. Audio and transcripts never leave your Mac. No accounts, no cloud, no tracking.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(width: 300)
            Button("Show onboarding again") {
                UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
                NotificationCenter.default.post(name: NSNotification.Name("CounterfoilShowOnboarding"), object: nil)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func bundleVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private func bundleBuild() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

struct OnboardingView: View {
    static let windowID = "onboarding"

    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var settings = SettingsStore.shared
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var page = 0
    @State private var microphoneState = CounterfoilPermissionState.unknown
    @State private var screenRecordingState = CounterfoilPermissionState.unknown

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Counterfoil")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Spacer()
                Button("Skip") { skip() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 22)
            .padding(.top, 15)
            .padding(.bottom, 9)

            Divider()

            Group {
                switch page {
                case 0:
                    welcomePage
                case 1:
                    permissionsPage
                default:
                    readyPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index == page ? counterfoilRed : Color.secondary.opacity(0.28))
                            .frame(width: index == page ? 7 : 5, height: index == page ? 7 : 5)
                    }
                }
                .frame(width: 58, alignment: .leading)

                Spacer()

                if page > 0 {
                    Button("Back") { page -= 1 }
                        .buttonStyle(.bordered)
                        .frame(minWidth: 68, minHeight: 30)
                        .contentShape(Rectangle())
                }

                Button(page == 2 ? "Start using Counterfoil" : "Continue") {
                    if page == 2 {
                        finish()
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) { page += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(counterfoilRed)
                .frame(minWidth: page == 2 ? 166 : 88, minHeight: 30)
                .contentShape(Rectangle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
        }
        .frame(width: 480, height: 360)
        .onAppear { refreshPermissions() }
        .onExitCommand { skip() }
        .onDisappear {
            if !hasSeenOnboarding {
                hasSeenOnboarding = true
            }
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(counterfoilRed)
                .padding(.top, 8)

            Text("Meetings, kept local.")
                .font(.system(.title2, design: .rounded).weight(.semibold))

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
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A couple of permissions")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                    Text("Counterfoil needs these to hear you and the meeting audio. macOS will keep the final decision in your hands.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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

                HStack {
                    Text("Status: (microphoneState.rawValue) · (screenRecordingState.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check status") { refreshPermissions() }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 23)
            .padding(.top, 17)
            .padding(.bottom, 3)
        }
    }

    private var readyPage: some View {
        VStack(spacing: 13) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 43, weight: .medium))
                .foregroundStyle(.green)
                .padding(.top, 7)

            Text("You're ready")
                .font(.system(.title2, design: .rounded).weight(.semibold))

            Text("Your next meeting will appear in the sidebar. Use Record Meeting when you’re ready; the title prompt comes first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 365)

            Label("Record Meeting", systemImage: "record.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(counterfoilRed)
                .padding(.horizontal, 15)
                .frame(minHeight: 34)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(counterfoilRed.opacity(0.35), lineWidth: 1)
                }

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

    private func openModelsSettings() {
        UserDefaults.standard.set(true, forKey: "openModelsSettings")
        finish()
        DispatchQueue.main.async {
            if #available(macOS 14.0, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }

    private func finish() {
        hasSeenOnboarding = true
        dismissWindow(id: Self.windowID)
    }

    private func skip() {
        finish()
    }
}
