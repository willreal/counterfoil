import Foundation
import SwiftUI

struct VocabularyPair: Identifiable, Codable, Equatable {
    var id = UUID()
    var from: String
    var to: String
}

class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published private(set) var availableModels: [String]

    @Published var vocabularyPairs: [VocabularyPair] {
        didSet { saveVocabulary() }
    }

    @Published var autoDeleteEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoDeleteEnabled, forKey: "autoDeleteAudio")
            hasChosenAudioRetention = true
            UserDefaults.standard.set(true, forKey: "hasChosenAudioRetention")
        }
    }

    @Published private(set) var hasChosenAudioRetention: Bool

    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }

    var hasAnyModels: Bool {
        !availableModels.isEmpty
    }

    func hasModel(named: String) -> Bool {
        availableModels.contains(named)
    }

    private init() {
        let storedRetention = UserDefaults.standard.object(forKey: "autoDeleteAudio") as? Bool
        self.availableModels = Transcriber.scanAvailableModels()
        self.autoDeleteEnabled = storedRetention ?? false
        self.hasChosenAudioRetention = storedRetention != nil
            || UserDefaults.standard.bool(forKey: "hasChosenAudioRetention")
        self.selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "Parakeet V2"
        self.vocabularyPairs = Self.loadVocabulary()
    }

    func chooseAudioRetention(autoDelete: Bool) {
        autoDeleteEnabled = autoDelete
        hasChosenAudioRetention = true
        UserDefaults.standard.set(true, forKey: "hasChosenAudioRetention")
    }

    func refreshAvailableModels() {
        availableModels = Transcriber.scanAvailableModels()
    }

    private func saveVocabulary() {
        if let data = try? JSONEncoder().encode(vocabularyPairs) {
            UserDefaults.standard.set(data, forKey: "vocabularyPairs")
        }
    }

    private static func loadVocabulary() -> [VocabularyPair] {
        guard let data = UserDefaults.standard.data(forKey: "vocabularyPairs") else { return [] }
        return (try? JSONDecoder().decode([VocabularyPair].self, from: data)) ?? []
    }
}
