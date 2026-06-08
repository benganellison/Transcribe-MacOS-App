import Foundation
import Testing
@testable import Transcribe

struct SpeakerSegmentMapperTests {

    private func row(_ idx: Int, _ s: Double, _ e: Double) -> SpeakerSegmentMapper.Row {
        SpeakerSegmentMapper.Row(speakerIndex: idx, start: s, end: e)
    }

    @Test func testRelabelsInFirstAppearanceOrder() {
        // Diarizer slot indices are arbitrary (5, 2); labels should follow time order.
        let out = SpeakerSegmentMapper.map([row(5, 0, 2), row(2, 2, 4), row(5, 4, 6)])
        #expect(out.map(\.speakerLabel) == ["Speaker 1", "Speaker 2", "Speaker 1"])
        #expect(out.map(\.start) == [0, 2, 4])
    }

    @Test func testSortsByStartTime() {
        let out = SpeakerSegmentMapper.map([row(1, 4, 6), row(0, 0, 2), row(1, 2, 4)])
        #expect(out.map(\.start) == [0, 2, 4])
        // Earliest speaker (index 0 at t=0) becomes Speaker 1.
        #expect(out.first?.speakerLabel == "Speaker 1")
    }

    @Test func testMultipleSegmentsPerSpeakerShareLabel() {
        let out = SpeakerSegmentMapper.map([row(7, 0, 1), row(7, 5, 6), row(3, 2, 3)])
        #expect(out.map(\.speakerLabel) == ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    @Test func testEmptyInputIsEmpty() {
        #expect(SpeakerSegmentMapper.map([]).isEmpty)
    }
}
