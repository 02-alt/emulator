import Foundation

/// Central place for the app's name/branding. Flows to window titles, the About screen, and anywhere
/// else the product name appears. (Note: the on-disk data folder stays "Emulator" in `AppPaths` so
/// existing libraries/saves aren't orphaned — this is display branding only.)
enum AppInfo {
    static let name = "Encore"
}
