import SwiftUI

/// App-wide settings. Edits persist to `UserDefaults` via `@AppStorage`; gameplay reads them at
/// launch through `AppSettings`. Per-game overrides (the cart's Settings sheet) take precedence
/// over the defaults set here.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.masterVolume) private var masterVolume = SettingsDefault.masterVolume
    @AppStorage(SettingsKey.defaultFilter) private var defaultFilter = SettingsDefault.defaultFilter
    @AppStorage(SettingsKey.lcdBacklit) private var lcdBacklit = SettingsDefault.lcdBacklit
    @AppStorage(SettingsKey.lcdGhosting) private var lcdGhosting = SettingsDefault.lcdGhosting
    @AppStorage(SettingsKey.defaultSwapAB) private var defaultSwapAB = SettingsDefault.defaultSwapAB
    @AppStorage(SettingsKey.haptics) private var haptics = SettingsDefault.haptics
    @AppStorage(SettingsKey.fastForwardSpeed) private var fastForwardSpeed = SettingsDefault.fastForwardSpeed
    @AppStorage(SettingsKey.rewindEnabled) private var rewindEnabled = SettingsDefault.rewindEnabled
    @AppStorage(SettingsKey.autoResume) private var autoResume = SettingsDefault.autoResume
    @AppStorage(SettingsKey.joystickAsDpad) private var joystickAsDpad = SettingsDefault.joystickAsDpad
    @AppStorage(SettingsKey.ambientScene) private var ambientScene = SettingsDefault.ambientScene
    @AppStorage(SettingsKey.ambientVolume) private var ambientVolume = SettingsDefault.ambientVolume
    @AppStorage(SettingsKey.controlScale) private var controlScale = SettingsDefault.controlScale
    @AppStorage(SettingsKey.controlOpacity) private var controlOpacity = SettingsDefault.controlOpacity

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
                        Toggle("LCD Backlight (AGS-101)", isOn: $lcdBacklit).tint(.green)
                        Toggle("LCD Ghosting", isOn: $lcdGhosting).tint(.green)
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
                        Slider(value: $controlOpacity, in: 0.2...1).tint(.green)
                        Image(systemName: "circle.fill").foregroundStyle(.secondary)
                    }
                    Toggle("Haptics", isOn: $haptics).tint(.green)
                    Toggle("Swap A / B by default", isOn: $defaultSwapAB).tint(.green)
                }

                Section {
                    Toggle("Analog Stick as D-Pad", isOn: $joystickAsDpad).tint(.green)
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
                    Toggle("Rewind", isOn: $rewindEnabled).tint(.green)
                    Toggle("Auto-Resume on Launch", isOn: $autoResume).tint(.green)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Core", value: ContinuityService.coreVersion)
                    LabeledContent("System", value: "Game Boy Advance")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            // Keep the ambience in sync as the scene/volume change.
            .onChange(of: ambientScene) { _, _ in AmbientPlayer.shared.apply() }
            .onChange(of: ambientVolume) { _, _ in AmbientPlayer.shared.apply() }
        }
        .preferredColorScheme(.dark)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
