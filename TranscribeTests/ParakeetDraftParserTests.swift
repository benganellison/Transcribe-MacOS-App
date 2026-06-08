import XCTest
@testable import Transcribe

final class ParakeetDraftParserTests: XCTestCase {

    private func tok(_ t: String, _ s: Double, _ e: Double) -> ParakeetDraftParser.Token {
        ParakeetDraftParser.Token(text: t, start: s, end: e, confidence: 0.9)
    }

    func testTokensToWordsGroupsSubwords() {
        let tokens = [tok("▁Jag", 0, 0.3), tok("▁ve", 0.3, 0.5), tok("t", 0.5, 0.6), tok("▁inte", 0.6, 1.0)]
        let words = ParakeetDraftParser.tokensToWords(tokens)
        XCTAssertEqual(words.map(\.word), ["Jag", "vet", "inte"])
        XCTAssertEqual(words[1].start, 0.3)
        XCTAssertEqual(words[1].end, 0.6)
    }

    func testWordsToSegmentsSplitsOnSentenceEnd() {
        let words = [
            WordTimestamp(word: "Hej.", start: 0, end: 1, confidence: 1),
            WordTimestamp(word: "Då", start: 1.1, end: 1.5, confidence: 1),
        ]
        let segs = ParakeetDraftParser.wordsToSegments(words, maxGapSeconds: 0.8)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "Hej.")
        XCTAssertEqual(segs[1].text, "Då")
    }

    func testWordsToSegmentsSplitsOnGap() {
        let words = [
            WordTimestamp(word: "a", start: 0, end: 1, confidence: 1),
            WordTimestamp(word: "b", start: 3.0, end: 3.5, confidence: 1),
        ]
        let segs = ParakeetDraftParser.wordsToSegments(words, maxGapSeconds: 0.8)
        XCTAssertEqual(segs.count, 2)
    }

    func testWordsToSegmentsKeepsRunTogether() {
        let words = [
            WordTimestamp(word: "a", start: 0, end: 0.5, confidence: 1),
            WordTimestamp(word: "b", start: 0.6, end: 1.0, confidence: 1),
        ]
        let segs = ParakeetDraftParser.wordsToSegments(words, maxGapSeconds: 0.8)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].text, "a b")
        XCTAssertEqual(segs[0].start, 0)
        XCTAssertEqual(segs[0].end, 1.0)
        XCTAssertEqual(segs[0].words?.count, 2)
    }

    func testEmptyTokens() {
        XCTAssertTrue(ParakeetDraftParser.tokensToWords([]).isEmpty)
        XCTAssertTrue(ParakeetDraftParser.wordsToSegments([], maxGapSeconds: 0.8).isEmpty)
    }

    func testWordsFromTextSplitsAndDistributesTiming() {
        let words = ParakeetDraftParser.wordsFromText("hej jag heter Anna", start: 0, end: 8)
        XCTAssertEqual(words.map(\.word), ["hej", "jag", "heter", "Anna"])
        XCTAssertEqual(words.first?.start, 0)
        XCTAssertEqual(words.last?.end, 8)
    }

    func testWordsFromTextEmpty() {
        XCTAssertTrue(ParakeetDraftParser.wordsFromText("   ", start: 0, end: 8).isEmpty)
    }
}
