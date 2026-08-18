import Foundation

struct TranscriptionResult: Sendable {
    let systemText: String
    let microphoneText: String
}

actor TranscriptionCoordinator {
    static let shared = TranscriptionCoordinator()

    private var tail: Task<Void, Never> = Task {}

    func transcribeSession(
        systemURL: URL?,
        microphoneURL: URL?,
        modelName: String
    ) async throws -> TranscriptionResult {
        let predecessor = tail
        let operation = Task.detached(priority: .userInitiated) {
            await predecessor.value
            try Task.checkCancellation()
            return try await Self.performSession(
                systemURL: systemURL,
                microphoneURL: microphoneURL,
                modelName: modelName
            )
        }
        tail = Task {
            _ = try? await operation.value
        }
        return try await operation.value
    }

    nonisolated private static func performSession(
        systemURL: URL?,
        microphoneURL: URL?,
        modelName: String
    ) async throws -> TranscriptionResult {
        guard systemURL != nil || microphoneURL != nil else {
            return TranscriptionResult(systemText: "", microphoneText: "")
        }
        let transcriber = Transcriber.shared
        defer { transcriber.releaseModels() }
        try transcriber.forceLoadSync(modelName: modelName)

        let systemText: String
        if let systemURL {
            systemText = try await transcriber.transcribeLoaded(filePath: systemURL.path, baseOffset: 0)
        } else {
            systemText = ""
        }

        let microphoneText: String
        if let microphoneURL {
            microphoneText = try await transcriber.transcribeLoaded(filePath: microphoneURL.path, baseOffset: 0)
        } else {
            microphoneText = ""
        }

        return TranscriptionResult(systemText: systemText, microphoneText: microphoneText)
    }
}
