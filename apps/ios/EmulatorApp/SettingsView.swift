import SwiftUI
import LibraryKit

/// App-wide settings. Edits persist to `UserDefaults` via `@AppStorage`; gameplay reads them at
/// launch through `AppSettings`. Per-game overrides (the cart's Settings sheet) take precedence
/// over the defaults set here.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showAbout = false

    @AppStorage(SettingsKey.masterVolume) private var masterVolume = SettingsDefault.masterVolume
    @AppStorage(SettingsKey.defaultFilter) private var defaultFilter = SettingsDefault.defaultFilter
    @AppStorage(SettingsKey.lcdBacklit) private var lcdBacklit = SettingsDefault.lcdBacklit
    @AppStorage(SettingsKey.lcdGhosting) private var lcdGhosting = SettingsDefault.lcdGhosting
    @AppStorage(SettingsKey.defaultSwapAB) private var defaultSwapAB = SettingsDefault.defaultSwapAB
    @AppStorage(SettingsKey.haptics) private var haptics = SettingsDefault.haptics
    @AppStorage(SettingsKey.fastForwardSpeed) private var fastForwardSpeed = SettingsDefault.fastForwardSpeed
    @AppStorage(SettingsKey.rewindEnabled) private var rewindEnabled = SettingsDefault.rewindEnabled
    @AppStorage(SettingsKey.autoResume) private var autoResume = SettingsDefault.autoResume
    @AppStorage(SettingsKey.transferEnabled) private var transferEnabled = SettingsDefault.transferEnabled
    @AppStorage(SettingsKey.joystickAsDpad) private var joystickAsDpad = SettingsDefault.joystickAsDpad
    @AppStorage(SettingsKey.ambientScene) private var ambientScene = SettingsDefault.ambientScene
    @AppStorage(SettingsKey.ambientVolume) private var ambientVolume = SettingsDefault.ambientVolume
    @AppStorage(SettingsKey.controlScale) private var controlScale = SettingsDefault.controlScale
    @AppStorage(SettingsKey.controlOpacity) private var controlOpacity = SettingsDefault.controlOpacity
    @AppStorage(SettingsKey.trophyNotifications) private var trophyNotifications = SettingsDefault.trophyNotifications

    // RetroAchievements login. Username (a public handle) lives in UserDefaults; the Web API key is
    // a secret, so it's kept in the Keychain via `RACredentials` — the same store the game details
    // sheet reads to light up trophies. `raApiKey` seeds from the Keychain and writes back on edit.
    @AppStorage("ra.username") private var raUsername = ""
    @State private var raApiKey = RACredentials.storedAPIKey ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Audio") {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $masterVolume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }

                Section("Ambience") {
                    Picker("Soundscape", selection: $ambientScene) {
                        ForEach(AmbientScene.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if ambientScene != AmbientScene.off.rawValue {
                        HStack {
                            Image(systemName: "cloud.rain").foregroundStyle(.secondary)
                            Slider(value: $ambientVolume, in: 0...1)
                            Image(systemName: "cloud.heavyrain").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Video") {
                    Picker("Default Filter", selection: $defaultFilter) {
                        ForEach(DisplayFilter.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if defaultFilter == DisplayFilter.lcd.rawValue {
                        Toggle("LCD Backlight (AGS-101)", isOn: $lcdBacklit).tint(DS.accent)
                        Toggle("LCD Ghosting", isOn: $lcdGhosting).tint(DS.accent)
                    }
                }

                Section("On-Screen Controls") {
                    Picker("Button Size", selection: $controlScale) {
                        Text("Small").tag(0.85)
                        Text("Medium").tag(1.0)
                        Text("Large").tag(1.2)
                    }
                    HStack {
                        Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                        Slider(value: $controlOpacity, in: 0.2...1).tint(DS.accent)
                        Image(systemName: "circle.fill").foregroundStyle(.secondary)
                    }
                    Toggle("Haptics", isOn: $haptics).tint(DS.accent)
                    Toggle("Swap A / B by default", isOn: $defaultSwapAB).tint(DS.accent)
                }

                Section {
                    Toggle("Analog Stick as D-Pad", isOn: $joystickAsDpad).tint(DS.accent)
                } header: {
                    Text("Controller")
                } footer: {
                    Text("MFi, Xbox and DualSense controllers connect automatically and use the standard mapping. When one is connected the on-screen controls hide.")
                }

                Section("Gameplay") {
                    Picker("Fast-Forward Speed", selection: $fastForwardSpeed) {
                        Text("2×").tag(2.0)
                        Text("3×").tag(3.0)
                        Text("4×").tag(4.0)
                    }
                    Toggle("Rewind", isOn: $rewindEnabled).tint(DS.accent)
                    Toggle("Auto-Resume on Launch", isOn: $autoResume).tint(DS.accent)
                }

                Section {
                    Toggle("Transfer Games Between My Devices", isOn: $transferEnabled).tint(DS.accent)
                } header: {
                    Text("Handoff")
                } footer: {
                    Text("Continue a game on another of your devices even if it doesn’t have the game yet: "
                        + "Encore copies it over through your own private iCloud — never our servers — and "
                        + "deletes the copy the moment your other device receives it. Only turn this on for "
                        + "games you legally own. We don’t condone piracy.")
                }

                Section {
                    Toggle("Trophy Banners", isOn: $trophyNotifications).tint(DS.accent)
                    Button("Preview Banner") {
                        // The banner host lives at the app root, behind this sheet — dismiss to the
                        // library so the preview is actually visible, then post it.
                        dismiss()
                        Task {
                            try? await Task.sleep(for: .seconds(0.5))
                            AppNotifier.shared.post(
                                .trophy(title: "Nice! Got the hang of it", points: 5))
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("A subtle banner slides in when you unlock a RetroAchievement while playing.")
                }

                Section {
                    TextField("Username", text: $raUsername)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Web API Key", text: $raApiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: raApiKey) { _, new in
                            RACredentials.setAPIKey(new.trimmingCharacters(in: .whitespaces))
                        }
                } header: {
                    Text("RetroAchievements")
                } footer: {
                    Text("Sign in with your RetroAchievements username and Web API key (from Settings → Keys on retroachievements.org) to see trophies and story progress for each game.")
                }

            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAbout = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("About")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showAbout) {
                NavigationStack { AboutView() }
                    .preferredColorScheme(.dark)
            }
            // Keep the ambience in sync as the scene/volume change.
            .onChange(of: ambientScene) { _, _ in AmbientPlayer.shared.apply() }
            .onChange(of: ambientVolume) { _, _ in AmbientPlayer.shared.apply() }
        }
        .preferredColorScheme(.dark)
    }
}
