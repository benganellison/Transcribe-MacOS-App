import Foundation

/// Pure conversion of Parakeet token-level timings into the app's word/segment
/// model. Framework-free (takes a minimal local `Token`), so it's unit-tested.
enum ParakeetDraftParser {

    /// Minimal mirror of FluidAudio's TokenTiming (keeps this file framework-free).
    struct Token: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let confidence: Float
    }

    /// SentencePiece word-start marker.
    static let wordStartMarker = "\u{2581}"  // ▁

    /// Groups subword tokens into words. A token beginning with the word-start
    /// marker starts a new word; others append to the current word.
    static func tokensToWords(_ tokens: [Token]) -> [WordTimestamp] {
        var words: [WordTimestamp] = []
        for t in tokens {
            let isWordStart = t.text.hasPrefix(wordStartMarker)
            let clean = t.text.replacingOccurrences(of: wordStartMarker, with: "")
            if clean.isEmpty { continue }
            if isWordStart || words.isEmpty {
                words.append(WordTimestamp(word: clean, start: t.start, end: t.end, confidence: t.confidence))
            } else {
                let last = words[words.count - 1]
                words[words.count - 1] = WordTimestamp(
                    word: last.word + clean,
                    start: last.start,
                    end: t.end,
                    confidence: min(last.confidence, t.confidence)
                )
            }
        }
        return words
    }

    /// Fallback word builder when token-level grouping fails (e.g. the token strings
    /// don't carry the ▁ word-boundary marker, so everything would collapse into one
    /// "word"). Splits the model's already-correct `text` on whitespace and evenly
    /// distributes timing across `[start, end]`. Coarse per-word timing, but the right
    /// word count — enough for the draft preview and the diarization merge.
    static func wordsFromText(_ text: String, start: TimeInterval, end: TimeInterval) -> [WordTimestamp] {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let span = max(0, end - start)
        let step = span / Double(tokens.count)
        return tokens.enumerated().map { i, w in
            WordTimestamp(word: w, start: start + step * Double(i), end: start + step * Double(i + 1), confidence: 1.0)
        }
    }

    /// Groups words into segments, breaking on a sentence-final word (ends with
    /// . ! ?) or a pause longer than `maxGapSeconds`.
    static func wordsToSegments(_ words: [WordTimestamp], maxGapSeconds: TimeInterval) -> [TranscriptionSegmentData] {
        guard !words.isEmpty else { return [] }
        var segments: [TranscriptionSegmentData] = []
        var current: [WordTimestamp] = []

        func flush() {
            guard !current.isEmpty else { return }
            segments.append(TranscriptionSegmentData(
                start: current.first!.start,
                end: current.last!.end,
                text: current.map(\.word).joined(separator: " "),
                words: current
            ))
            current = []
        }

        for (i, w) in words.enumerated() {
            if let prev = current.last, w.start - prev.end > maxGapSeconds {
                flush()
            }
            current.append(w)
            let endsSentence = w.word.hasSuffix(".") || w.word.hasSuffix("!") || w.word.hasSuffix("?")
            let isLast = i == words.count - 1
            if endsSentence || isLast { flush() }
        }
        return segments
    }
}
