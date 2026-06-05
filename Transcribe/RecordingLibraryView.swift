import SwiftUI
import AVFoundation
import AppKit

struct RecordingLibraryView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var recordingLibrary: RecordingLibraryManager

    @State private var audioPlayer: AVAudioPlayer?
    @State private var playbackTimer: Timer?
    @State private var activePlaybackID: String?
    @State private var renameRecordingID: UUID?
    @State private var renameText = ""
    @State private var detailsEditorRecording: SavedRecording?
    @State private var recordingPendingDeletion: SavedRecording?
    @State private var actionError: LibraryActionError?
    @FocusState private var isRenameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    savedRecordingsSection
                    voiceMemosSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.surfaceBackground)
        }
        .background(Color.surfaceBackground)
        .sheet(item: $detailsEditorRecording) { recording in
            RecordingDetailsEditor(recording: recording) { location, comment in
                recordingLibrary.updateMetadata(recording: recording, location: location, comment: comment)
            }
        }
        .alert(localized("Delete Recording"), isPresented: deleteAlertBinding, presenting: recordingPendingDeletion) { recording in
            Button(localized("cancel"), role: .cancel) {
                recordingPendingDeletion = nil
            }
            Button(localized("Delete"), role: .destructive) {
                stopPlaybackIfNeeded(for: recording.id.uuidString)
                recordingLibrary.delete(recording: recording)
                recordingPendingDeletion = nil
            }
        } message: { recording in
            Text(String(format: localized("Are you sure you want to delete %@?"), recording.name))
        }
        .alert(item: $actionError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text(localized("OK")))
            )
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private var header: some View {
        HStack {
            Button(action: {
                appState.showRecordingLibrary = false
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14))
                    Text(localized("back"))
                        .font(.system(size: 14))
                }
                .foregroundColor(.primaryAccent)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(localized("My Recordings"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.textPrimary)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                Text(localized("back"))
            }
            .opacity(0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.surfaceBackground)
        .overlay(
            Rectangle()
                .fill(Color.borderLight)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var savedRecordingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(localized("Saved Recordings"))

            VStack(spacing: 10) {
                if recordingLibrary.savedRecordings.isEmpty {
                    emptyState(localized("No saved recordings yet."))
                } else {
                    ForEach(recordingLibrary.savedRecordings) { recording in
                        savedRecordingRow(for: recording)
                    }
                }
            }
        }
    }

    private var voiceMemosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(localized("Voice Memos"))

            VStack(spacing: 10) {
                if recordingLibrary.hasVoiceMemosAccess {
                    if recordingLibrary.voiceMemos.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(localized("No Voice Memos found in the selected folder."))
                                .font(.system(size: 14))
                                .foregroundColor(.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Button(action: connectVoiceMemos) {
                                Text(localized("Change Folder"))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.primaryAccent)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .glassCard()
                    } else {
                        ForEach(recordingLibrary.voiceMemos) { memo in
                            voiceMemoRow(for: memo)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(localized("Connect your Voice Memos Recordings folder to browse and import Voice Memos here."))
                            .font(.system(size: 14))
                            .foregroundColor(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button(action: connectVoiceMemos) {
                            Text(localized("Connect Voice Memos"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(LinearGradient.accentGradient)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .glassCard()
                }
            }
        }
    }

    private func savedRecordingRow(for recording: SavedRecording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                if renameRecordingID == recording.id {
                    TextField(localized("Recording Name"), text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isRenameFieldFocused)
                        .font(.system(size: 15, weight: .semibold))
                        .onSubmit {
                            confirmRename(for: recording)
                        }

                    Button(action: {
                        confirmRename(for: recording)
                    }) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.primaryAccent)
                    }
                    .buttonStyle(.plain)

                    Button(action: cancelRename) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.textSecondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(recording.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if activePlaybackID == recording.id.uuidString {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.primaryAccent)
                    }

                    transcriptionStatusIcon(for: recording.transcriptionStatus)
                }
            }

            HStack(spacing: 8) {
                Text(formattedDate(recording.date))
                Text("•")
                Text(formattedDuration(recording.duration))
                if let location = recording.location, !location.isEmpty {
                    Text("•")
                    Text(location)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.borderLight, lineWidth: 0.5)
                )
        )
        .contextMenu {
            Button(activePlaybackID == recording.id.uuidString ? localized("Stop") : localized("play")) {
                togglePlayback(url: recording.audioURL(in: recordingLibrary.libraryURL), id: recording.id.uuidString)
            }

            Button(localized("transcribe")) {
                transcribe(recording: recording)
            }

            Button(localized("Rename")) {
                beginRename(recording)
            }

            Button(localized("Edit Details")) {
                detailsEditorRecording = recording
            }

            Button(localized("Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([recording.audioURL(in: recordingLibrary.libraryURL)])
            }

            Divider()

            Button(localized("Delete"), role: .destructive) {
                recordingPendingDeletion = recording
            }
        }
        .onTapGesture(count: 2) {
            transcribe(recording: recording)
        }
    }

    private func voiceMemoRow(for memo: VoiceMemoRecording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text(memo.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if activePlaybackID == memo.id {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.primaryAccent)
                }
            }

            HStack(spacing: 8) {
                Text(formattedDate(memo.date))
                Text("•")
                Text(formattedDuration(memo.duration))
            }
            .font(.system(size: 13))
            .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.borderLight, lineWidth: 0.5)
                )
        )
        .contextMenu {
            Button(activePlaybackID == memo.id ? localized("Stop") : localized("play")) {
                togglePlayback(url: memo.fileURL, id: memo.id)
            }

            Button(localized("transcribe")) {
                transcribe(memo: memo)
            }

            Button(localized("Save to Library")) {
                if recordingLibrary.importVoiceMemo(memo: memo) == nil {
                    actionError = LibraryActionError(
                        title: localized("Import Failed"),
                        message: localized("The Voice Memo could not be saved to your library.")
                    )
                }
            }
        }
        .onTapGesture(count: 2) {
            transcribe(memo: memo)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundColor(.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .glassCard()
    }

    private func beginRename(_ recording: SavedRecording) {
        renameRecordingID = recording.id
        renameText = recording.name
        isRenameFieldFocused = true
    }

    private func confirmRename(for recording: SavedRecording) {
        let trimmedName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            cancelRename()
            return
        }

        if recordingLibrary.rename(recording: recording, newName: trimmedName) != nil {
            cancelRename()
        } else {
            actionError = LibraryActionError(
                title: localized("Rename Failed"),
                message: localized("The recording could not be renamed. Please try again.")
            )
        }
    }

    private func cancelRename() {
        isRenameFieldFocused = false
        renameRecordingID = nil
        renameText = ""
    }

    private func transcribe(recording: SavedRecording) {
        appState.openRecordingForTranscription(
            recording.audioURL(in: recordingLibrary.libraryURL),
            recordingID: recording.id
        )
        appState.showRecordingLibrary = false
    }

    private func transcribe(memo: VoiceMemoRecording) {
        appState.openVoiceMemoForTranscription(memo.fileURL, voiceMemoID: memo.id)
        appState.showRecordingLibrary = false
    }

    private func connectVoiceMemos() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = localized("Select your Voice Memos Recordings folder")
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")

        if panel.runModal() == .OK, let url = panel.url {
            recordingLibrary.selectVoiceMemosFolder(url: url)
        }
    }

    private func togglePlayback(url: URL, id: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            actionError = LibraryActionError(
                title: localized("Playback Unavailable"),
                message: localized("The selected audio file could not be found.")
            )
            return
        }

        if activePlaybackID == id {
            stopPlayback()
            return
        }

        stopPlayback()

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()

            guard player.play() else {
                return
            }

            audioPlayer = player
            activePlaybackID = id
            startPlaybackMonitor()
        } catch {
            stopPlayback()
        }
    }

    private func startPlaybackMonitor() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if audioPlayer?.isPlaying != true {
                stopPlayback()
            }
        }
    }

    private func stopPlaybackIfNeeded(for id: String) {
        if activePlaybackID == id {
            stopPlayback()
        }
    }

    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activePlaybackID = nil
    }

    private func transcriptionStatusIcon(for status: TranscriptionStatus) -> some View {
        Group {
            switch status {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.primaryAccent)
            case .inProgress:
                Image(systemName: "waveform.badge.magnifyingglass")
                    .foregroundColor(.textSecondary)
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .foregroundColor(.textSecondary)
            case .notStarted:
                Image(systemName: "circle")
                    .foregroundColor(.borderLight)
            }
        }
        .font(.system(size: 14))
    }

    private func formattedDate(_ date: Date) -> String {
        if let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day,
           abs(days) < 7 {
            return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        }

        return Self.dateFormatter.string(from: date)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { recordingPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    recordingPendingDeletion = nil
                }
            }
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct LibraryActionError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct RecordingDetailsEditor: View {
    let recording: SavedRecording
    let onSave: (String?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var location: String
    @State private var comment: String

    init(recording: SavedRecording, onSave: @escaping (String?, String?) -> Void) {
        self.recording = recording
        self.onSave = onSave
        _location = State(initialValue: recording.location ?? "")
        _comment = State(initialValue: recording.comment ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(localized("Edit Details"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                Text(localized("Location"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textSecondary)

                TextField(localized("Location"), text: $location)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(localized("Comment"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textSecondary)

                TextEditor(text: $comment)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 120)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.elevatedSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.borderLight, lineWidth: 0.5)
                            )
                    )
            }

            HStack {
                Spacer()

                Button(localized("cancel")) {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.textSecondary)

                Button(action: save) {
                    Text(localized("save"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(LinearGradient.accentGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color.surfaceBackground)
    }

    private func save() {
        onSave(normalize(location), normalize(comment))
        dismiss()
    }

    private func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
