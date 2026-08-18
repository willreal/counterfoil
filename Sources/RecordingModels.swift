import Foundation

enum RecordingFailureStage: String, Codable, Equatable {
    case preparing
    case pausing
    case resuming
    case saving
    case transcribing
}

struct RecordingFailure: Error, Codable, Equatable, Identifiable {
    let stage: RecordingFailureStage
    let message: String
    let recoverySuggestion: String
    let audioPreserved: Bool

    var id: String { "\(stage.rawValue):\(message)" }
}

enum RecordingPhase: Equatable {
    case idle
    case preparing
    case recording
    case pausing
    case paused
    case resuming
    case saving
    case transcribing
    case complete(sessionID: String)
    case failed(RecordingFailure)

    var isRecordingSession: Bool {
        switch self {
        case .preparing, .recording, .pausing, .paused, .resuming, .saving:
            return true
        case .idle, .transcribing, .complete, .failed:
            return false
        }
    }

    var presentsRecordingPanel: Bool {
        switch self {
        case .preparing, .recording, .pausing, .paused, .resuming, .saving:
            return true
        case .failed(let failure):
            return failure.stage != .transcribing
        case .idle, .transcribing, .complete:
            return false
        }
    }

    var isPaused: Bool {
        switch self {
        case .paused, .pausing:
            return true
        default:
            return false
        }
    }

    var canPause: Bool { self == .recording }
    var canResume: Bool { self == .paused }

    var canStop: Bool {
        switch self {
        case .recording, .paused:
            return true
        default:
            return false
        }
    }

    var statusText: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Preparing audio"
        case .recording: return "Recording"
        case .pausing: return "Pausing"
        case .paused: return "Paused"
        case .resuming: return "Resuming"
        case .saving: return "Saving audio"
        case .transcribing: return "Transcribing locally"
        case .complete: return "Ready"
        case .failed: return "Recording problem"
        }
    }
}

enum ChannelCaptureState: Equatable {
    case unavailable
    case preparing
    case active
    case silent
    case failed(String)

    var label: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .preparing: return "Preparing"
        case .active: return "Capturing"
        case .silent: return "Silent"
        case .failed: return "Failed"
        }
    }

    var presentsWarning: Bool {
        switch self {
        case .unavailable, .failed:
            return true
        case .preparing, .active, .silent:
            return false
        }
    }
}

enum StopConfirmationState: Equatable {
    case idle
    case counting(Int)

    var isCounting: Bool {
        if case .counting = self { return true }
        return false
    }

    var remainingSeconds: Int? {
        guard case .counting(let value) = self else { return nil }
        return value
    }

    func toggled() -> StopConfirmationState {
        isCounting ? .idle : .counting(3)
    }

    func advanced() -> (state: StopConfirmationState, shouldStop: Bool) {
        guard case .counting(let value) = self else { return (.idle, false) }
        if value > 1 { return (.counting(value - 1), false) }
        return (.idle, true)
    }
}

enum SessionProcessingState: String, Codable, Equatable {
    case legacy
    case recording
    case saving
    case transcribing
    case ready
    case failed
}

struct SessionNoteMetadata: Codable, Equatable {
    let timestamp: TimeInterval
    let text: String
}

struct SessionMetadataV1: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    let id: UUID
    var title: String
    var startTime: Date
    var durationSeconds: TimeInterval
    var systemAudioFilename: String?
    var microphoneAudioFilename: String?
    var transcriptFilename: String
    var selectedModel: String
    var processingState: SessionProcessingState
    var failureMessage: String?
    var flags: [TimeInterval]
    var notes: [SessionNoteMetadata]

    var stem: String {
        URL(fileURLWithPath: transcriptFilename).deletingPathExtension().lastPathComponent
    }
}

enum SessionNaming {
    static let untitledTitle = "Untitled meeting"

    static func sanitizedTitle(_ title: String) -> String {
        var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for character in ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"] {
            value = value.replacingOccurrences(of: character, with: "")
        }
        value = value.replacingOccurrences(of: "\n", with: " ")
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }
        if value.count > 60 {
            value = String(value.prefix(60))
        }
        return value.isEmpty ? untitledTitle : value
    }

    static func baseName(title: String, startTime: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "\(sanitizedTitle(title)) \(formatter.string(from: startTime)) \(id.uuidString.lowercased())"
    }

    static func defaultTitle(at date: Date) -> String {
        untitledTitle
    }

    static func editorDraft(for storedTitle: String) -> String {
        storedTitle == untitledTitle ? "" : storedTitle
    }
}

enum RecordingTransition {
    static func allows(_ action: RecordingAction, from phase: RecordingPhase) -> Bool {
        switch action {
        case .start:
            if phase == .idle || isComplete(phase) { return true }
            if case .failed(let failure) = phase, failure.stage == .transcribing { return true }
            return false
        case .pause:
            return phase.canPause
        case .resume:
            return phase.canResume
        case .stop:
            return phase.canStop
        case .retry:
            if case .failed = phase { return true }
            return false
        }
    }

    private static func isComplete(_ phase: RecordingPhase) -> Bool {
        if case .complete = phase { return true }
        return false
    }
}

enum RecordingAction {
    case start
    case pause
    case resume
    case stop
    case retry
}

enum AudioRetentionChoice: String, Codable, Equatable {
    case keep
    case moveToTrashAfterThirtyDays

    var automaticallyDeletesAudio: Bool {
        self == .moveToTrashAfterThirtyDays
    }

    func shouldRemoveAudio(recordedAt: Date, now: Date) -> Bool {
        guard self == .moveToTrashAfterThirtyDays else { return false }
        return now.timeIntervalSince(recordedAt) >= 30 * 24 * 60 * 60
    }
}

func formatElapsedTimestamp(_ elapsed: TimeInterval) -> String {
    let totalSeconds = max(0, Int(elapsed))
    return String(
        format: "%02d:%02d:%02d",
        totalSeconds / 3600,
        (totalSeconds / 60) % 60,
        totalSeconds % 60
    )
}

#if DEBUG
enum RecordingCoreTestSupport {
    static func defaultTitleIsUntitledMeeting() -> Bool {
        SessionNaming.defaultTitle(at: Date(timeIntervalSince1970: 0)) == SessionNaming.untitledTitle
            && SessionNaming.sanitizedTitle("   ") == SessionNaming.untitledTitle
            && SessionNaming.editorDraft(for: SessionNaming.untitledTitle).isEmpty
    }

    static func stopConfirmationSequencePasses() -> Bool {
        var state = StopConfirmationState.idle.toggled()
        guard state == .counting(3) else { return false }
        state = state.toggled()
        guard state == .idle else { return false }
        state = state.toggled()
        let first = state.advanced()
        let second = first.state.advanced()
        let third = second.state.advanced()
        return first.state == .counting(2)
            && first.shouldStop == false
            && second.state == .counting(1)
            && second.shouldStop == false
            && third.state == .idle
            && third.shouldStop
    }

    static func channelWarningsAppearOnlyForProblems() -> Bool {
        ChannelCaptureState.unavailable.presentsWarning
            && ChannelCaptureState.failed("failure").presentsWarning
            && ChannelCaptureState.preparing.presentsWarning == false
            && ChannelCaptureState.active.presentsWarning == false
            && ChannelCaptureState.silent.presentsWarning == false
    }

    static func failureRoundTrips() -> Bool {
        let failure = RecordingFailure(
            stage: .saving,
            message: "Writer failed",
            recoverySuggestion: "Reveal audio",
            audioPreserved: true
        )
        guard let encoded = try? JSONEncoder().encode(failure),
              let decoded = try? JSONDecoder().decode(RecordingFailure.self, from: encoded) else {
            return false
        }
        return decoded == failure && decoded.audioPreserved
    }

    static func readableNamesAreUniqueWithinOneSecond() -> Bool {
        let start = Date(timeIntervalSince1970: 1_786_300_000)
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let first = SessionNaming.baseName(title: "Design / Review", startTime: start, id: firstID)
        let second = SessionNaming.baseName(title: "Design / Review", startTime: start, id: secondID)
        return first != second
            && first.hasSuffix(firstID.uuidString.lowercased())
            && !first.contains("/")
    }

    static func metadataRoundTripPreservesPrecision() -> Bool {
        let id = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let metadata = SessionMetadataV1(
            id: id,
            title: "Research",
            startTime: Date(timeIntervalSince1970: 1_786_300_000),
            durationSeconds: 93.742,
            systemAudioFilename: "research.m4a",
            microphoneAudioFilename: "research.mic.m4a",
            transcriptFilename: "research.md",
            selectedModel: "Parakeet V2",
            processingState: .transcribing,
            failureMessage: nil,
            flags: [12.25],
            notes: [SessionNoteMetadata(timestamp: 18.5, text: "Follow up")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(SessionMetadataV1.self, from: data) else {
            return false
        }
        return decoded.id == id
            && abs(decoded.durationSeconds - 93.742) < 0.000_001
            && decoded.notes.first?.timestamp == 18.5
    }

    static func retentionHonorsThirtyDayBoundary() -> Bool {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let beforeBoundary = start.addingTimeInterval(30 * 24 * 60 * 60 - 1)
        let boundary = start.addingTimeInterval(30 * 24 * 60 * 60)
        return !AudioRetentionChoice.keep.shouldRemoveAudio(recordedAt: start, now: boundary)
            && !AudioRetentionChoice.moveToTrashAfterThirtyDays.shouldRemoveAudio(
                recordedAt: start,
                now: beforeBoundary
            )
            && AudioRetentionChoice.moveToTrashAfterThirtyDays.shouldRemoveAudio(
                recordedAt: start,
                now: boundary
            )
    }
}
#endif
