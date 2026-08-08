import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var capture: CaptureManager
    @State private var showingDeleteAudioConfirm = false
    @State private var showingDeleteEverythingConfirm = false
    @State private var sessionToDelete: Session?
    @State private var titleText = ""

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
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text(formatDuration(capture.recordingDuration))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 8)
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
                if let id, let s = store.sessions.first(where: { $0.id == id }) {
                    store.loadTranscript(for: s)
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
                ScrollView {
                    Text(parseMarkdown(store.transcriptContent[session.id] ?? ""))
                        .textSelection(.enabled)
                        .font(.system(.body))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .background(Color(nsColor: .textBackgroundColor))
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
