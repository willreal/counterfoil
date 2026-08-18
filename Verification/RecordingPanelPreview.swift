import SwiftUI

@main
@MainActor
struct RecordingPanelPreviewApp: App {
    @StateObject private var capture: CaptureManager
    @StateObject private var store: TranscriptStore
    @State private var darkAppearance = false
    @State private var channelsHaveProblems = false

    init() {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        let capture = CaptureManager()
        capture.configureDeterministicPreview()
        _capture = StateObject(wrappedValue: capture)
        _store = StateObject(wrappedValue: TranscriptStore())
    }

    var body: some Scene {
        Window("Recording Panel Preview", id: RecordingWindowView.windowID) {
            RecordingWindowView(capture: capture, store: store)
                .tint(Color(nsColor: .systemRed))
                .preferredColorScheme(darkAppearance ? .dark : .light)
                .containerBackground(.clear, for: .window)
                .windowResizeAnchor(.top)
                .windowDismissBehavior(capture.phase.presentsRecordingPanel ? .disabled : .enabled)
                .windowMinimizeBehavior(.disabled)
                .windowResizeBehavior(.disabled)
                .windowFullScreenBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 280, height: 112)
        .defaultPosition(.center)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .windowManagerRole(.associated)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Finish Audio") {
                    capture.transitionDeterministicPreview(to: .transcribing)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Toggle Appearance") {
                    darkAppearance.toggle()
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Toggle Paused State") {
                    if capture.phase == .paused {
                        capture.transitionDeterministicPreview(to: .recording)
                    } else {
                        capture.transitionDeterministicPreview(to: .paused)
                    }
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Toggle Channel Problems") {
                    channelsHaveProblems.toggle()
                    if channelsHaveProblems {
                        capture.setDeterministicChannelStates(
                            system: .unavailable,
                            microphone: .failed("Preview microphone failure")
                        )
                    } else {
                        capture.setDeterministicChannelStates(system: .active, microphone: .active)
                    }
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }
}
