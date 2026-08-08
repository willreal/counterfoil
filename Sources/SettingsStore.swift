import Foundation
import SwiftUI

struct VocabularyPair: Identifiable, Codable, Equatable {
    var id = UUID()
    var from: String
    var to: String
}

class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var vocabularyPairs: [VocabularyPair] {
        didSet { saveVocabulary() }
    }

    @Published var autoDeleteEnabled: Bool {
        didSet { UserDefaults.standard.set(autoDeleteEnabled, forKey: "autoDeleteAudio") }
    }

    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }

    var availableModels: [String] {
        Transcriber.scanAvailableModels()
    }

    var hasAnyModels: Bool {
        !availableModels.isEmpty
    }

    func hasModel(named: String) -> Bool {
        availableModels.contains(named)
    }

    private init() {
        self.autoDeleteEnabled = UserDefaults.standard.object(forKey: "autoDeleteAudio") as? Bool ?? true
        self.selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "Parakeet V2"
        self.vocabularyPairs = Self.loadVocabulary()
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
