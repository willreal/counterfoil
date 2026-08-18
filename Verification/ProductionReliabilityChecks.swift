import Foundation
import AVFoundation

@main
@MainActor
struct ProductionReliabilityChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CounterfoilProductionChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let stem = "audit-session"
        var metadata = SessionMetadataV1(
            id: id,
            title: "Original title",
            startTime: Date(timeIntervalSince1970: 1_786_300_000),
            durationSeconds: 30,
            systemAudioFilename: nil,
            microphoneAudioFilename: nil,
            transcriptFilename: "\(stem).md",
            selectedModel: "Parakeet V2",
            processingState: .transcribing,
            failureMessage: nil,
            flags: [],
            notes: []
        )
        let metadataURL = root.appendingPathComponent("\(stem).json")
        try SessionMetadataIO.write(metadata, to: metadataURL)

        let store = TranscriptStore()
        let session = Session(
            id: id.uuidString.lowercased(),
            stem: stem,
            title: metadata.title,
            startTime: metadata.startTime,
            duration: metadata.durationSeconds,
            hasSystemFile: false,
            hasMicFile: false,
            hasTranscript: false,
            dayDir: root.path,
            processingState: .transcribing,
            transcriptFilename: metadata.transcriptFilename,
            metadataFilename: metadataURL.lastPathComponent
        )
        store.sessions = [session]
        store.renameSession(session, to: "Renamed while transcribing")

        try store.completeProcessingSession(
            metadata: metadata,
            dayDir: root,
            systemText: "[00:00:00] meeting words",
            microphoneText: "[00:00:01] my words"
        )
        let transcript = try String(contentsOf: root.appendingPathComponent(metadata.transcriptFilename), encoding: .utf8)
        precondition(transcript.hasPrefix("# Renamed while transcribing"), "stale completion overwrote renamed title")
        let persisted = try SessionMetadataIO.read(from: metadataURL)
        precondition(persisted.title == "Renamed while transcribing", "metadata rename did not survive completion")

        let failedID = UUID()
        let failedStem = "audit-failed-session"
        let staleFailedMetadata = SessionMetadataV1(
            id: failedID,
            title: "Original failed title",
            startTime: metadata.startTime,
            durationSeconds: 12,
            systemAudioFilename: nil,
            microphoneAudioFilename: nil,
            transcriptFilename: "\(failedStem).md",
            selectedModel: "Parakeet V2",
            processingState: .transcribing,
            failureMessage: nil,
            flags: [],
            notes: []
        )
        let failedMetadataURL = root.appendingPathComponent("\(failedStem).json")
        try SessionMetadataIO.write(staleFailedMetadata, to: failedMetadataURL)
        let failedSession = Session(
            id: failedID.uuidString.lowercased(),
            stem: failedStem,
            title: staleFailedMetadata.title,
            startTime: staleFailedMetadata.startTime,
            duration: staleFailedMetadata.durationSeconds,
            hasSystemFile: false,
            hasMicFile: false,
            hasTranscript: false,
            dayDir: root.path,
            processingState: .transcribing,
            transcriptFilename: staleFailedMetadata.transcriptFilename,
            metadataFilename: failedMetadataURL.lastPathComponent
        )
        store.sessions.append(failedSession)
        store.renameSession(failedSession, to: "Renamed before failure")
        store.failProcessingSession(
            metadata: staleFailedMetadata,
            dayDir: root,
            message: "Synthetic failure"
        )
        let persistedFailure = try SessionMetadataIO.read(from: failedMetadataURL)
        precondition(persistedFailure.title == "Renamed before failure", "failure restored a stale meeting title")

        metadata.systemSegments = [
            SessionAudioSegmentMetadata(filename: "one.m4a", offset: 0, trimStart: 0.02, duration: 5),
            SessionAudioSegmentMetadata(filename: "two.m4a", offset: 5, trimStart: 0.01, duration: 4),
        ]
        try SessionMetadataIO.write(metadata, to: metadataURL)
        let segmented = try SessionMetadataIO.read(from: metadataURL)
        precondition(segmented.effectiveSystemSegments.count == 2, "segment manifest was not persisted")
        precondition(segmented.allAudioFilenames.contains("two.m4a"), "segment files missing from recovery manifest")

        func writeSilence(to url: URL, seconds: Double) throws {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
                preconditionFailure("Unable to create test audio format")
            }
            let frameCount = AVAudioFrameCount(48_000 * seconds)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                preconditionFailure("Unable to create test audio buffer")
            }
            buffer.frameLength = frameCount
            if let channels = buffer.floatChannelData {
                for index in 0..<Int(frameCount) { channels[0][index] = 0 }
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let segmentOneURL = root.appendingPathComponent("timeline-one.wav")
        let segmentTwoURL = root.appendingPathComponent("timeline-two.wav")
        try writeSilence(to: segmentOneURL, seconds: 0.35)
        try writeSilence(to: segmentTwoURL, seconds: 0.35)
        let timelineOutput = root.appendingPathComponent("timeline-output.m4a")
        let timelineSegments = [
            AudioSegmentInput(
                url: segmentOneURL,
                metadata: SessionAudioSegmentMetadata(filename: segmentOneURL.lastPathComponent, offset: 0, trimStart: 0.05, duration: 0.20)
            ),
            AudioSegmentInput(
                url: segmentTwoURL,
                metadata: SessionAudioSegmentMetadata(filename: segmentTwoURL.lastPathComponent, offset: 0.40, trimStart: 0, duration: 0.20)
            ),
        ]
        guard let mergedTimeline = try await AudioFinalizer.merge(timelineSegments, to: timelineOutput) else {
            preconditionFailure("AudioFinalizer timeline export failed")
        }
        let timelineAsset = AVURLAsset(url: mergedTimeline)
        let timelineDuration = try await timelineAsset.load(.duration).seconds
        precondition(timelineDuration > 0.50 && timelineDuration < 0.80, "timeline offsets were not preserved")

        print("ProductionReliabilityChecks passed")
    }
}
