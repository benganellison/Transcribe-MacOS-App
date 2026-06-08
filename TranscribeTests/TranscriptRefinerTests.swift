import Foundation
import Testing
@testable import Transcribe

struct TranscriptRefinerTests {

    private func word(_ text: String, _ s: Double, _ e: Double, refined: Bool? = nil, locked: Bool? = nil) -> WordTimestamp {
        WordTimestamp(word: text, start: s, end: e, confidence: 1.0, refined: refined, locked: locked)
    }

    private func turn(_ speaker: String, _ start: Double, _ end: Double, words: [WordTimestamp]) -> DiarizedUtterance {
        DiarizedUtterance(speakerID: speaker, text: words.map(\.word).joined(separator: " "),
                          startTime: start, endTime: end, words: words)
    }

    @Test func testCoveredDraftWordsReplacedAndMarkedRefined() {
        let turns = [turn("Speaker 1", 0, 10, words: [
            word("a", 0, 2, refined: false), word("b", 2, 4, refined: false),
        ])]
        let whisper = [word("Accurate-a", 0, 2), word("Accurate-b", 2, 4)]
        let out = TranscriptRefiner.refine(turns: turns, whisperWords: whisper, coveredUntil: 10)
        #expect(out[0].words?.map(\.word) == ["Accurate-a", "Accurate-b"])
        #expect(out[0].words?.allSatisfy { $0.isRefined } == true)
        #expect(out[0].text == "Accurate-a Accurate-b")
    }

    @Test func testUncoveredWordsStayBlue() {
        let turns = [turn("Speaker 1", 0, 6, words: [
            word("a", 0, 2, refined: false), word("b", 2, 4, refined: false), word("c", 4, 6, refined: false),
        ])]
        let whisper = [word("A", 0, 2), word("B", 2, 4), word("C", 4, 6)]
        let out = TranscriptRefiner.refine(turns: turns, whisperWords: whisper, coveredUntil: 3)
        let words = out[0].words ?? []
        #expect(words.map(\.word) == ["A", "B", "c"])
        #expect(words.last?.isRefined == false)   // "c" still draft (blue)
        #expect(words.first?.isRefined == true)   // "A" refined (white)
    }

    @Test func testLockedWordSurvivesRefinement() {
        let turns = [turn("Speaker 1", 0, 4, words: [
            word("a", 0, 2, refined: false),
            word("EDITED", 2, 4, refined: true, locked: true),
        ])]
        let whisper = [word("A", 0, 2), word("B", 2, 4)]
        let out = TranscriptRefiner.refine(turns: turns, whisperWords: whisper, coveredUntil: 10)
        let words = out[0].words ?? []
        #expect(words.map(\.word) == ["A", "EDITED"])   // whisper "B" dropped, edit kept
        #expect(words.last?.isLocked == true)
    }

    @Test func testTurnIdentityAndBoundariesPreserved() {
        let original = turn("Speaker 2", 1, 9, words: [word("x", 1, 3, refined: false)])
        let out = TranscriptRefiner.refine(turns: [original], whisperWords: [word("X", 1, 3)], coveredUntil: 10)
        #expect(out[0].id == original.id)
        #expect(out[0].speakerID == "Speaker 2")
        #expect(out[0].startTime == 1)
        #expect(out[0].endTime == 9)
    }

    @Test func testWhisperWordInGapLandsInNearestTurn() {
        let turns = [
            turn("Speaker 1", 0, 4, words: [word("a", 0, 2, refined: false)]),
            turn("Speaker 2", 6, 10, words: [word("b", 6, 8, refined: false)]),
        ]
        // Word at 4.5–5 falls in the gap; nearer to turn A's end (4) than B's start (6).
        let whisper = [word("a", 0, 2), word("gap", 4.5, 5), word("b", 6, 8)]
        let out = TranscriptRefiner.refine(turns: turns, whisperWords: whisper, coveredUntil: 10)
        #expect(out[0].words?.contains { $0.word == "gap" } == true)
        #expect(out[1].words?.contains { $0.word == "gap" } == false)
    }

    @Test func testReplacePositionalSwapsTextLeftToRight() {
        let turns = [
            turn("Speaker 1", 0, 4, words: [word("a", 0, 2, refined: false), word("b", 2, 4, refined: false)]),
            turn("Speaker 2", 4, 8, words: [word("c", 4, 6, refined: false), word("d", 6, 8, refined: false)]),
        ]
        // Whisper has emitted 3 words so far.
        let out = TranscriptRefiner.replacePositional(turns: turns, whisperWords: ["A", "B", "C"])
        #expect(out.count == 2)                                  // structure unchanged
        #expect(out[0].words?.map(\.word) == ["A", "B"])
        #expect(out[1].words?.map(\.word) == ["C", "d"])         // 4th word not yet reached
        #expect(out[0].words?.allSatisfy { $0.isRefined } == true)
        #expect(out[1].words?.first?.isRefined == true)          // C refined (white)
        #expect(out[1].words?.last?.isRefined == false)          // d still draft (blue)
        #expect(out[1].text == "C d")
    }

    @Test func testReplacePositionalFromSkipsAlreadyRefinedTurns() {
        let turns = [
            turn("Speaker 1", 0, 4, words: [word("A", 0, 2, refined: true), word("B", 2, 4, refined: true)]),
            turn("Speaker 2", 4, 8, words: [word("c", 4, 6, refined: false), word("d", 6, 8, refined: false)]),
        ]
        // from=2: first turn (words 0,1) is fully before the frontier → left untouched.
        let out = TranscriptRefiner.replacePositional(turns: turns, whisperWords: ["X", "Y", "C", "D"], from: 2)
        #expect(out[0].words?.map(\.word) == ["A", "B"])   // not re-replaced with X,Y
        #expect(out[1].words?.map(\.word) == ["C", "D"])    // edge turn refined
    }

    @Test func testReplacePositionalKeepsLockedWords() {
        let turns = [turn("Speaker 1", 0, 4, words: [
            word("a", 0, 2, refined: false),
            word("EDITED", 2, 4, refined: true, locked: true),
        ])]
        let out = TranscriptRefiner.replacePositional(turns: turns, whisperWords: ["A", "B"])
        #expect(out[0].words?.map(\.word) == ["A", "EDITED"])    // locked kept; position consumed
    }

    @Test func testReplacePositionalEmptyWhisperIsNoOp() {
        let turns = [turn("Speaker 1", 0, 2, words: [word("a", 0, 2, refined: false)])]
        #expect(TranscriptRefiner.replacePositional(turns: turns, whisperWords: []) == turns)
    }

    @Test func testPseudoWordsEvenlyDistributeAndMarkRefined() {
        let words = TranscriptRefiner.pseudoWords(text: "a b c d", start: 0, end: 4)
        #expect(words.map(\.word) == ["a", "b", "c", "d"])
        #expect(words.allSatisfy { $0.isRefined })
        #expect(words.first?.start == 0)
        #expect(words.last?.end == 4)
    }

    @Test func testPseudoWordsEmptyTextIsEmpty() {
        #expect(TranscriptRefiner.pseudoWords(text: "   ", start: 0, end: 4).isEmpty)
    }

    @Test func testEmptyInputsAreNoOps() {
        let turns = [turn("Speaker 1", 0, 4, words: [word("a", 0, 2, refined: false)])]
        #expect(TranscriptRefiner.refine(turns: turns, whisperWords: [], coveredUntil: 10) == turns)
        #expect(TranscriptRefiner.refine(turns: [], whisperWords: [word("A", 0, 2)], coveredUntil: 10).isEmpty)
    }
}
