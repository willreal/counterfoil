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
        let dir = Transcriber.modelsDir
        let fm = FileManager.default
        let flatNames = ["Preprocessor", "Encoder", "Decoder", "JointDecision"]
        let hasVocab = fm.fileExists(atPath: dir.appendingPathComponent("parakeet_vocab.json").path)
        var models: [String] = []

        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in contents {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let sub = item
                let ok = flatNames.allSatisfy { fm.fileExists(atPath: sub.appendingPathComponent("\($0).mlmodelc").path) }
                    && fm.fileExists(atPath: sub.appendingPathComponent("parakeet_vocab.json").path)
                if ok { models.append(item.lastPathComponent) }
            }
        }

        if models.isEmpty && hasVocab {
            let ok = flatNames.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent("\($0).mlmodelc").path) }
            if ok { models.append("Parakeet V2") }
        }

        return models
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
