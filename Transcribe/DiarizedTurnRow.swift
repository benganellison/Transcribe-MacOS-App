import SwiftUI

/// One speaker turn in the diarized transcript: the speaker-label menu header
/// plus the turn's words.
///
/// Equatable so the LazyVStack only re-renders rows whose inputs changed. The
/// playhead arrives as a `PlaybackPhase` (stable `.spoken`/`.upcoming` for rows
/// it isn't in), so 10 Hz playback ticks touch a single row. Without this gate,
/// every tick pushed every realized row's AppKit-backed speaker Menu through
/// updateNSView while scrolling shuffled lazy placements — the transaction
/// feedback loop behind the listen-while-scrolling freeze (confirmed by
/// spindump: flushTransactions never drained, hot in AppKitPopUpAdaptor and
/// LazyLayoutViewCache.updateItemPhases).
struct DiarizedTurnRow: View, Equatable {
    struct SpeakerOption: Equatable {
        let id: String
        let name: String
    }

    let utterance: DiarizedUtterance
    let uIndex: Int
    let displayName: String
    let otherSpeakers: [SpeakerOption]
    let timestamp: String?
    let fontSize: CGFloat
    let isEditing: Bool
    let showConfidenceHints: Bool
    let isTranscribing: Bool
    let phase: TimedTranscript.PlaybackPhase

    let onRename: () -> Void
    let onMergeWithPrevious: () -> Void
    let onMergeSpeakerInto: (String) -> Void
    let onAssignTurnTo: (String) -> Void
    let onAssignTurnToNew: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onEditWord: (_ wordIndex: Int, _ newText: String) -> Void
    let onEditSentence: (_ newText: String) -> Void
    let onRestoreWord: (_ wordIndex: Int) -> Void
    let onRestoreSentence: () -> Void
    let onSplitTurn: (_ beforeWordIndex: Int) -> Void

    /// Data-only comparison; closures are recreated by the parent each pass but
    /// capture nothing that can change while the data fields compare equal
    /// (uIndex is a field precisely so index shifts force a re-render).
    static func == (lhs: DiarizedTurnRow, rhs: DiarizedTurnRow) -> Bool {
        lhs.utterance == rhs.utterance
            && lhs.uIndex == rhs.uIndex
            && lhs.displayName == rhs.displayName
            && lhs.otherSpeakers == rhs.otherSpeakers
            && lhs.timestamp == rhs.timestamp
            && lhs.fontSize == rhs.fontSize
            && lhs.isEditing == rhs.isEditing
            && lhs.showConfidenceHints == rhs.showConfidenceHints
            && lhs.isTranscribing == rhs.isTranscribing
            && lhs.phase == rhs.phase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Menu {
                    Button(localized("rename_speaker_title")) { onRename() }
                    if uIndex > 0 {
                        Button(localized("merge_with_previous")) { onMergeWithPrevious() }
                    }
                    if !otherSpeakers.isEmpty {
                        Menu(localized("merge_speaker_into")) {
                            ForEach(otherSpeakers, id: \.id) { target in
                                Button(target.name) { onMergeSpeakerInto(target.id) }
                            }
                        }
                    }
                    Menu(localized("assign_turn_to")) {
                        ForEach(otherSpeakers, id: \.id) { target in
                            Button(target.name) { onAssignTurnTo(target.id) }
                        }
                        Button(localized("new_speaker")) { onAssignTurnToNew() }
                    }
                } label: {
                    Text(displayName)
                        .font(.system(size: max(11, fontSize - 2), weight: .semibold))
                        .foregroundColor(.primaryAccent)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(localized("speaker_actions_help"))

                if let timestamp {
                    Text("[\(timestamp)]")
                        .font(.system(size: max(10, fontSize - 4)))
                        .foregroundColor(.textTertiary)
                }
            }

            if isTranscribing, let uWords = utterance.words, !uWords.isEmpty {
                // Streaming: one cheap Text per turn (per-word blue/white via
                // AttributedString) instead of a tappable view + FlowLayout per
                // word. The heavy interactive WordFlowView returns at completion.
                Text(Self.streamingAttributedText(uWords, fontSize: fontSize))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let uWords = utterance.words, !uWords.isEmpty {
                WordFlowView(
                    words: uWords,
                    segmentIndex: 10_000 + uIndex,
                    currentTime: phase.effectiveTime,
                    fontSize: fontSize,
                    isEditing: isEditing,
                    showConfidenceHints: showConfidenceHints,
                    lowConfidenceThreshold: 0.5,
                    colorBySource: isTranscribing,
                    onSeek: onSeek,
                    onEditWord: onEditWord,
                    onEditSentence: onEditSentence,
                    onRestoreWord: onRestoreWord,
                    onRestoreSentence: onRestoreSentence,
                    onSplitTurn: onSplitTurn
                )
                // Constrain the FlowLayout to the container width so it wraps;
                // without this the layout can be proposed a nil width, which
                // FlowLayout treats as .infinity → one non-wrapping row that
                // overflows right (matches the two sibling branches).
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(utterance.text)
                    .font(.system(size: fontSize))
                    .foregroundColor(.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// One AttributedString for a whole turn with per-word color (draft = blue,
    /// refined = white). Rendered as a single Text — no per-word views or custom layout.
    private static func streamingAttributedText(_ words: [WordTimestamp], fontSize: CGFloat) -> AttributedString {
        var result = AttributedString()
        for (i, w) in words.enumerated() {
            var piece = AttributedString(i == 0 ? w.word : " " + w.word)
            piece.foregroundColor = w.isRefined ? Color.textPrimary : Color.draftBlue
            piece.font = .system(size: fontSize)
            result += piece
        }
        return result
    }
}
