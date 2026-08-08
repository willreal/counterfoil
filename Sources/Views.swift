import SwiftUI
import AppKit
import AVFoundation

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
            if store.sessions.isEmpty {
                emptySidebar
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
        .background(coralBackground)
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
                            .background(
                                player.hasAudio && player.activeOffset == line.timestamp && player.isPlaying
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
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
            Image(systemName: "text.badge.xmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No transcript yet")
                .foregroundColor(.secondary)
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
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none

        var groups: [String: [Session]] = [:]
        for s in store.sessions {
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
