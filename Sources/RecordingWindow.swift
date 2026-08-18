import SwiftUI
import AppKit

private let recordingWindowRed = Color(nsColor: .systemRed)

struct RecordingWindowView: View {
    static let windowID = "recording-panel"

    @ObservedObject var capture: CaptureManager
    @ObservedObject var store: TranscriptStore

    @Environment(\.dismiss) private var dismissWindowContent
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var titleDraft = ""
    @State private var noteDraft = ""
    @State private var noteIsOpen = false
    @FocusState private var titleIsFocused: Bool
    @FocusState private var noteIsFocused: Bool

    private let windowWidth: CGFloat = 280
    private let collapsedHeight: CGFloat = 112
    private let noteHeight: CGFloat = 146

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            header
            controls
            if noteIsOpen {
                noteTray
            }
            if case .failed(let failure) = capture.phase {
                failureTray(failure)
            }
        }
        .frame(width: windowWidth)
        .background(windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .containerBackground(.clear, for: .window)
        .overlay {
            CompactRecordingWindowAccessor()
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: noteIsOpen)
        .onAppear {
            titleDraft = SessionNaming.editorDraft(for: capture.activeTitle)
        }
        .onChange(of: capture.activeTitle) { _, title in
            if !titleIsFocused {
                titleDraft = SessionNaming.editorDraft(for: title)
            }
        }
        .onChange(of: capture.phase) { _, phase in
            if !phase.presentsRecordingPanel {
                closeWindow()
            }
            if case .failed = phase {
                closeNote()
            }
        }
        .onChange(of: titleIsFocused) { _, isFocused in
            if !isFocused {
                commitTitle()
            }
        }
        .onDisappear {
            noteIsOpen = false
            noteIsFocused = false
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private var dragHandle: some View {
        CompactRecordingDragHandle()
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .accessibilityLabel("Move recording window")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField(
                "",
                text: $titleDraft,
                prompt: Text(SessionNaming.untitledTitle)
                    .foregroundStyle(titleColor.opacity(0.9))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .semibold))
            .lineLimit(1)
            .focused($titleIsFocused)
            .onSubmit { commitTitle() }
            .disabled(!capture.phase.isRecordingSession)
            .accessibilityLabel("Meeting title")
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatRecordingClock(capture.recordingDuration))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(capture.phase.isPaused ? Color.orange : titleColor)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Recording time \(formatRecordingClock(capture.recordingDuration))")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    @ViewBuilder
    private var controls: some View {
        if capture.phase == .saving {
            savingControl
        } else {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    controlButton(
                        title: capture.phase.canResume ? "Resume recording" : "Pause recording",
                        symbol: capture.phase.canResume ? "play.fill" : "pause.fill",
                        tint: titleColor,
                        enabled: capture.phase.canPause || capture.phase.canResume
                    ) {
                        if capture.phase.canResume {
                            capture.resumeCapture()
                        } else {
                            capture.pauseCapture()
                        }
                    }

                    controlButton(
                        title: "Flag this moment",
                        symbol: "flag.fill",
                        tint: recordingWindowRed,
                        enabled: capture.phase.canStop
                    ) {
                        capture.flagCurrentMoment()
                    }

                    controlButton(
                        title: noteIsOpen ? "Close note" : "Add a note",
                        symbol: "note.text",
                        tint: titleColor,
                        enabled: capture.phase.canStop
                    ) {
                        toggleNote()
                    }
                }

                Spacer(minLength: 0)

                stopButton
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
    }

    private func controlButton(
        title: String,
        symbol: String,
        tint: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(controlBackground, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
        .help(title)
        .accessibilityLabel(title)
    }

    private var stopButton: some View {
        Button(action: stopRecording) {
            Label("Stop", systemImage: "stop.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 92, height: 38)
                .background(recordingWindowRed, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!capture.phase.canStop)
        .opacity(capture.phase.canStop ? 1 : 0.45)
        .help("Stop recording")
        .accessibilityLabel("Stop recording")
    }

    private var savingControl: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Saving audio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(titleColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .accessibilityElement(children: .combine)
    }

    private var noteTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Note", systemImage: "note.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))

            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: $noteDraft)
                    .focused($noteIsFocused)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .padding(.horizontal, 0)
                    .padding(.trailing, 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Note text")

                Button(action: commitNote) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.18), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                .help("Save note")
                .accessibilityLabel("Save note")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 15)
        .padding(.bottom, 10)
        .frame(width: windowWidth, height: noteHeight, alignment: .top)
        .background(noteBackground)
        .environment(\.colorScheme, .dark)
    }

    private func failureTray(_ failure: RecordingFailure) -> some View {
        let actions = RecordingRecoveryPolicy.actions(for: failure)
        return VStack(spacing: 7) {
            Label("Recording problem", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(recordingWindowRed)

            Text(failure.message)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .foregroundStyle(Color.white.opacity(0.9))

            Text(failure.recoverySuggestion)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .foregroundStyle(Color.white.opacity(0.65))

            HStack(spacing: 8) {
                if actions.contains(.retryPreparation) {
                    Button("Try Again") { capture.retryAfterFailure() }
                }
                if actions.contains(.saveCapturedAudio) {
                    Button("Save Recording") {
                        capture.saveCapturedAudioAfterFailure(store: store)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(recordingWindowRed)
            .controlSize(.small)

            HStack(spacing: 14) {
                if actions.contains(.revealAudio) {
                    Button {
                        capture.revealCurrentFiles()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal audio")
                }
                if actions.contains(.copyDiagnostics) {
                    Button {
                        capture.copyFailureDiagnostics()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy diagnostics")
                }
                if actions.contains(.dismiss) {
                    Button {
                        capture.dismissFailure()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Close")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.82))
        }
        .padding(.horizontal, 12)
        .padding(.top, 15)
        .padding(.bottom, 10)
        .frame(width: windowWidth, height: 190)
        .background(noteBackground)
        .environment(\.colorScheme, .dark)
    }

    private func toggleNote() {
        if noteIsOpen {
            closeNote()
            return
        }

        _ = capture.beginNote()
        noteIsOpen = true
        Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard noteIsOpen else { return }
            noteIsFocused = true
        }
    }

    private func closeNote() {
        capture.cancelPendingNote()
        noteDraft = ""
        noteIsOpen = false
        noteIsFocused = false
    }

    private func commitNote() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        capture.addNote(trimmed, at: capture.noteTimestamp ?? capture.currentElapsedTime())
        closeNote()
    }

    private func commitTitle() {
        guard capture.phase.isRecordingSession else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? SessionNaming.untitledTitle : trimmed
        capture.updateActiveTitle(resolved)
        titleDraft = trimmed.isEmpty ? "" : capture.activeTitle
        titleIsFocused = false
    }

    private func stopRecording() {
        commitTitle()
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            capture.addNote(trimmed, at: capture.noteTimestamp ?? capture.currentElapsedTime())
        } else {
            capture.cancelPendingNote()
        }
        noteDraft = ""
        noteIsOpen = false
        noteIsFocused = false
        capture.stop(store: store)
    }

    private func closeWindow() {
        noteIsOpen = false
        noteIsFocused = false
        dismissWindow(id: Self.windowID)
        dismissWindowContent()
    }

    private var windowBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.14, green: 0.14, blue: 0.15)
            : Color(red: 0.81, green: 0.815, blue: 0.825)
    }

    private var controlBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.11)
            : Color.white.opacity(0.86)
    }

    private var titleColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.78)
            : Color.black.opacity(0.58)
    }

    private var noteBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color.black.opacity(colorScheme == .dark ? 0.13 : 0.08),
                Color.black.opacity(colorScheme == .dark ? 0.34 : 0.22)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct CompactRecordingDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            self
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct CompactRecordingWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        configure(window: nsView.window)
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovable = true
        window.isMovableByWindowBackground = false
        window.hasShadow = true
        window.styleMask.remove(.titled)
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 16
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        private func configureWindow() {
            guard let window else { return }
            CompactRecordingWindowAccessor().configure(window: window)
            window.invalidateShadow()
        }
    }
}
