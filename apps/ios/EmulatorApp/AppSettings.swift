import Foundation

/// Display filter — mirrors the macOS `Settings.DisplayFilter` (same raw values, so `Game.overrideFilter`
/// is portable): crisp pixels, bilinear, or the physically-modelled GBA LCD panel.
enum DisplayFilter: Int, CaseIterable, Identifiable {
    case sharp = 0, smooth = 1, lcd = 2
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .sharp: return "Sharp"
        case .smooth: return "Smooth"
        case .lcd: return "LCD"
        }
    }
}

/// Ambient soundscape layered over gameplay (off / rain / storm).
enum AmbientScene: Int, CaseIterable, Identifiable {
    case off = 0, rain = 1, storm = 2
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .rain: return "Rain"
        case .storm: return "Storm"
        }
    }
    var resource: String? {
        switch self {
        case .off: return nil
        case .rain: return "rain"
        case .storm: return "storm"
        }
    }
}

/// App-wide settings. Persisted in `UserDefaults` under these keys; the SettingsView edits them via
/// `@AppStorage`, while gameplay code reads them once at launch through the static accessors below
/// (so keys/defaults live in exactly one place and can't drift).
enum SettingsKey {
    static let masterVolume = "settings.masterVolume"
    static let defaultFilter = "settings.defaultFilter"
    static let lcdBacklit = "settings.lcdBacklit"
    static let lcdGhosting = "settings.lcdGhosting"
    static let defaultSwapAB = "settings.defaultSwapAB"
    static let haptics = "settings.haptics"
    static let fastForwardSpeed = "settings.fastForwardSpeed"
    static let rewindEnabled = "settings.rewindEnabled"
    static let autoResume = "settings.autoResume"
    static let joystickAsDpad = "settings.joystickAsDpad"
    static let ambientScene = "settings.ambientScene"
    static let ambientVolume = "settings.ambientVolume"
    static let controlScale = "settings.controlScale"
    static let controlOpacity = "settings.controlOpacity"
    static let transferEnabled = "continuity.transferEnabled"
}

enum SettingsDefault {
    static let masterVolume = 1.0
    static let defaultFilter = DisplayFilter.sharp.rawValue
    static let lcdBacklit = true
    static let lcdGhosting = false
    static let defaultSwapAB = false
    static let haptics = true
    static let fastForwardSpeed = 2.0
    static let rewindEnabled = true
    static let autoResume = false   // off: launch to the library; on: jump straight into last session
    static let joystickAsDpad = true
    static let ambientScene = AmbientScene.off.rawValue
    static let ambientVolume = 0.6
    static let controlScale = 1.0
    static let controlOpacity = 1.0
    static let transferEnabled = false   // off: never copy game files between devices (see About ▸ Handoff)
}

/// Read-side of the global settings for non-UI code (launch-time reads).
enum AppSettings {
    private static let d = UserDefaults.standard

    static var masterVolume: Double { d.object(forKey: SettingsKey.masterVolume) as? Double ?? SettingsDefault.masterVolume }
    static var defaultFilter: DisplayFilter { DisplayFilter(rawValue: d.object(forKey: SettingsKey.defaultFilter) as? Int ?? SettingsDefault.defaultFilter) ?? .sharp }
    static var lcdBacklit: Bool { d.object(forKey: SettingsKey.lcdBacklit) as? Bool ?? SettingsDefault.lcdBacklit }
    static var lcdGhosting: Bool { d.object(forKey: SettingsKey.lcdGhosting) as? Bool ?? SettingsDefault.lcdGhosting }
    static var defaultSwapAB: Bool { d.object(forKey: SettingsKey.defaultSwapAB) as? Bool ?? SettingsDefault.defaultSwapAB }
    static var haptics: Bool { d.object(forKey: SettingsKey.haptics) as? Bool ?? SettingsDefault.haptics }
    static var fastForwardSpeed: Double { d.object(forKey: SettingsKey.fastForwardSpeed) as? Double ?? SettingsDefault.fastForwardSpeed }
    static var rewindEnabled: Bool { d.object(forKey: SettingsKey.rewindEnabled) as? Bool ?? SettingsDefault.rewindEnabled }
    static var autoResume: Bool { d.object(forKey: SettingsKey.autoResume) as? Bool ?? SettingsDefault.autoResume }
    static var transferEnabled: Bool { d.object(forKey: SettingsKey.transferEnabled) as? Bool ?? SettingsDefault.transferEnabled }
    static var joystickAsDpad: Bool { d.object(forKey: SettingsKey.joystickAsDpad) as? Bool ?? SettingsDefault.joystickAsDpad }
    static var ambientScene: AmbientScene { AmbientScene(rawValue: d.object(forKey: SettingsKey.ambientScene) as? Int ?? SettingsDefault.ambientScene) ?? .off }
    static var ambientVolume: Double { d.object(forKey: SettingsKey.ambientVolume) as? Double ?? SettingsDefault.ambientVolume }
    static var controlScale: Double { d.object(forKey: SettingsKey.controlScale) as? Double ?? SettingsDefault.controlScale }
    static var controlOpacity: Double { d.object(forKey: SettingsKey.controlOpacity) as? Double ?? SettingsDefault.controlOpacity }
}
