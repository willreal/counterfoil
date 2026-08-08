import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

class TranscriptPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var rate: Float = 1.0
    @Published var hasAudio = false
    @Published var activeOffset: TimeInterval?

    private var player: AVPlayer?
    private var timeObserver: Any?

    func load(url: URL) {
        stop()
        let p = AVPlayer(url: url)
        p.rate = rate
        player = p
        hasAudio = true

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
    }

    func play(from time: TimeInterval) {
        guard let p = player else { return }
        let cm = CMTime(seconds: time, preferredTimescale: 600)
        p.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        p.rate = rate
        isPlaying = true
        activeOffset = time
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        player?.rate = rate
        isPlaying = true
    }

    func toggle() {
        isPlaying ? pause() : resume()
    }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying {
            player?.rate = r
        }
    }

    func stop() {
        player?.pause()
        player = nil
        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }
        isPlaying = false
        hasAudio = false
        currentTime = 0
        activeOffset = nil
    }

    deinit {
        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
        }
    }
}

struct TranscriptLineItem: Identifiable {
    let id = UUID()
    let text: String
    let timestamp: TimeInterval?
    let raw: String
    let isHeader: Bool
    let isMeta: Bool
    let isEmpty: Bool
}

struct ContentView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var capture: CaptureManager
    @StateObject private var player = TranscriptPlayer()
    @State private var showingDeleteAudioConfirm = false
    @State private var showingDeleteEverythingConfirm = false
    @State private var sessionToDelete: Session?
    @State private var titleText = ""
    @State private var noteText = ""
    @State private var showNotePopover = false
    @State private var playStatusTime: String = ""
    @State private var showSearch = false
    @State private var showImportPicker = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 220)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup {
                Spacer()

                if showSearch {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search...", text: $store.searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .focused($searchFocused)
                            .onSubmit {
                                if store.searchQuery.isEmpty {
                                    showSearch = false
                                }
                            }
                        if !store.searchQuery.isEmpty {
                            Button {
                                store.searchQuery = ""
                                showSearch = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Button {
                        showSearch = true
                        searchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Find (⌘F)")
                }

                Button {
                    showImportPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import audio file")
                .disabled(capture.isRecording)

                if capture.isRecording {
                    HStack(spacing: 6) {
                        if CaptureManager.hasMic {
                            micMeter
                                .frame(width: 24, height: 14)
                        }

                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)

                        Text(formatDuration(capture.recordingDuration))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(capture.isPaused ? .yellow : .red)
                    }
                    .padding(.horizontal, 8)

                    if !capture.isPaused {
                        Button {
                            capture.flagCurrentMoment()
                        } label: {
                            Image(systemName: "flag.fill")
                        }
                        .help("Flag moment (⌥⌘F)")

                        Button {
                            noteText = ""
                            showNotePopover = true
                        } label: {
                            Image(systemName: "note.text.badge.plus")
                        }
                        .help("Add note")
                        .popover(isPresented: $showNotePopover, arrowEdge: .bottom) {
                            VStack(spacing: 8) {
                                Text("Add note at current time")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("Note", text: $noteText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)
                                    .onSubmit {
                                        commitNote()
                                    }
                                HStack {
                                    Spacer()
                                    Button("Cancel") { showNotePopover = false }
                                    Button("Add") { commitNote() }
                                        .keyboardShortcut(.return, modifiers: [])
                                        .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            }
                            .padding(12)
                        }
                    }

                    Button {
                        if capture.isPaused {
                            capture.resumeCapture()
                        } else {
                            capture.pauseCapture()
                        }
                    } label: {
                        Image(systemName: capture.isPaused ? "play.fill" : "pause.fill")
                    }
                    .foregroundColor(.yellow)
                    .help(capture.isPaused ? "Resume recording (⌘P)" : "Pause recording (⌘P)")
                }

                if !CaptureManager.hasMic {
                    Image(systemName: "mic.slash")
                        .foregroundColor(.secondary)
                        .help("No microphone detected")
                }

                Button {
                    if capture.isRecording {
                        capture.stop(store: store)
                    } else {
                        titleText = ""
                        capture.showTitlePrompt = true
                    }
                } label: {
                    if capture.isRecording {
                        Label("Stop", systemImage: "stop.fill")
                    } else {
                        Label("Record", systemImage: "record.circle.fill")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .labelStyle(.iconOnly)
                .font(.system(size: 28))
                .foregroundColor(capture.isRecording ? .red : .red)
            }
        }
        .sheet(isPresented: $capture.showTitlePrompt) {
            titleSheet
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                Task {
                    await store.importAudio(url: url)
                }
            }
        }
        .alert("Low Disk Space", isPresented: $capture.showLowDiskAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                capture.confirmLowDiskStart()
            }
        } message: {
            Text("Less than 2 GB of free disk space available. Recording may fail if space runs out.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CounterfoilFind"))) { _ in
            showSearch = true
            searchFocused = true
        }
    }

    func commitNote() {
        let t = noteText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        capture.addNote(t)
        showNotePopover = false
    }

    var micMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.green)
                    .frame(width: max(2, geo.size.width * capture.micLevel), height: 4)
                    .animation(.easeOut(duration: 0.1), value: capture.micLevel)
            }
        }
    }

    var titleSheet: some View {
        VStack(spacing: 16) {
            Text("Start Recording")
                .font(.headline)
            TextField("Meeting title", text: $titleText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit {
                    startWithTitle()
                }
            HStack(spacing: 16) {
                Button("Cancel") {
                    capture.showTitlePrompt = false
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button("Start Recording") {
                    startWithTitle()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(titleText.trimmingCharacters(in: .whitespaces).isEmpty && false)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    func startWithTitle() {
        var t = titleText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            t = "Meeting \(df.string(from: Date()))"
        }
        capture.showTitlePrompt = false
        capture.start(title: t)
    }

    var sidebar: some View {
        List(selection: Binding(
            get: { store.selectedSession },
            set: { id in
                store.selectedSession = id
                player.stop()
                if let id, let s = store.sessions.first(where: { $0.id == id }) {
                    store.loadTranscript(for: s)
                    loadPlayer(for: s)
                }
            }
        )) {
            if !store.orphanSessions.isEmpty && store.searchQuery.isEmpty {
                Section(header: Text("Recoverable").font(.headline).foregroundColor(.orange)) {
                    ForEach(store.orphanSessions) { orphan in
                        orphanRow(orphan)
                    }
                }
            }

            if store.displayedSessions.isEmpty {
                if store.searchQuery.isEmpty {
                    emptySidebar
                } else {
                    VStack(spacing: 8) {
                        Text("No results")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("for \"\(store.searchQuery)\"")
                            .font(.caption)
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            } else {
                ForEach(groupedDays(), id: \.0) { day, daySessions in
                    Section(header: Text(day).font(.headline).foregroundColor(.secondary)) {
                        ForEach(daySessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)  // let coralBackground show through rows
        .background(coralBackground)
    }

    func orphanRow(_ orphan: OrphanInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recoverable recording")
                    .font(.body.bold())
                Text(orphan.stem)
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    func loadPlayer(for session: Session) {
        let sysM4a = (session.dayDir as NSString).appendingPathComponent("\(session.stem).m4a")
        if FileManager.default.fileExists(atPath: sysM4a) {
            player.load(url: URL(fileURLWithPath: sysM4a))
        }
    }

    var coralBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Color(red: 0.95, green: 0.55, blue: 0.45)
                .opacity(0.08)
        }
    }

    var emptySidebar: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No recordings yet")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Press ⌘R to start recording")
                .font(.caption)
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    func sessionRow(_ session: Session) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.body.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(formatTimeOnly(session.startTime))
                        .font(.caption)
                    if session.duration > 0 {
                        Text("·")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(formatDuration(session.duration))
                            .font(.caption)
                    }
                }
                .foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                if session.hasTranscript {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !session.hasSystemFile && !session.hasMicFile {
                    Text("transcript only")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(3)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
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
        .alert("Delete Audio?", isPresented: $showingDeleteAudioConfirm, presenting: sessionToDelete) { s in
            Button("Cancel", role: .cancel) {}
            Button("Delete Audio", role: .destructive) {
                store.deleteAudioFiles(s)
            }
        } message: { s in
            Text("The audio files (.m4a) will be moved to Trash. The transcript will be kept.")
        }
        .alert("Delete Everything?", isPresented: $showingDeleteEverythingConfirm, presenting: sessionToDelete) { s in
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                store.deleteEverything(s)
            }
        } message: { s in
            Text("The audio files AND the transcript will be permanently moved to Trash. This cannot be undone.")
        }
    }

    var detailPane: some View {
        Group {
            if let id = store.selectedSession, let session = store.sessions.first(where: { $0.id == id }) {
                transcriptView(session: session)
            } else if store.sessions.isEmpty {
                emptyDetail
            } else {
                VStack {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("Select a recording")
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    func transcriptView(session: Session) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.title3.bold())
                    HStack(spacing: 12) {
                        if session.duration > 0 {
                            Label(formatDuration(session.duration), systemImage: "clock")
                        }
                        Label(session.hasSystemFile ? "Audio present" : "Audio deleted",
                              systemImage: session.hasSystemFile ? "waveform" : "waveform.slash")
                        if session.hasMicFile {
                            Label("Mic", systemImage: "mic.fill")
                        }
                        if !session.hasSystemFile && !session.hasMicFile && session.hasTranscript {
                            Label("Transcript only", systemImage: "doc.text")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()

                if session.hasTranscript, player.hasAudio {
                    HStack(spacing: 4) {
                        Button {
                            player.toggle()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .help(player.isPlaying ? "Pause" : "Play")

                        if player.isPlaying || player.currentTime > 0 {
                            Text(formatDuration(player.currentTime))
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .leading)
                        }

                        Picker("Speed", selection: Binding(get: {
                            Double(player.rate)
                        }, set: { r in
                            player.setRate(Float(r))
                        })) {
                            Text("0.5×").tag(0.5)
                            Text("1×").tag(1.0)
                            Text("1.5×").tag(1.5)
                            Text("2×").tag(2.0)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 64)
                        .help("Playback speed")
                    }
                }

                if session.hasTranscript {
                    Button {
                        copyTranscript(session: session)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy Transcript")

                    Button {
                        revealInFinder(session: session)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal in Finder")
                }

                Menu {
                    Button {
                        sessionToDelete = session
                        showingDeleteAudioConfirm = true
                    } label: {
                        Label("Delete Audio", systemImage: "trash")
                    }
                    Button(role: .destructive) {
                        sessionToDelete = session
                        showingDeleteEverythingConfirm = true
                    } label: {
                        Label("Delete Everything", systemImage: "trash.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Delete options")
            }
            .padding(12)
            Divider()

            if store.transcriptContent[session.id] == nil {
                if session.hasTranscript {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyTranscribing
                }
            } else {
                transcriptBody(session: session)
            }

            if capture.status.contains("Transcribing") {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(capture.status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
            }
        }
    }

    func highlightColor(for line: TranscriptLineItem) -> Color {
        if !store.searchQuery.isEmpty && line.raw.lowercased().contains(store.searchQuery.lowercased()) {
            return Color.yellow.opacity(0.3)
        }
        if player.hasAudio && player.activeOffset == line.timestamp && player.isPlaying {
            return Color.accentColor.opacity(0.12)
        }
        return Color.clear
    }

    func transcriptBody(session: Session) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let lines = parseTranscriptLines(store.transcriptContent[session.id] ?? "")
                    ForEach(lines) { line in
                        if line.isHeader || line.isMeta || line.isEmpty {
                            Text(parseMarkdown(line.raw))
                                .textSelection(.enabled)
                                .font(.system(.body))
                                .padding(.horizontal, 16)
                                .padding(.vertical, line.isEmpty ? 0 : 4)
                                .background(highlightColor(for: line))
                        } else {
                            Button {
                                if player.hasAudio, let ts = line.timestamp {
                                    player.play(from: ts)
                                }
                            } label: {
                                Text(parseMarkdown(line.raw))
                                    .font(.system(.body))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                            .background(highlightColor(for: line))
                            .id(line.id)
                            .onHover { hovering in
                                if hovering && player.hasAudio && line.timestamp != nil {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: player.currentTime) { _, newTime in
                if player.isPlaying {
                    if let activeLine = findActiveLine(
                        store.transcriptContent[session.id] ?? "",
                        time: newTime
                    ) {
                        proxy.scrollTo(activeLine.id, anchor: .center)
                    }
                }
            }
        }
    }

    func parseTranscriptLines(_ md: String) -> [TranscriptLineItem] {
        let rawLines = md.components(separatedBy: "\n")
        var items: [TranscriptLineItem] = []
        let tsPattern = try! NSRegularExpression(pattern: #"^\*\*\[(\d{2}:\d{2}:\d{2})\]"#, options: [])

        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                items.append(TranscriptLineItem(text: "", timestamp: nil, raw: raw, isHeader: false, isMeta: false, isEmpty: true))
                continue
            }
            if trimmed.hasPrefix("# ") {
                items.append(TranscriptLineItem(text: trimmed, timestamp: nil, raw: raw, isHeader: true, isMeta: false, isEmpty: false))
                continue
            }
            if trimmed.hasPrefix("*") && trimmed.hasSuffix("*") {
                items.append(TranscriptLineItem(text: trimmed, timestamp: nil, raw: raw, isHeader: false, isMeta: true, isEmpty: false))
                continue
            }

            if let m = tsPattern.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) {
                let tsStr = (trimmed as NSString).substring(with: m.range(at: 1))
                let parts = tsStr.components(separatedBy: ":")
                let secs = (Int(parts[0]) ?? 0) * 3600 + (Int(parts[1]) ?? 0) * 60 + (Int(parts[2]) ?? 0)
                items.append(TranscriptLineItem(
                    text: trimmed,
                    timestamp: TimeInterval(secs),
                    raw: raw,
                    isHeader: false, isMeta: false, isEmpty: false
                ))
            } else {
                items.append(TranscriptLineItem(text: trimmed, timestamp: nil, raw: raw, isHeader: false, isMeta: false, isEmpty: false))
            }
        }
        return items
    }

    func findActiveLine(_ md: String, time: TimeInterval) -> TranscriptLineItem? {
        let lines = parseTranscriptLines(md)
        var best: TranscriptLineItem?
        for line in lines {
            guard let ts = line.timestamp else { continue }
            if ts <= time + 0.25 {
                best = line
            }
        }
        return best
    }

    var emptyDetail: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No recordings yet")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Press ⌘R or click Record to start your first meeting")
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            if !Transcriber.shared.modelsAvailable {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Transcription models not installed")
                        .font(.callout)
                    Text("Open Settings → Models to download")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Open Settings") {
                        if #available(macOS 14.0, *) {
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        } else {
                            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding()
            }
            if capture.status.contains("Error") {
                Text(capture.status)
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var emptyTranscribing: some View {
        VStack(spacing: 16) {
            if !Transcriber.shared.modelsAvailable {
                Image(systemName: "square.stack.3d.up.trianglebadge.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                Text("Models needed for transcription")
                    .font(.headline)
                Text("Download models in Settings → Models to enable transcription.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 260)
                Button("Open Settings") {
                    if #available(macOS 14.0, *) {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } else {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                }
                .padding(.top, 4)
            } else {
                Image(systemName: "text.badge.xmark")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("No transcript yet")
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func parseMarkdown(_ md: String) -> AttributedString {
        do {
            return try AttributedString(markdown: md, options: AttributedString.MarkdownParsingOptions())
        } catch {
            return AttributedString(md)
        }
    }

    func copyTranscript(session: Session) {
        if let content = store.transcriptContent[session.id] {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(content, forType: .string)
        } else {
            let mdPath = (session.dayDir as NSString).appendingPathComponent("\(session.stem).md")
            if let content = try? String(contentsOfFile: mdPath, encoding: .utf8) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(content, forType: .string)
            }
        }
    }

    func revealInFinder(session: Session) {
        let mdPath = (session.dayDir as NSString).appendingPathComponent("\(session.stem).md")
        let sysM4aPath = (session.dayDir as NSString).appendingPathComponent("\(session.stem).m4a")
        let sysMp4Path = (session.dayDir as NSString).appendingPathComponent("\(session.stem).mp4")
        let micPath = (session.dayDir as NSString).appendingPathComponent("\(session.stem).mic.m4a")

        var urls: [URL] = []
        for p in [mdPath, sysM4aPath, sysMp4Path, micPath] {
            let url = URL(fileURLWithPath: p)
            if FileManager.default.fileExists(atPath: p) {
                urls.append(url)
            }
        }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func groupedDays() -> [(String, [Session])] {
        let sessions = store.displayedSessions
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none

        var groups: [String: [Session]] = [:]
        for s in sessions {
            let key = df.string(from: s.startTime)
            groups[key, default: []].append(s)
        }
        return groups.sorted(by: { $0.0 > $1.0 }).map { ($0.key, $0.value.sorted(by: { $0.startTime > $1.startTime })) }
    }

    func formatDuration(_ d: TimeInterval) -> String {
        let min = Int(d) / 60
        let sec = Int(d) % 60
        return String(format: "%d:%02d", min, sec)
    }

    func formatTimeOnly(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
}

// MARK: Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            VocabSettingsView()
                .tabItem { Label("Vocabulary", systemImage: "textformat.abc") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelsSettingsView()
                .tabItem { Label("Models", systemImage: "square.stack.3d.up") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var selectedModel: String

    init() {
        _selectedModel = State(initialValue: SettingsStore.shared.selectedModel)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Automatically delete audio after 7 days", isOn: $settings.autoDeleteEnabled)
                Text("Transcripts are always kept. When enabled, audio files older than 7 days are moved to Trash.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Transcription Model") {
                if settings.availableModels.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading) {
                            Text("No models installed")
                                .font(.body.bold())
                            Text(Transcriber.shared.modelsMissingReason)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(settings.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .onChange(of: selectedModel) { _, newValue in
                        settings.selectedModel = newValue
                        Task { await Transcriber.shared.preloadModels() }
                    }
                    Text("The selected model is used for all future transcriptions. Changes take effect at next transcription.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ModelsSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var v2Downloading = false
    @State private var v3Downloading = false
    @State private var v2Progress: Double = 0
    @State private var v3Progress: Double = 0
    @State private var v2Error: String?
    @State private var v3Error: String?
    @State private var v2Completed = false
    @State private var v3Completed = false

    var body: some View {
        Form {
            Section {
                Text("Transcription models live in ~/Library/Application Support/Counterfoil/Models/")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Installed Models") {
                if settings.availableModels.isEmpty {
                    Label("No models installed", systemImage: "xmark.circle")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(settings.availableModels, id: \.self) { model in
                        HStack {
                            Label(model, systemImage: "shippingbox.fill")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("Installed")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
            }

            Section("Download Models") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Parakeet V2")
                                .font(.body.bold())
                            Text("~450 MB · 1,031-token vocab · Default model")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if v2Completed || settings.hasModel(named: "Parakeet V2") {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else if v2Downloading {
                            VStack(spacing: 2) {
                                ProgressView(value: v2Progress, total: 1.0)
                                    .frame(width: 80)
                                Text("\(Int(v2Progress * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Button("Download V2") {
                                downloadV2()
                            }
                        }
                    }

                    if let err = v2Error {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Parakeet V3")
                                .font(.body.bold())
                            Text("~461 MB · 8,192-token vocab · Improved accuracy")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if v3Completed || settings.hasModel(named: "parakeet-tdt-0.6b-v3-coreml") {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else if v3Downloading {
                            VStack(spacing: 2) {
                                ProgressView(value: v3Progress, total: 1.0)
                                    .frame(width: 80)
                                Text("\(Int(v3Progress * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Button("Download V3") {
                                downloadV3()
                            }
                        }
                    }

                    if let err = v3Error {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    func downloadV2() {
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
                    v2Progress = 1.0
                    Task { await Transcriber.shared.preloadModels() }
                case .failure(let err):
                    v2Error = err.localizedDescription
                }
            }
        }
    }

    func downloadV3() {
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
                    v3Progress = 1.0
                    Task { await Transcriber.shared.preloadModels() }
                case .failure(let err):
                    v3Error = err.localizedDescription
                }
            }
        }
    }

    func performDownload(urlString: String, label: String,
                         progress: @escaping (Double) -> Void,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                guard let url = URL(string: urlString) else {
                    throw NSError(domain: "download", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
                }

                let tmpDir = FileManager.default.temporaryDirectory
                let archivePath = tmpDir.appendingPathComponent("\(label)-\(UUID().uuidString).tar.gz")

                let (bytes, response) = try await withProgressDownload(url: url, progress: progress)
                try bytes.write(to: archivePath)

                guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                    throw NSError(domain: "download", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Download failed with HTTP error"])
                }

                let modelsDir = Transcriber.modelsDir
                try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

                let extractDir = try await extractTarGz(at: archivePath, to: modelsDir)
                try? FileManager.default.removeItem(at: archivePath)

                guard let extracted = extractDir else {
                    throw NSError(domain: "download", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to extract archive"])
                }

                let names = ["Preprocessor", "Encoder", "Decoder", "JointDecision"]
                for name in names {
                    if !FileManager.default.fileExists(atPath: extracted.appendingPathComponent("\(name).mlmodelc").path) {
                        throw NSError(domain: "download", code: 4,
                                      userInfo: [NSLocalizedDescriptionKey: "Archive missing \(name).mlmodelc"])
                    }
                }

                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func withProgressDownload(url: URL, progress: @escaping (Double) -> Void) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600

        let (bytes, response) = try await URLSession.shared.data(for: request)
        progress(1.0)
        return (bytes, response)
    }

    func extractTarGz(at archivePath: URL, to destDir: URL) async throws -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archivePath.path, "-C", destDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }

        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: destDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let sorted = contents.sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return d1 > d2
            }
            for item in sorted {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    if fm.fileExists(atPath: item.appendingPathComponent("Preprocessor.mlmodelc").path) {
                        return item
                    }
                }
            }
            for item in sorted {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    return item
                }
            }
        }
        return destDir
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)

            Text("Counterfoil")
                .font(.title.bold())
            Text("Version \(bundleVersion()) (\(bundleBuild()))")
                .font(.body)
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 200)

            Text("100% local. Audio and transcripts never leave your Mac. No accounts, no cloud, no tracking.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(width: 280)
                .padding(.vertical, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    func bundleVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func bundleBuild() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

struct VocabSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Case-insensitive, word-boundary-aware replacements applied during transcription.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(12)

            HStack {
                Text("From").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                Text("To").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 28)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            ScrollView {
                if #available(macOS 15.0, *) {
                    ForEach(Array(settings.vocabularyPairs.enumerated()), id: \.element.id) { _, pair in
                        vocabRow(pair)
                    }
                } else {
                    ForEach(settings.vocabularyPairs) { pair in
                        vocabRow(pair)
                    }
                }
            }

            Button {
                settings.vocabularyPairs.append(VocabularyPair(from: "", to: ""))
            } label: {
                Label("Add Replacement", systemImage: "plus")
            }
            .padding(12)
        }
    }

    func vocabRow(_ pair: VocabularyPair) -> some View {
        HStack {
            TextField("e.g., tachy board", text: Binding(
                get: { pair.from },
                set: { newValue in
                    if let i = settings.vocabularyPairs.firstIndex(where: { $0.id == pair.id }) {
                        settings.vocabularyPairs[i].from = newValue
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            TextField("e.g., Tachyboard", text: Binding(
                get: { pair.to },
                set: { newValue in
                    if let i = settings.vocabularyPairs.firstIndex(where: { $0.id == pair.id }) {
                        settings.vocabularyPairs[i].to = newValue
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            Button {
                if let i = settings.vocabularyPairs.firstIndex(where: { $0.id == pair.id }) {
                    settings.vocabularyPairs.remove(at: i)
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}
