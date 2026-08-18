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
                .tint(Color(nsColor: .systemRed))
                .accentColor(Color(nsColor: .systemRed))
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
            CommandGroup(after: .appInfo) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: NSNotification.Name("CounterfoilOpenSettings"), object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("Recording", id: RecordingWindowView.windowID) {
            RecordingWindowView(capture: capture, store: store)
                .tint(Color(nsColor: .systemRed))
                .accentColor(Color(nsColor: .systemRed))
                .windowResizeAnchor(.top)
                .windowDismissBehavior(capture.phase.presentsRecordingPanel ? .disabled : .enabled)
                .windowMinimizeBehavior(.disabled)
                .windowResizeBehavior(.disabled)
                .windowFullScreenBehavior(.disabled)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 280, height: 245)
        .defaultPosition(.center)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .windowManagerRole(.associated)
        .commandsRemoved()

        Window("Welcome to Counterfoil", id: OnboardingView.windowID) {
            OnboardingView()
                .accentColor(Color(nsColor: .systemRed))
                .windowDismissBehavior(.disabled)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 520, height: 460)
        .windowResizability(.contentSize)

        Window("Counterfoil Settings", id: SettingsView.windowID) {
            SettingsView()
                .tint(Color(nsColor: .systemRed))
                .accentColor(Color(nsColor: .systemRed))
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 510, height: 420)
        .windowResizability(.contentSize)
    }
}
