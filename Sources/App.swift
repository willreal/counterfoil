import SwiftUI
import AppKit

@main
struct CounterfoilApp: App {
    @StateObject private var store = TranscriptStore()
    @StateObject private var capture = CaptureManager()

    init() {
        // Single-window utility: disable window state restoration.
        // Stale saved frames (from before layout changes) otherwise restore
        // as invisible ghost windows and the real window never appears.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, capture: capture)
                .frame(minWidth: 980, minHeight: 520)
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
        }

        Window("Recording", id: RecordingPanelView.windowID) {
            RecordingPanelView(capture: capture, store: store)
                .background(RecordingWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 316, height: 340)
        .windowResizability(.contentSize)

        Window("Welcome to Counterfoil", id: OnboardingView.windowID) {
            OnboardingView()
        }
        .defaultSize(width: 480, height: 360)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}
