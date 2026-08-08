import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var capture: CaptureManager
    @State private var showingDeleteConfirm = false
    @State private var sessionToDelete: Session?

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

                if CaptureManager.hasMic {
                    Button {
                        capture.micEnabled.toggle()
                    } label: {
                        Image(systemName: capture.micEnabled ? "mic.fill" : "mic.slash")
                    }
                    .help(capture.micEnabled ? "Microphone enabled" : "Microphone muted")
                    .disabled(capture.isRecording)
                } else {
                    Image(systemName: "mic.slash")
                        .foregroundColor(.secondary)
                        .help("No microphone detected")
                }

                Button {
                    if capture.isRecording {
                        capture.stop(store: store)
                    } else {
                        capture.start()
                    }
                } label: {
                    if capture.isRecording {
                        Label("Stop", systemImage: "stop.fill")
                    } else {
                        Label("Record", systemImage: "record.circle")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .tint(capture.isRecording ? .red : nil)
            }
        }
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
        .background(.ultraThinMaterial)
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
                Text(formatTimeOnly(session.startTime))
                    .font(.system(.body, design: .monospaced))
                if session.duration > 0 {
                    Text(formatDuration(session.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                if session.hasTranscript {
                    Text("📄")
                        .font(.caption)
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
            Button(role: .destructive) {
                sessionToDelete = session
                showingDeleteConfirm = true
            } label: {
                Label("Delete Recording", systemImage: "trash")
            }
        }
        .alert("Delete Recording?", isPresented: $showingDeleteConfirm, presenting: sessionToDelete) { s in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.deleteSession(s)
            }
        } message: { s in
            Text("The audio/video files will be moved to Trash. The transcript will be kept.")
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
                    Text("\(session.stem)")
                        .font(.title3.bold())
                    HStack(spacing: 12) {
                        if session.duration > 0 {
                            Label(formatDuration(session.duration), systemImage: "clock")
                        }
                        Label(session.hasSystemFile ? "Video present" : "Video deleted",
                              systemImage: session.hasSystemFile ? "video.fill" : "video.slash")
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
                Button(role: .destructive) {
                    sessionToDelete = session
                    showingDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete recording files (transcript kept)")
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
                        .font(.system(.body, design: .monospaced))
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
            let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return try AttributedString(markdown: md, options: opts)
        } catch {
            return AttributedString(md)
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
