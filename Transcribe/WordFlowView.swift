import SwiftUI

/// Renders the words of a single segment as a wrapping, interactive flow.
struct WordFlowView: View {
    let words: [WordTimestamp]
    let segmentIndex: Int
    /// Playback position; a word is "spoken" once currentTime passes its end.
    let currentTime: TimeInterval
    let fontSize: CGFloat
    let isEditing: Bool
    let showConfidenceHints: Bool
    /// confidence below this gets a subtle cue (only when hints shown)
    let lowConfidenceThreshold: Float

    let onSeek: (TimeInterval) -> Void
    let onEditWord: (_ wordIndex: Int, _ newText: String) -> Void
    let onRestoreWord: (_ wordIndex: Int) -> Void
    let onRestoreSentence: () -> Void

    @State private var editingWordIndex: Int? = nil
    @State private var editText: String = ""

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                wordView(index: index, word: word)
                    .id("w-\(segmentIndex)-\(index)")
            }
        }
    }

    @ViewBuilder
    private func wordView(index: Int, word: WordTimestamp) -> some View {
        if isEditing && editingWordIndex == index {
            TextField("", text: $editText, onCommit: {
                onEditWord(index, editText)
                editingWordIndex = nil
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: fontSize))
            .frame(minWidth: 40)
        } else {
            Text(word.word)
                .font(.system(size: fontSize))
                .foregroundColor(color(for: word))
                .underline(showConfidenceHints && word.confidence < lowConfidenceThreshold, pattern: .dot)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isEditing {
                        editingWordIndex = index
                        editText = word.word
                    } else {
                        onSeek(word.start)
                    }
                }
                .contextMenu {
                    Button(localized("restore_word")) { onRestoreWord(index) }
                    Button(localized("restore_sentence")) { onRestoreSentence() }
                }
        }
    }

    private func color(for word: WordTimestamp) -> Color {
        if word.start <= currentTime && currentTime <= word.end {
            return .primaryAccent          // current word
        }
        return word.end <= currentTime ? .textPrimary : .textTertiary  // spoken vs upcoming
    }
}
