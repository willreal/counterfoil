import Testing
@testable import CounterfoilCore

@Suite("Recording core")
struct RecordingCoreTests {
    @Test func repeatedStartIsRejectedDuringPreparation() {
        #expect(RecordingTransition.allows(.start, from: .idle))
        #expect(!RecordingTransition.allows(.start, from: .preparing))
        #expect(!RecordingTransition.allows(.start, from: .recording))
    }

    @Test func rapidPauseAndResumeRequestsAreSerialized() {
        #expect(RecordingTransition.allows(.pause, from: .recording))
        #expect(!RecordingTransition.allows(.pause, from: .pausing))
        #expect(!RecordingTransition.allows(.resume, from: .pausing))
        #expect(RecordingTransition.allows(.resume, from: .paused))
        #expect(!RecordingTransition.allows(.resume, from: .resuming))
    }

    @Test func stopIsAvailableWhilePaused() {
        #expect(RecordingTransition.allows(.stop, from: .paused))
        #expect(!RecordingTransition.allows(.stop, from: .saving))
    }

    @Test func recordingPanelClosesAfterAudioFinalization() {
        #expect(RecordingPhase.saving.presentsRecordingPanel)
        #expect(!RecordingPhase.transcribing.presentsRecordingPanel)
        #expect(!RecordingPhase.complete(sessionID: "session").presentsRecordingPanel)
        #expect(!RecordingPhase.failed(RecordingFailure(
            stage: .transcribing,
            message: "Transcription failed",
            recoverySuggestion: "Retry",
            audioPreserved: true
        )).presentsRecordingPanel)
    }

    @Test func failurePreservesRecoveryContext() throws {
        #expect(RecordingCoreTestSupport.failureRoundTrips())
    }

    @Test func permissionAndMicrophoneFailuresRemainVisible() {
        let permission = RecordingPhase.failed(RecordingFailure(
            stage: .preparing,
            message: "Permission denied",
            recoverySuggestion: "Review access",
            audioPreserved: false
        ))
        let microphone = RecordingPhase.failed(RecordingFailure(
            stage: .preparing,
            message: "Microphone failed",
            recoverySuggestion: "Review access",
            audioPreserved: false
        ))
        #expect(permission.presentsRecordingPanel)
        #expect(microphone.presentsRecordingPanel)
    }

    @Test func readableNamesRemainUniqueWithinOneSecond() {
        #expect(RecordingCoreTestSupport.readableNamesAreUniqueWithinOneSecond())
    }

    @Test func newRecordingsUseUntitledMeeting() {
        #expect(RecordingCoreTestSupport.defaultTitleIsUntitledMeeting())
    }

    @Test func stopConfirmationCountsDownAndCancelsDeterministically() {
        #expect(RecordingCoreTestSupport.stopConfirmationSequencePasses())
    }

    @Test func healthyAndPausedChannelsStayQuiet() {
        #expect(RecordingCoreTestSupport.channelWarningsAppearOnlyForProblems())
    }

    @Test func metadataRoundTripPreservesExactDurationAndNoteOffset() throws {
        #expect(RecordingCoreTestSupport.metadataRoundTripPreservesPrecision())
    }

    @Test func futureTranscriptTimestampsBeginAtElapsedZero() {
        #expect(formatElapsedTimestamp(0) == "00:00:00")
        #expect(formatElapsedTimestamp(15.9) == "00:00:15")
        #expect(formatElapsedTimestamp(3_661) == "01:01:01")
    }

    @Test func retentionChoiceHonorsThirtyDayBoundary() {
        #expect(RecordingCoreTestSupport.retentionHonorsThirtyDayBoundary())
    }

    @Test func metadataStorageUsesTemporaryRoot() {
        #expect(RecordingReliabilityTestSupport.metadataRoundTripUsesTemporaryStorage())
    }

    @Test func interruptedSessionsRecoverDeterministically() {
        #expect(RecordingReliabilityTestSupport.crashRecoveryMatrixPasses())
    }

    @Test func renameFailurePreservesOriginalAudio() {
        #expect(RecordingReliabilityTestSupport.renameFallbackPreservesSource())
        #expect(RecordingReliabilityTestSupport.missingSourcePropagatesRenameFailure())
    }

    @Test func successfulRenameMovesOriginalAudio() {
        #expect(RecordingReliabilityTestSupport.successfulRenameMovesSource())
    }

    @Test func capacityAndNoteBoundariesAreStable() {
        #expect(RecordingReliabilityTestSupport.capacityAndNoteBoundariesPass())
    }

    @Test func recoveryPolicyCoversFailureMatrix() {
        #expect(RecordingReliabilityTestSupport.recoveryActionsCoverFailureMatrix())
    }
}
