import Foundation

enum RecordingRecoveryAction: String, Equatable {
    case retryPreparation
    case saveCapturedAudio
    case retryTranscription
    case changeModel
    case revealAudio
    case copyDiagnostics
    case dismiss
}

enum RecordingRecoveryPolicy {
    static func actions(for failure: RecordingFailure) -> [RecordingRecoveryAction] {
        switch failure.stage {
        case .preparing:
            return failure.audioPreserved
                ? [.retryPreparation, .revealAudio, .copyDiagnostics, .dismiss]
                : [.retryPreparation, .copyDiagnostics, .dismiss]
        case .pausing, .resuming:
            return failure.audioPreserved
                ? [.saveCapturedAudio, .revealAudio, .copyDiagnostics, .dismiss]
                : [.copyDiagnostics, .dismiss]
        case .saving:
            return failure.audioPreserved
                ? [.revealAudio, .copyDiagnostics, .dismiss]
                : [.copyDiagnostics, .dismiss]
        case .transcribing:
            return [
                .retryTranscription,
                .changeModel,
                .revealAudio,
                .copyDiagnostics,
                .dismiss,
            ]
        }
    }
}

enum RecordingCapacityPolicy {
    static let minimumRecommendedBytes: Int64 = 2 * 1024 * 1024 * 1024

    static func requiresConfirmation(availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return false }
        return availableBytes < minimumRecommendedBytes
    }
}

enum RecordingNoteTiming {
    static func capturedOffset(_ elapsed: TimeInterval) -> TimeInterval {
        max(0, elapsed)
    }
}

enum SessionMetadataIO {
    static func read(from url: URL) throws -> SessionMetadataV1 {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionMetadataV1.self, from: Data(contentsOf: url))
    }

    static func write(_ metadata: SessionMetadataV1, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: url, options: [.atomic])
    }
}

enum SessionCrashRecovery {
    static let interruptedMessage = "Counterfoil closed before processing finished. The captured audio is preserved."
    static let interruptedWithoutAudioMessage = "Counterfoil closed before processing finished. No finalized audio file was found."

    static func recovered(
        metadata: SessionMetadataV1,
        transcriptExists: Bool,
        audioExists: Bool
    ) -> SessionMetadataV1 {
        var recovered = metadata

        if transcriptExists {
            recovered.processingState = .ready
            recovered.failureMessage = nil
            return recovered
        }

        switch recovered.processingState {
        case .recording, .saving, .transcribing:
            recovered.processingState = .failed
            recovered.failureMessage = audioExists
                ? interruptedMessage
                : interruptedWithoutAudioMessage
        case .legacy, .ready, .failed:
            break
        }
        return recovered
    }
}

enum SessionFileRelocation {
    static func movePreservingSource(
        from sourceURL: URL,
        to destinationURL: URL,
        fileExists: (URL) -> Bool,
        move: (URL, URL) throws -> Void
    ) throws -> URL {
        do {
            try move(sourceURL, destinationURL)
            return destinationURL
        } catch {
            if fileExists(sourceURL) {
                return sourceURL
            }
            throw error
        }
    }
}

#if DEBUG
enum RecordingReliabilityTestSupport {
    private static func sampleMetadata(
        state: SessionProcessingState = .recording
    ) -> SessionMetadataV1 {
        SessionMetadataV1(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            title: "Reliability",
            startTime: Date(timeIntervalSince1970: 1_786_300_000),
            durationSeconds: 41.875,
            systemAudioFilename: "system.m4a",
            microphoneAudioFilename: "microphone.m4a",
            transcriptFilename: "transcript.md",
            selectedModel: "Parakeet V2",
            processingState: state,
            failureMessage: nil,
            flags: [4.5],
            notes: [SessionNoteMetadata(timestamp: 8.25, text: "Original offset")]
        )
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CounterfoilReliabilityTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func metadataRoundTripUsesTemporaryStorage() -> Bool {
        guard let root = try? temporaryRoot() else { return false }
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.json")
        let expected = sampleMetadata(state: .transcribing)
        do {
            try SessionMetadataIO.write(expected, to: url)
            let decoded = try SessionMetadataIO.read(from: url)
            return decoded == expected
                && FileManager.default.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }

    static func crashRecoveryMatrixPasses() -> Bool {
        for state in [SessionProcessingState.recording, .saving, .transcribing] {
            let withAudio = SessionCrashRecovery.recovered(
                metadata: sampleMetadata(state: state),
                transcriptExists: false,
                audioExists: true
            )
            guard withAudio.processingState == .failed,
                  withAudio.failureMessage == SessionCrashRecovery.interruptedMessage else {
                return false
            }

            let withoutAudio = SessionCrashRecovery.recovered(
                metadata: sampleMetadata(state: state),
                transcriptExists: false,
                audioExists: false
            )
            guard withoutAudio.processingState == .failed,
                  withoutAudio.failureMessage == SessionCrashRecovery.interruptedWithoutAudioMessage else {
                return false
            }
        }

        let transcriptWonRace = SessionCrashRecovery.recovered(
            metadata: sampleMetadata(state: .transcribing),
            transcriptExists: true,
            audioExists: true
        )
        return transcriptWonRace.processingState == .ready
            && transcriptWonRace.failureMessage == nil
    }

    static func renameFallbackPreservesSource() -> Bool {
        guard let root = try? temporaryRoot() else { return false }
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        let destination = root.appendingPathComponent("destination.m4a")
        let bytes = Data([0x43, 0x46, 0x4f, 0x49, 0x4c])
        do {
            try bytes.write(to: source)
            let result = try SessionFileRelocation.movePreservingSource(
                from: source,
                to: destination,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                move: { _, _ in
                    throw NSError(domain: "RenameFailure", code: 1)
                }
            )
            let preservedBytes = try Data(contentsOf: source)
            return result == source && preservedBytes == bytes
        } catch {
            return false
        }
    }

    static func successfulRenameMovesSource() -> Bool {
        guard let root = try? temporaryRoot() else { return false }
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        let destination = root.appendingPathComponent("destination.m4a")
        do {
            try Data([0x01]).write(to: source)
            let result = try SessionFileRelocation.movePreservingSource(
                from: source,
                to: destination,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                move: { try FileManager.default.moveItem(at: $0, to: $1) }
            )
            return result == destination
                && FileManager.default.fileExists(atPath: destination.path)
                && !FileManager.default.fileExists(atPath: source.path)
        } catch {
            return false
        }
    }

    static func missingSourcePropagatesRenameFailure() -> Bool {
        guard let root = try? temporaryRoot() else { return false }
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("missing.m4a")
        let destination = root.appendingPathComponent("destination.m4a")
        do {
            _ = try SessionFileRelocation.movePreservingSource(
                from: source,
                to: destination,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                move: { _, _ in
                    throw NSError(domain: "RenameFailure", code: 2)
                }
            )
            return false
        } catch {
            return true
        }
    }

    static func capacityAndNoteBoundariesPass() -> Bool {
        let minimum = RecordingCapacityPolicy.minimumRecommendedBytes
        return RecordingCapacityPolicy.requiresConfirmation(availableBytes: minimum - 1)
            && !RecordingCapacityPolicy.requiresConfirmation(availableBytes: minimum)
            && !RecordingCapacityPolicy.requiresConfirmation(availableBytes: nil)
            && RecordingNoteTiming.capturedOffset(-3) == 0
            && RecordingNoteTiming.capturedOffset(7.75) == 7.75
    }

    static func recoveryActionsCoverFailureMatrix() -> Bool {
        let permission = RecordingRecoveryPolicy.actions(for: RecordingFailure(
            stage: .preparing,
            message: "Permission denied",
            recoverySuggestion: "Review access",
            audioPreserved: false
        ))
        let microphone = RecordingRecoveryPolicy.actions(for: RecordingFailure(
            stage: .resuming,
            message: "Microphone failed",
            recoverySuggestion: "Save audio",
            audioPreserved: true
        ))
        let writer = RecordingRecoveryPolicy.actions(for: RecordingFailure(
            stage: .saving,
            message: "Writer failed",
            recoverySuggestion: "Reveal audio",
            audioPreserved: true
        ))
        let transcription = RecordingRecoveryPolicy.actions(for: RecordingFailure(
            stage: .transcribing,
            message: "Transcription failed",
            recoverySuggestion: "Retry",
            audioPreserved: true
        ))

        return permission.contains(.retryPreparation)
            && permission.contains(.copyDiagnostics)
            && microphone.contains(.saveCapturedAudio)
            && microphone.contains(.revealAudio)
            && writer.contains(.revealAudio)
            && writer.contains(.copyDiagnostics)
            && transcription.contains(.retryTranscription)
            && transcription.contains(.changeModel)
    }
    static func segmentTimelineMetadataPasses() -> Bool {
        var metadata = sampleMetadata(state: .recording)
        let start = Date(timeIntervalSince1970: 1_786_300_000)
        let systemStart = start.addingTimeInterval(0.035)
        let microphoneStart = start.addingTimeInterval(0.010)
        let synchronized = max(systemStart, microphoneStart)
        let system = AudioSegmentTimeline.alignedSegment(
            filename: "system.1.m4a",
            baseOffset: 12.5,
            channelStartedAt: systemStart,
            synchronizedStart: synchronized
        )
        let microphone = AudioSegmentTimeline.alignedSegment(
            filename: "microphone.1.m4a",
            baseOffset: 12.5,
            channelStartedAt: microphoneStart,
            synchronizedStart: synchronized
        )
        metadata.systemSegments = [AudioSegmentTimeline.closed(system, at: 20)]
        metadata.microphoneSegments = [AudioSegmentTimeline.closed(microphone, at: 20)]
        guard let root = try? temporaryRoot() else { return false }
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("segments.json")
        do {
            try SessionMetadataIO.write(metadata, to: url)
            let decoded = try SessionMetadataIO.read(from: url)
            guard decoded.systemSegments == metadata.systemSegments,
                  decoded.microphoneSegments == metadata.microphoneSegments,
                  decoded.effectiveSystemSegments.first?.duration == 7.5,
                  abs((decoded.effectiveMicrophoneSegments.first?.effectiveTrimStart ?? 0) - 0.025) < 0.001 else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

}
#endif
