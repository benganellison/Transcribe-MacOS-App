import XCTest
@testable import Transcribe

final class DraftSpliceTests: XCTestCase {

    private func seg(_ s: Double, _ e: Double, _ text: String) -> TranscriptionSegmentData {
        TranscriptionSegmentData(start: s, end: e, text: text, words: nil)
    }

    func testTailDropsSegmentsCoveredByWhisper() {
        let draft = [seg(0, 2, "a"), seg(2, 4, "b"), seg(4, 6, "c")]
        let tail = DraftSplice.tailDraft(draft, after: 3.0)
        XCTAssertEqual(tail.map(\.text), ["b", "c"])
    }

    func testTailEmptyWhenAllCovered() {
        let draft = [seg(0, 2, "a"), seg(2, 4, "b")]
        XCTAssertTrue(DraftSplice.tailDraft(draft, after: 10).isEmpty)
    }

    func testTailAllWhenNothingCovered() {
        let draft = [seg(0, 2, "a"), seg(2, 4, "b")]
        XCTAssertEqual(DraftSplice.tailDraft(draft, after: 0).count, 2)
    }

    func testCombinedTextPrefixPlusTail() {
        let draft = [seg(0, 2, "a"), seg(2, 4, "b"), seg(4, 6, "c")]
        let text = DraftSplice.combinedText(whisperText: "ACCURATE", draft: draft, coveredUntil: 3.0)
        XCTAssertEqual(text, "ACCURATE b c")
    }
}
