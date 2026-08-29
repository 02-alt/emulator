import Foundation

/// SwiftPM synthesizes `Bundle.module`, whose one-time initializer calls `fatalError` when the
/// target's resource bundle can't be located. In a shipped `.app` that turns *any* packaging or
/// code-signing hiccup into a launch crash — the `EXC_BREAKPOINT` we saw come out of
/// `LibretroDB.loadIfNeeded()` → `Bundle.module` at launch, before the caller's `guard let … else`
/// could bail out.
///
/// `moduleResources` searches the same candidate locations SwiftPM does but returns `nil` instead
/// of trapping, so a missing bundle degrades gracefully (no catalog metadata) rather than killing
/// the app. All `Bundle.module` call sites in this target should use this instead.
extension Bundle {
    /// Non-trapping stand-in for `Bundle.module`. `nil` if the resource bundle can't be found.
    static let moduleResources: Bundle? = {
        // <PackageName>_<TargetName>.bundle — see Package.swift (package "Emulator", target "LibraryKit").
        let bundleName = "Emulator_LibraryKit.bundle"
        let candidates = [
            Bundle.main.resourceURL,          // shipped .app: Contents/Resources
            Bundle(for: BundleFinderLibraryKit.self).resourceURL,
            Bundle.main.bundleURL,            // `swift run`: bundle sits next to the executable
        ]
        for case let base? in candidates {
            let url = base.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()
}

/// Anchor for `Bundle(for:)` so the search can find resources relative to this module's binary.
private final class BundleFinderLibraryKit {}
