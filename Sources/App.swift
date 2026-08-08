import SwiftUI
import AppKit

@main
struct CounterfoilApp: App {
    @StateObject private var store = TranscriptStore()
    @StateObject private var capture = CaptureManager()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, capture: capture)
                .frame(minWidth: 820, minHeight: 520)
                .task {
                    await store.loadSessions()
                }
                .task {
                    await Transcriber.shared.preloadModels()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Find") {
                    NotificationCenter.default.post(name: NSNotification.Name("CounterfoilFind"), object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Recording") {
                Button(capture.isRecording ? "Stop Recording" : "Start Recording") {
                    if capture.isRecording {
                        capture.stop(store: store)
                    } else {
                        capture.showTitlePrompt = true
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Button(capture.isPaused ? "Resume Recording" : "Pause Recording") {
                    if capture.isPaused {
                        capture.resumeCapture()
                    } else {
                        capture.pauseCapture()
                    }
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(!capture.isRecording)

                Divider()

                Button("Flag Moment") {
                    capture.flagCurrentMoment()
                }
                .keyboardShortcut("f", modifiers: [.option, .command])
                .disabled(!capture.isRecording || capture.isPaused)
            }
        }

        Settings {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}
