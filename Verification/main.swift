@testable import CounterfoilCore

@main
struct CounterfoilCoreVerification {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }

        check(RecordingTransition.allows(.start, from: .idle), "Idle start")
        check(!RecordingTransition.allows(.start, from: .preparing), "Repeated start")
        check(RecordingTransition.allows(.pause, from: .recording), "Pause")
        check(!RecordingTransition.allows(.resume, from: .pausing), "Rapid resume")
        check(RecordingTransition.allows(.resume, from: .paused), "Resume")
        check(RecordingTransition.allows(.stop, from: .paused), "Paused stop")
        check(!RecordingTransition.allows(.stop, from: .saving), "Repeated stop")
        check(RecordingPhase.saving.presentsRecordingPanel, "Panel remains through audio finalization")
        check(!RecordingPhase.transcribing.presentsRecordingPanel, "Panel closes for transcription")
        check(RecordingCoreTestSupport.failureRoundTrips(), "Failure coding")
        check(RecordingCoreTestSupport.readableNamesAreUniqueWithinOneSecond(), "UUID naming")
        check(RecordingCoreTestSupport.defaultTitleIsUntitledMeeting(), "Default title")
        check(RecordingCoreTestSupport.stopConfirmationSequencePasses(), "Stop confirmation")
        check(RecordingCoreTestSupport.channelWarningsAppearOnlyForProblems(), "Channel warning presentation")
        check(RecordingCoreTestSupport.metadataRoundTripPreservesPrecision(), "Metadata precision")
        check(formatElapsedTimestamp(0) == "00:00:00", "Elapsed zero")
        check(formatElapsedTimestamp(3_661) == "01:01:01", "Elapsed hour")
        check(RecordingCoreTestSupport.retentionHonorsThirtyDayBoundary(), "Retention")
        check(RecordingReliabilityTestSupport.metadataRoundTripUsesTemporaryStorage(), "Temporary metadata storage")
        check(RecordingReliabilityTestSupport.crashRecoveryMatrixPasses(), "Crash recovery")
        check(RecordingReliabilityTestSupport.renameFallbackPreservesSource(), "Rename fallback")
        check(RecordingReliabilityTestSupport.successfulRenameMovesSource(), "Rename success")
        check(RecordingReliabilityTestSupport.missingSourcePropagatesRenameFailure(), "Missing source failure")
        check(RecordingReliabilityTestSupport.capacityAndNoteBoundariesPass(), "Capacity and note timing")
        check(RecordingReliabilityTestSupport.recoveryActionsCoverFailureMatrix(), "Recovery actions")

        print("CounterfoilCoreVerification passed \(count) checks")
    }
}
