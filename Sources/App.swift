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
            CommandMenu("Recording") {
                Button(capture.isRecording ? "Stop Recording" : "Start Recording") {
                    if capture.isRecording {
                        capture.stop(store: store)
                    } else {
                        capture.start()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button("Toggle Microphone") {
                    capture.micEnabled.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command])
                .disabled(!CaptureManager.hasMic)
            }
        }
    }
}
