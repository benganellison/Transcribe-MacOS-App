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

    @State private var isUserScrolling = false
    @State private var lastScrollTargetID: String? = nil

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
            .onScrollPhaseChange { _, newPhase in
                // User-driven phases pause follow-playback: an animated scrollTo
                // issued mid-gesture fights the scroll and forces the LazyVStack
                // to realize off-screen content to resolve the word ID — at 10 Hz
                // that livelocks the main thread (the listen-while-scrolling
                // freeze). `.animating` is our own scrollTo, not the user.
                switch newPhase {
                case .tracking, .interacting, .decelerating:
                    isUserScrolling = true
                default:
                    isUserScrolling = false
                }
            }
            .onChange(of: currentTime) { _, t in
                guard followPlayback, !isEditing, !isUserScrolling,
                      let target = TimedTranscript.followScrollTarget(in: segments, at: t, lastTargetID: lastScrollTargetID)
                else { return }
                lastScrollTargetID = target
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }
}
