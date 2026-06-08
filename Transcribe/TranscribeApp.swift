import SwiftUI

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var settingsManager = SettingsManager()
    @StateObject private var recordingLibrary = RecordingLibraryManager()
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"

    init() {
        // Register @AppStorage defaults before any view-model or service reads them
        // raw via UserDefaults — otherwise unset keys (fast draft, identify speakers)
        // fall back to false and those features silently never run.
        SettingsManager.registerDefaultSettings()
    }

    private var preferredScheme: ColorScheme? {
        switch appColorScheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(transcriptionManager)
                .environmentObject(settingsManager)
                .environmentObject(recordingLibrary)
                .frame(minWidth: 900, minHeight: 700)
                .frame(idealWidth: 1200, idealHeight: 850)
                .preferredColorScheme(preferredScheme)
                .onAppear {
                    appDelegate.settingsManager = settingsManager
                }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Transcribe") {
                    appDelegate.showAboutWindow()
                }
            }
            
            CommandGroup(after: .appSettings) {
                Button("Preferences...") {
                    appDelegate.showPreferences()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        
        Settings {
            SettingsView()
                .environmentObject(settingsManager)
                .navigationTitle("")
                .preferredColorScheme(preferredScheme)
        }
    }
}
