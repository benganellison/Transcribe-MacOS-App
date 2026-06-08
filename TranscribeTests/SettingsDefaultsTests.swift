import Foundation
import Testing
@testable import Transcribe

/// Guards the bug where the fast draft and speaker identification silently never ran:
/// `@AppStorage` does not persist its inline default, so code that reads these keys raw
/// via `UserDefaults.standard` got `false` (the unset-key fallback) instead of the
/// intended `true`. `SettingsManager.registerDefaultSettings()` must make the raw reads
/// agree with the `@AppStorage` defaults.
struct SettingsDefaultsTests {

    @Test func testRegisterDefaultSettingsTurnsOnFastDraftAndDiarization() {
        // Simulate a fresh install: no explicit values stored for these keys.
        let keys = ["fastDraftEnabled", "fastDraftThresholdMinutes", "identifySpeakers"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }

        SettingsManager.registerDefaultSettings()

        // Read exactly the way TranscriptionView's view-model reads them.
        #expect(UserDefaults.standard.bool(forKey: "fastDraftEnabled"),
                "fast draft must default ON so long recordings show an instant draft")
        #expect(UserDefaults.standard.double(forKey: "fastDraftThresholdMinutes") == 5.0,
                "threshold must default to 5 minutes, not 0")
        #expect(UserDefaults.standard.bool(forKey: "identifySpeakers"),
                "speaker identification must default ON so diarization auto-runs")
    }
}
