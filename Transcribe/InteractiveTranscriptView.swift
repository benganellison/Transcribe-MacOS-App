import SwiftUI

struct InteractiveTranscriptView: View {
    let segments: [TranscriptionSegmentData]
    let currentTime: TimeInterval
    let fontSize: CGFloat
    let isEditing: Bool
    let followPlayback: Bool
    let showConfidenceHints: Bool

    let onSeek: (TimeInterval) -> Void
    let onEditWord: (_ segmentIndex: Int, _ wordIndex: Int, _ newText: String) -> Void
    let onEditSentence: (_ segmentIndex: Int, _ newText: String) -> Void
    let onRestoreWord: (_ segmentIndex: Int, _ wordIndex: Int) -> Void
    let onRestoreSentence: (_ segmentIndex: Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { sIndex, segment in
                        WordFlowView(
                            words: segment.words ?? [],
                            segmentIndex: sIndex,
                            currentTime: currentTime,
                            fontSize: fontSize,
                            isEditing: isEditing,
                            showConfidenceHints: showConfidenceHints,
                            lowConfidenceThreshold: 0.5,
                            onSeek: onSeek,
                            onEditWord: { wIndex, text in onEditWord(sIndex, wIndex, text) },
                            onEditSentence: { text in onEditSentence(sIndex, text) },
                            onRestoreWord: { wIndex in onRestoreWord(sIndex, wIndex) },
                            onRestoreSentence: { onRestoreSentence(sIndex) }
                        )
                    }
                }
                .padding(16)
            }
            .onChange(of: currentTime) { _, t in
                guard followPlayback, !isEditing,
                      let active = TimedTranscript.activeWord(in: segments, at: t) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("w-\(active.segmentIndex)-\(active.wordIndex)", anchor: .center)
                }
            }
        }
    }
}
