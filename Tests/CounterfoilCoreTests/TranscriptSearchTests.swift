import Testing
@testable import CounterfoilCore

@Suite("Transcript search")
struct TranscriptSearchTests {
    private let transcript = """
    # Test Meeting
    *2026-08-18 09:00 · 2 min · You 1 · Them 2*
    **[00:00:12] Them:** system audio line here
    **[00:00:20] NOTE: remember to check the budget**
    **[00:00:25] You:** second you line
    **[00:00:30] [FLAG]**
    [00:00:35] legacy system audio line
    """

    @Test func indexesSpeechNotesAndFlagsSeparately() {
        let index = TranscriptSearchSupport.makeIndex(from: transcript)
        #expect(index.text(for: .speech).contains("system audio line here"))
        #expect(index.text(for: .speech).contains("legacy system audio line"))
        #expect(!index.text(for: .speech).contains("budget"))
        #expect(index.text(for: .notes).contains("remember to check the budget"))
        #expect(!index.text(for: .notes).contains("second you line"))
        #expect(index.text(for: .flags).contains("flagged moment"))
    }

    @Test func flagAliasesAreSearchable() {
        let index = TranscriptSearchSupport.makeIndex(from: transcript)
        #expect(index.text(for: .all).localizedCaseInsensitiveContains("flagged"))
        #expect(index.text(for: .flags).localizedCaseInsensitiveContains("flagged moment"))
        #expect(index.matches("flagged", scope: .all))
        #expect(index.matches("budget", scope: .notes))
        #expect(!index.matches("budget", scope: .speech))
    }

    @Test func contextsDescribeSemanticEventType() {
        #expect(TranscriptSearchSupport.context(in: transcript, query: "budget", scope: .all) == "Note · remember to check the budget")
        #expect(TranscriptSearchSupport.context(in: transcript, query: "flagged", scope: .all) == "Flagged moment")
        #expect(TranscriptSearchSupport.context(in: transcript, query: "legacy", scope: .speech) == "Meeting · legacy system audio line")
        #expect(TranscriptSearchSupport.context(in: transcript, query: "budget", scope: .speech) == nil)

        let index = TranscriptSearchSupport.makeIndex(from: transcript)
        #expect(TranscriptSearchSupport.context(in: index, query: "budget", scope: .all) == "Note · remember to check the budget")
        #expect(TranscriptSearchSupport.context(in: index, query: "flagged", scope: .flags) == "Flagged moment")
        #expect(TranscriptSearchSupport.context(in: index, query: "legacy", scope: .speech) == "Meeting · legacy system audio line")
    }
}
