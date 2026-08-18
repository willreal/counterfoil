import Foundation
import ScreenCaptureKit
import AVFoundation
import SwiftUI
import Combine
import AppKit

private final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "com.willchai.counterfoil.system-audio", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var started = false
    private var failureMessage: String?

    func start(to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(
                domain: "CounterfoilCapture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No display is available for system audio capture."]
            )
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "CounterfoilCapture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The recording destination already exists."]
            )
        }

        let newWriter = try AVAssetWriter(url: url, fileType: .m4a)
        let newInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        guard newWriter.canAdd(newInput) else {
            throw NSError(
                domain: "CounterfoilCapture",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The system audio writer could not be configured."]
            )
        }
        newWriter.add(newInput)

        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.width)
        configuration.height = Int(display.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        sampleQueue.sync {
            writer = newWriter
            writerInput = newInput
            stream = newStream
            started = false
            failureMessage = nil
        }

        do {
            try await newStream.startCapture()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let snapshot = sampleQueue.sync { (started, failureMessage) }
                if let message = snapshot.1 {
                    throw NSError(
                        domain: "CounterfoilCapture",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
                if snapshot.0 { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw NSError(
                domain: "CounterfoilCapture",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "System audio did not begin within ten seconds."]
            )
        } catch {
            await abort()
            throw error
        }
    }

    func stop() async throws {
        let currentStream = sampleQueue.sync { stream }
        if let currentStream {
            try await currentStream.stopCapture()
        }

        let state: (AVAssetWriter?, String?) = sampleQueue.sync {
            writerInput?.markAsFinished()
            let currentWriter = writer
            let currentFailure = failureMessage
            writer = nil
            writerInput = nil
            stream = nil
            started = false
            failureMessage = nil
            return (currentWriter, currentFailure)
        }

        if let message = state.1 {
            throw NSError(
                domain: "CounterfoilCapture",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        guard let currentWriter = state.0 else { return }
        if currentWriter.status == .writing {
            await withCheckedContinuation { continuation in
                currentWriter.finishWriting { continuation.resume() }
            }
        }
        if currentWriter.status == .failed {
            throw currentWriter.error ?? NSError(
                domain: "CounterfoilCapture",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "The system audio file could not be finalized."]
            )
        }
    }

    func abort() async {
        let currentStream = sampleQueue.sync { stream }
        if let currentStream {
            try? await currentStream.stopCapture()
        }
        let currentWriter: AVAssetWriter? = sampleQueue.sync {
            writerInput?.markAsFinished()
            let value = writer
            writer = nil
            writerInput = nil
            stream = nil
            started = false
            failureMessage = nil
            return value
        }
        if let currentWriter, currentWriter.status == .writing {
            await withCheckedContinuation { continuation in
                currentWriter.finishWriting { continuation.resume() }
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, let writer, let writerInput else { return }

        if writer.status == .unknown {
            guard writer.startWriting() else {
                failureMessage = writer.error?.localizedDescription ?? "System audio writing could not start."
                started = true
                return
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }

        if writer.status == .writing, writerInput.isReadyForMoreMediaData {
            if !writerInput.append(sampleBuffer) {
                failureMessage = writer.error?.localizedDescription ?? "A system audio sample could not be written."
            }
        }
    }
}

private final class MicrophoneCapture: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?

    func start(to url: URL) throws {
        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw NSError(
                domain: "CounterfoilCapture",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "The microphone audio format is unavailable."]
            )
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "CounterfoilCapture",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "The microphone recording destination already exists."]
            )
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        let newFile = try AVAudioFile(forWriting: url, settings: settings)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            try? newFile.write(from: buffer)
        }
        newEngine.prepare()
        try newEngine.start()
        engine = newEngine
        file = newFile
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        file = nil
    }
}

private enum AudioFinalizer {
    static func merge(_ sourceURLs: [URL], to destinationURL: URL) async throws -> URL? {
        guard !sourceURLs.isEmpty else { return nil }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw NSError(
                domain: "CounterfoilCapture",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "The finalized audio destination already exists."]
            )
        }

        if sourceURLs.count == 1 {
            return try SessionFileRelocation.movePreservingSource(
                from: sourceURLs[0],
                to: destinationURL,
                fileExists: { fileManager.fileExists(atPath: $0.path) },
                move: { try fileManager.moveItem(at: $0, to: $1) }
            )
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(
                domain: "CounterfoilCapture",
                code: 31,
                userInfo: [NSLocalizedDescriptionKey: "The audio segments could not be combined."]
            )
        }

        var insertionTime = CMTime.zero
        for sourceURL in sourceURLs {
            let asset = AVURLAsset(url: sourceURL)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0 else { continue }
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: track,
                at: insertionTime
            )
            insertionTime = insertionTime + duration
        }

        guard insertionTime.seconds > 0,
              let exporter = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetAppleM4A
              ) else {
            throw NSError(
                domain: "CounterfoilCapture",
                code: 32,
                userInfo: [NSLocalizedDescriptionKey: "The combined audio export could not be created."]
            )
        }

        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).m4a")
        try await exporter.export(to: temporaryURL, as: .m4a)
        let completedURL: URL
        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            completedURL = destinationURL
        } catch {
            guard fileManager.fileExists(atPath: temporaryURL.path) else { throw error }
            completedURL = temporaryURL
        }

        for sourceURL in sourceURLs where sourceURL != completedURL {
            try? fileManager.removeItem(at: sourceURL)
        }
        return completedURL
    }

    static func duration(of urls: [URL]) async -> TimeInterval {
        var best: TimeInterval = 0
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            if let value = try? await asset.load(.duration), value.isNumeric {
                best = max(best, value.seconds)
            }
        }
        return max(0, best)
    }
}

@MainActor
final class CaptureManager: ObservableObject {
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var systemAudioState: ChannelCaptureState = .unavailable
    @Published private(set) var microphoneState: ChannelCaptureState = .unavailable
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var recordingStartTime: Date?
    @Published private(set) var activeTitle = ""
    @Published private(set) var lastFlagMessage: String?
    @Published var showLowDiskAlert = false

    private let systemCapture = SystemAudioCapture()
    private let microphoneCapture = MicrophoneCapture()
    private var durationTimer: AnyCancellable?
    private var activityToken: NSObjectProtocol?

    private var sessionID: UUID?
    private var sessionRequestedAt: Date?
    private var sessionTitle = ""
    private var sessionDir: URL?
    private var metadataURL: URL?
    private var metadata: SessionMetadataV1?
    private var systemSegments: [URL] = []
    private var microphoneSegments: [URL] = []
    private var segmentOffsets: [TimeInterval] = []
    private var systemCaptureRunning = false
    private var microphoneCaptureRunning = false
    private var pauseStartTime: Date?
    private var totalPausedDuration: TimeInterval = 0
    private var pendingLowDiskTitle: String?
    private var pendingNoteOffset: TimeInterval?
    private(set) var flaggedOffsets: [TimeInterval] = []
    private(set) var notes: [(TimeInterval, String)] = []

    static let hasMic: Bool = AVCaptureDevice.default(for: .audio) != nil

    nonisolated static let baseDir: URL = {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Counterfoil", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    var isRecording: Bool { phase.isRecordingSession }
    var isPaused: Bool { phase.isPaused }
    var status: String { phase.statusText }
    var flagCount: Int { flaggedOffsets.count }
    var noteCount: Int { notes.count }
    var noteTimestamp: TimeInterval? { pendingNoteOffset }

#if DEBUG
    func configureDeterministicPreview(
        phase: RecordingPhase = .recording,
        title: String = "Untitled meeting",
        duration: TimeInterval = 102,
        flagCount: Int = 0,
        notes: [String] = []
    ) {
        self.phase = phase
        activeTitle = title
        sessionTitle = title
        recordingDuration = duration
        recordingStartTime = Date().addingTimeInterval(-duration)
        systemAudioState = .active
        microphoneState = .active
        flaggedOffsets = (0..<flagCount).map { TimeInterval($0 + 1) }
        self.notes = notes.enumerated().map { (TimeInterval($0.offset + 1), $0.element) }
    }

    func transitionDeterministicPreview(to phase: RecordingPhase) {
        self.phase = phase
    }

    func setDeterministicChannelStates(
        system: ChannelCaptureState,
        microphone: ChannelCaptureState
    ) {
        systemAudioState = system
        microphoneState = microphone
    }
#endif

    static func dayDir(date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = baseDir.appendingPathComponent(
            formatter.string(from: date),
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func sanitizeTitle(_ title: String) -> String {
        SessionNaming.sanitizedTitle(title)
    }

    func currentElapsedTime() -> TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        var elapsed = Date().timeIntervalSince(start) - totalPausedDuration
        if phase.isPaused, let pauseStartTime {
            elapsed -= Date().timeIntervalSince(pauseStartTime)
        }
        return max(0, elapsed)
    }

    func start(title: String? = nil) {
        guard RecordingTransition.allows(.start, from: phase) else { return }
        let requestedAt = Date()
        let displayTitle = SessionNaming.sanitizedTitle(title ?? SessionNaming.defaultTitle(at: requestedAt))

        phase = .preparing
        activeTitle = displayTitle
        sessionTitle = displayTitle
        sessionRequestedAt = requestedAt
        recordingDuration = 0
        recordingStartTime = nil
        systemAudioState = .preparing
        microphoneState = Self.hasMic ? .preparing : .unavailable
        lastFlagMessage = nil
        flaggedOffsets = []
        notes = []
        pendingNoteOffset = nil
        totalPausedDuration = 0
        pauseStartTime = nil
        systemSegments = []
        microphoneSegments = []
        segmentOffsets = []

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let availableCapacity = try? documentsURL
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if RecordingCapacityPolicy.requiresConfirmation(availableBytes: availableCapacity) {
            pendingLowDiskTitle = displayTitle
            showLowDiskAlert = true
            return
        }

        beginPreparedSession(title: displayTitle, requestedAt: requestedAt)
    }

    func confirmLowDiskStart() {
        guard phase == .preparing,
              let pendingLowDiskTitle,
              let requestedAt = sessionRequestedAt else { return }
        self.pendingLowDiskTitle = nil
        beginPreparedSession(title: pendingLowDiskTitle, requestedAt: requestedAt)
    }

    func cancelLowDiskStart() {
        showLowDiskAlert = false
        pendingLowDiskTitle = nil
        resetSession(phase: .idle)
    }

    private func beginPreparedSession(title: String, requestedAt: Date) {
        let id = UUID()
        let directory = Self.dayDir(date: requestedAt)
        let baseName = SessionNaming.baseName(title: title, startTime: requestedAt, id: id)
        let firstSystemURL = directory.appendingPathComponent("\(baseName).system.1.m4a")
        let firstMicURL = directory.appendingPathComponent("\(baseName).microphone.1.m4a")
        let initialMetadataURL = directory.appendingPathComponent("\(baseName).json")

        sessionID = id
        sessionDir = directory
        metadataURL = initialMetadataURL
        systemSegments = [firstSystemURL]
        microphoneSegments = Self.hasMic ? [firstMicURL] : []
        segmentOffsets = [0]
        metadata = SessionMetadataV1(
            id: id,
            title: title,
            startTime: requestedAt,
            durationSeconds: 0,
            systemAudioFilename: firstSystemURL.lastPathComponent,
            microphoneAudioFilename: Self.hasMic ? firstMicURL.lastPathComponent : nil,
            transcriptFilename: "\(baseName).md",
            selectedModel: SettingsStore.shared.selectedModel,
            processingState: .recording,
            failureMessage: nil,
            flags: [],
            notes: []
        )

        do {
            try persistMetadata()
        } catch {
            fail(
                stage: .preparing,
                error: error,
                suggestion: "Check that the Counterfoil folder is writable, then try again.",
                audioPreserved: false
            )
            return
        }

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "Recording meeting"
        )

        Task { await startHardware() }
    }

    private func startHardware() async {
        guard phase == .preparing,
              let systemURL = systemSegments.first else { return }
        do {
            try await systemCapture.start(to: systemURL)
            systemCaptureRunning = true
            systemAudioState = .active

            if Self.hasMic, let microphoneURL = microphoneSegments.first {
                do {
                    try microphoneCapture.start(to: microphoneURL)
                    microphoneCaptureRunning = true
                    microphoneState = .active
                } catch {
                    microphoneState = .failed(error.localizedDescription)
                    await systemCapture.abort()
                    systemCaptureRunning = false
                    throw error
                }
            }

            let actualStart = Date()
            recordingStartTime = actualStart
            metadata?.startTime = actualStart
            try persistMetadata()
            phase = .recording
            startDurationTimer()
            CounterfoilSound.play("Pop")
        } catch {
            endActivityToken()
            fail(
                stage: .preparing,
                error: error,
                suggestion: "Review microphone and screen recording access, then try again.",
                audioPreserved: hasRecordedAudio
            )
        }
    }

    func pauseCapture() {
        guard RecordingTransition.allows(.pause, from: phase) else { return }
        phase = .pausing
        pauseStartTime = Date()
        Task {
            do {
                try await stopActiveCaptures()
                phase = .paused
                systemAudioState = .silent
                if Self.hasMic { microphoneState = .silent }
            } catch {
                fail(
                    stage: .pausing,
                    error: error,
                    suggestion: "Stop the recording to preserve the audio captured so far.",
                    audioPreserved: true
                )
            }
        }
    }

    func resumeCapture() {
        guard RecordingTransition.allows(.resume, from: phase),
              let directory = sessionDir,
              let id = sessionID,
              let requestedAt = sessionRequestedAt else { return }

        if let pauseStartTime {
            totalPausedDuration += Date().timeIntervalSince(pauseStartTime)
        }
        self.pauseStartTime = nil
        let offset = currentElapsedTime()
        let index = systemSegments.count + 1
        let baseName = SessionNaming.baseName(title: sessionTitle, startTime: requestedAt, id: id)
        let systemURL = directory.appendingPathComponent("\(baseName).system.\(index).m4a")
        let microphoneURL = directory.appendingPathComponent("\(baseName).microphone.\(index).m4a")
        systemSegments.append(systemURL)
        segmentOffsets.append(offset)
        if Self.hasMic { microphoneSegments.append(microphoneURL) }

        phase = .resuming
        systemAudioState = .preparing
        if Self.hasMic { microphoneState = .preparing }

        Task {
            do {
                try await systemCapture.start(to: systemURL)
                systemCaptureRunning = true
                systemAudioState = .active
                if Self.hasMic {
                    try microphoneCapture.start(to: microphoneURL)
                    microphoneCaptureRunning = true
                    microphoneState = .active
                }
                phase = .recording
            } catch {
                await systemCapture.abort()
                systemCaptureRunning = false
                microphoneCapture.stop()
                microphoneCaptureRunning = false
                fail(
                    stage: .resuming,
                    error: error,
                    suggestion: "Stop the recording to preserve the completed segments.",
                    audioPreserved: true
                )
            }
        }
    }

    func flagCurrentMoment() {
        guard phase == .recording || phase == .paused else { return }
        let timestamp = currentElapsedTime()
        if let last = flaggedOffsets.last, abs(last - timestamp) < 0.5 { return }
        flaggedOffsets.append(timestamp)
        lastFlagMessage = "Flagged at \(formatRecordingClock(timestamp))"
        metadata?.flags = flaggedOffsets
        try? persistMetadata()
        CounterfoilSound.play("Tink")
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if lastFlagMessage == "Flagged at \(formatRecordingClock(timestamp))" {
                lastFlagMessage = nil
            }
        }
    }

    func beginNote() -> TimeInterval {
        let timestamp = RecordingNoteTiming.capturedOffset(currentElapsedTime())
        pendingNoteOffset = timestamp
        return timestamp
    }

    func cancelPendingNote() {
        pendingNoteOffset = nil
    }

    func addNote(_ text: String, at timestamp: TimeInterval? = nil) {
        guard phase.isRecordingSession else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let resolvedTimestamp = RecordingNoteTiming.capturedOffset(
            timestamp ?? pendingNoteOffset ?? currentElapsedTime()
        )
        notes.append((resolvedTimestamp, trimmed))
        pendingNoteOffset = nil
        metadata?.notes = notes.map { SessionNoteMetadata(timestamp: $0.0, text: $0.1) }
        try? persistMetadata()
    }

    func updateActiveTitle(_ title: String) {
        guard phase.isRecordingSession else { return }
        let value = SessionNaming.sanitizedTitle(title)
        sessionTitle = value
        activeTitle = value
        metadata?.title = value
        try? persistMetadata()
    }

    func stop(store: TranscriptStore) {
        guard RecordingTransition.allows(.stop, from: phase) else { return }
        phase = .saving
        durationTimer?.cancel()
        durationTimer = nil
        CounterfoilSound.play("Tink")
        Task { await finalizeAndTranscribe(store: store) }
    }

    private func finalizeAndTranscribe(store: TranscriptStore) async {
        guard let id = sessionID,
              let directory = sessionDir,
              let startTime = recordingStartTime ?? sessionRequestedAt else {
            fail(
                stage: .saving,
                message: "The active recording identity is missing.",
                suggestion: "Reveal the Counterfoil folder and preserve any audio segments.",
                audioPreserved: hasRecordedAudio
            )
            return
        }

        do {
            try await stopActiveCaptures()
            endActivityToken()

            let finalBaseName = SessionNaming.baseName(title: sessionTitle, startTime: startTime, id: id)
            let requestedSystemURL = directory.appendingPathComponent("\(finalBaseName).m4a")
            let requestedMicrophoneURL = Self.hasMic
                ? directory.appendingPathComponent("\(finalBaseName).mic.m4a")
                : nil

            guard let finalSystemURL = try await AudioFinalizer.merge(
                systemSegments,
                to: requestedSystemURL
            ) else {
                throw NSError(
                    domain: "CounterfoilCapture",
                    code: 40,
                    userInfo: [NSLocalizedDescriptionKey: "The system audio file is unavailable."]
                )
            }
            var finalMicrophoneURL: URL?
            if let requestedMicrophoneURL, !microphoneSegments.isEmpty {
                finalMicrophoneURL = try await AudioFinalizer.merge(
                    microphoneSegments,
                    to: requestedMicrophoneURL
                )
            }

            let duration = await AudioFinalizer.duration(
                of: [finalSystemURL, finalMicrophoneURL].compactMap { $0 }
            )
            let finalMetadataURL = directory.appendingPathComponent("\(finalBaseName).json")
            let oldMetadataURL = metadataURL
            metadata = SessionMetadataV1(
                id: id,
                title: sessionTitle,
                startTime: startTime,
                durationSeconds: duration,
                systemAudioFilename: finalSystemURL.lastPathComponent,
                microphoneAudioFilename: finalMicrophoneURL?.lastPathComponent,
                transcriptFilename: "\(finalBaseName).md",
                selectedModel: SettingsStore.shared.selectedModel,
                processingState: .transcribing,
                failureMessage: nil,
                flags: flaggedOffsets,
                notes: notes.map { SessionNoteMetadata(timestamp: $0.0, text: $0.1) }
            )
            metadataURL = finalMetadataURL
            try persistMetadata()
            if let oldMetadataURL, oldMetadataURL != finalMetadataURL {
                try? FileManager.default.removeItem(at: oldMetadataURL)
            }

            guard let finalizedMetadata = metadata else { return }
            store.beginProcessingSession(metadata: finalizedMetadata, dayDir: directory)
            phase = .transcribing
            resetCaptureResourcesForProcessing()

            do {
                let systemText = try await Transcriber.shared.transcribe(
                    filePath: finalSystemURL.path,
                    baseOffset: 0
                )
                var microphoneText = ""
                if let finalMicrophoneURL,
                   FileManager.default.fileExists(atPath: finalMicrophoneURL.path) {
                    microphoneText = try await Transcriber.shared.transcribe(
                        filePath: finalMicrophoneURL.path,
                        baseOffset: 0
                    )
                }
                try store.completeProcessingSession(
                    metadata: finalizedMetadata,
                    dayDir: directory,
                    systemText: systemText,
                    microphoneText: microphoneText
                )
                phase = .complete(sessionID: id.uuidString.lowercased())
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if case .complete = phase { phase = .idle }
                }
            } catch {
                store.failProcessingSession(
                    metadata: finalizedMetadata,
                    dayDir: directory,
                    message: error.localizedDescription
                )
                phase = .failed(RecordingFailure(
                    stage: .transcribing,
                    message: error.localizedDescription,
                    recoverySuggestion: "Retry transcription or choose another installed model.",
                    audioPreserved: true
                ))
            }
        } catch {
            endActivityToken()
            fail(
                stage: .saving,
                error: error,
                suggestion: "Reveal the Counterfoil folder and preserve the recorded segments.",
                audioPreserved: hasRecordedAudio
            )
        }
    }

    func retryAfterFailure() {
        guard RecordingTransition.allows(.retry, from: phase),
              case .failed(let failure) = phase else { return }
        if failure.stage == .preparing {
            let title = activeTitle
            discardEmptyPreparationFiles()
            resetSession(phase: .idle)
            start(title: title)
        }
    }

    func saveCapturedAudioAfterFailure(store: TranscriptStore) {
        guard case .failed(let failure) = phase,
              failure.audioPreserved,
              failure.stage == .pausing || failure.stage == .resuming else { return }
        phase = .saving
        durationTimer?.cancel()
        durationTimer = nil
        Task { await finalizeAndTranscribe(store: store) }
    }

    func dismissFailure() {
        guard case .failed = phase else { return }
        endActivityToken()
        resetSession(phase: .idle)
    }

    func revealCurrentFiles() {
        let urls = (systemSegments + microphoneSegments + [metadataURL].compactMap { $0 })
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func copyFailureDiagnostics() {
        let filePaths = (systemSegments + microphoneSegments + [metadataURL].compactMap { $0 })
            .map(\.path)
            .joined(separator: "\n")
        let phaseDescription: String
        if case .failed(let failure) = phase {
            phaseDescription = "\(failure.stage.rawValue): \(failure.message)"
        } else {
            phaseDescription = phase.statusText
        }
        let diagnostics = [
            "Counterfoil recording diagnostics",
            "Phase: \(phaseDescription)",
            "Session: \(sessionID?.uuidString.lowercased() ?? "Unavailable")",
            "Title: \(sessionTitle)",
            "System audio: \(systemAudioState.label)",
            "Microphone: \(microphoneState.label)",
            "Elapsed seconds: \(currentElapsedTime())",
            "Files:",
            filePaths.isEmpty ? "Unavailable" : filePaths,
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }

    private func startDurationTimer() {
        durationTimer?.cancel()
        durationTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.phase == .recording else { return }
                self.recordingDuration = self.currentElapsedTime()
            }
    }

    private func stopActiveCaptures() async throws {
        var systemError: Error?
        if systemCaptureRunning {
            do {
                try await systemCapture.stop()
            } catch {
                systemError = error
            }
            systemCaptureRunning = false
        }
        if microphoneCaptureRunning {
            microphoneCapture.stop()
            microphoneCaptureRunning = false
        }
        if let systemError { throw systemError }
    }

    private func persistMetadata() throws {
        guard let metadata, let metadataURL else { return }
        try SessionMetadataIO.write(metadata, to: metadataURL)
    }

    private var hasRecordedAudio: Bool {
        (systemSegments + microphoneSegments).contains {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: $0.path),
                  let size = attributes[.size] as? NSNumber else { return false }
            return size.int64Value > 0
        }
    }

    private func fail(
        stage: RecordingFailureStage,
        error: Error,
        suggestion: String,
        audioPreserved: Bool
    ) {
        fail(
            stage: stage,
            message: error.localizedDescription,
            suggestion: suggestion,
            audioPreserved: audioPreserved
        )
    }

    private func fail(
        stage: RecordingFailureStage,
        message: String,
        suggestion: String,
        audioPreserved: Bool
    ) {
        systemAudioState = .failed(message)
        if Self.hasMic, microphoneState == .preparing {
            microphoneState = .failed(message)
        }
        metadata?.processingState = .failed
        metadata?.failureMessage = message
        try? persistMetadata()
        phase = .failed(RecordingFailure(
            stage: stage,
            message: message,
            recoverySuggestion: suggestion,
            audioPreserved: audioPreserved
        ))
    }

    private func resetCaptureResourcesForProcessing() {
        durationTimer?.cancel()
        durationTimer = nil
        recordingDuration = 0
        recordingStartTime = nil
        activeTitle = ""
        sessionTitle = ""
        systemAudioState = .unavailable
        microphoneState = .unavailable
        systemSegments = []
        microphoneSegments = []
        segmentOffsets = []
        flaggedOffsets = []
        notes = []
        pendingNoteOffset = nil
        totalPausedDuration = 0
        pauseStartTime = nil
        sessionID = nil
        sessionDir = nil
        metadataURL = nil
        metadata = nil
    }

    private func resetSession(phase newPhase: RecordingPhase) {
        resetCaptureResourcesForProcessing()
        sessionRequestedAt = nil
        systemCaptureRunning = false
        microphoneCaptureRunning = false
        phase = newPhase
    }

    private func discardEmptyPreparationFiles() {
        for url in systemSegments + microphoneSegments + [metadataURL].compactMap({ $0 }) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value == 0 || url.pathExtension == "json" else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func endActivityToken() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }
}

private enum CounterfoilSound {
    static func play(_ name: String) {
        let path = "/System/Library/Sounds/\(name).aiff"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
