import AppKit
import LibraryKit
import UniformTypeIdentifiers

/// The friendly "set up PlayStation" flow — themed cards, not scary errors. It explains why a BIOS
/// is needed, lets the user add one (or several, one per region), identifies the region of each dump
/// (by MD5, else by asking), and can nudge for a specific region a game wants. Triggered from the app
/// menu, from Settings, and from a `.biosRequired` / region-mismatch at launch.
@MainActor
enum PSXBiosOnboarding {

    /// Present the onboarding over `window`. `onReady` fires when a usable BIOS is installed (already
    /// was, or the user just added one). When some BIOS already exists this opens the management card
    /// (coverage + add more) rather than the first-run explainer.
    static func present(in window: NSWindow?, onReady: (() -> Void)? = nil) {
        if PSXBios.isInstalled {
            manage(in: window, onReady: onReady)
        } else {
            explain(in: window, onReady: onReady)
        }
    }

    /// A game whose region isn't covered is about to launch. Nudge to add that exact BIOS, but let the
    /// player continue on the fallback BIOS if they'd rather. `onReady` continues the launch after a
    /// successful add; `onSkip` continues without adding.
    static func presentMissing(region: PSXRegion, in window: NSWindow?,
                               onReady: @escaping () -> Void, onSkip: @escaping () -> Void) {
        AppAlert.present(
            in: window,
            symbol: "globe",
            title: "Add the \(region.displayName) BIOS?",
            message: """
            This is a \(region.displayName) \(region.flag) game. You don’t have that region’s PlayStation \
            BIOS (\(region.biosFilename)) installed yet.

            It’ll still boot on the BIOS you have, but region-checking games run best on their own. Add \
            the \(region.displayName) BIOS for the best compatibility.
            """,
            actions: [
                .init(title: "Play Anyway", isCancel: true) { onSkip() },
                .init(title: "Add BIOS…", isDefault: true) {
                    chooseFile(in: window, preferred: region, onReady: onReady)
                },
            ])
    }

    /// Add (or replace) the BIOS for a specific region — the entry point the per-region buttons in
    /// Settings use. Goes straight to the file picker, defaulting the region to `region` if the dump
    /// can't identify itself. `onReady` fires after a successful install (callers refresh their UI).
    static func addBIOS(for region: PSXRegion?, in window: NSWindow?, onReady: (() -> Void)? = nil) {
        chooseFile(in: window, preferred: region, onReady: onReady)
    }

    /// Open the user's browser on a guide for **legally** dumping a PlayStation BIOS from a console
    /// they own — deliberately not a search for the copyrighted image itself.
    static func openDumpingGuide() {
        let query = "how to dump PlayStation 1 BIOS from your own console"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "https://duckduckgo.com/?q=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - First run

    private static func explain(in window: NSWindow?, onReady: (() -> Void)?) {
        AppAlert.present(
            in: window,
            symbol: "cpu",
            title: "Set Up PlayStation",
            message: """
            PlayStation games need your console’s start-up file — its BIOS — to run. You only add it once.

            It’s a 512 KB file, usually named something like scph5501.bin, dumped from a PlayStation you \
            own. Choose it below and you’re set. You can add each region’s BIOS (Japan, North America, \
            Europe) so every game runs on its own.
            """,
            actions: [
                .init(title: "Not Now", isCancel: true),
                .init(title: "Choose BIOS File…", isDefault: true) {
                    chooseFile(in: window, preferred: nil, onReady: onReady)
                },
            ])
    }

    // MARK: - Management (multi-region)

    /// Coverage card: what's installed, which regions are still missing, and a button to add more.
    private static func manage(in window: NSWindow?, onReady: (() -> Void)?) {
        let have = PSXBios.installedRegions
        let covered = PSXRegion.allCases.filter { have.contains($0) }
        let missing = PSXBios.missingRegions

        let coverageLine = PSXRegion.allCases
            .map { "\($0.flag) \($0.displayName): \(have.contains($0) ? "installed" : "—")" }
            .joined(separator: "\n")

        var actions: [AppAlert.Action] = []
        actions.append(.init(title: "Done", isCancel: true) { onReady?() })
        if let next = missing.first {
            actions.append(.init(title: "Add \(next.displayName)…", isDefault: true) {
                chooseFile(in: window, preferred: next, onReady: onReady)
            })
        } else {
            actions.append(.init(title: "Add Another…", isDefault: true) {
                chooseFile(in: window, preferred: nil, onReady: onReady)
            })
        }

        AppAlert.present(
            in: window,
            symbol: missing.isEmpty ? "checkmark.circle" : "cpu",
            title: missing.isEmpty ? "All Regions Covered" : "PlayStation BIOS",
            message: (covered.isEmpty ? "" : "Installed: \(PSXBios.installedDescription ?? "").\n\n")
                + coverageLine
                + (missing.isEmpty
                   ? "\n\nEvery region is covered — all your games boot on their own BIOS."
                   : "\n\nAdd the missing regions so games from them run on their intended BIOS."),
            actions: actions)
    }

    // MARK: - Picking + installing

    /// Open the file panel, validate the pick, and install it. `preferred` is the region we're hoping
    /// for (from a targeted nudge or the next-missing slot); it's only used as the default when the
    /// dump's own region can't be recognized from its bytes.
    private static func chooseFile(in window: NSWindow?, preferred: PSXRegion?, onReady: (() -> Void)?) {
        let panel = NSOpenPanel()
        panel.title = "Choose PlayStation BIOS"
        panel.prompt = "Use BIOS"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // BIOS dumps are typically .bin, but people keep them under odd extensions — allow anything
        // and let validation (size + Sony signature) be the real gate.
        if let bin = UTType(filenameExtension: "bin") {
            panel.allowedContentTypes = [bin, .data]
        }

        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let validated = try PSXBios.validate(url)
                if let known = validated.known {
                    // The dump identifies itself — install straight under its canonical region.
                    let name = try PSXBios.install(validated, as: known.region)
                    afterInstall(name: name, in: window, onReady: onReady)
                } else {
                    // Unknown-but-valid dump: we can't read its region from the bytes, so ask.
                    askRegion(for: validated, preferred: preferred, in: window, onReady: onReady)
                }
            } catch {
                showError(in: window, message: error.localizedDescription, preferred: preferred, onReady: onReady)
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    /// Ask which region an unrecognized (but valid) dump belongs to, so it installs under the right
    /// canonical name. This is what keeps a valid-but-unlisted Japanese dump from being misfiled as
    /// North America.
    private static func askRegion(for validated: PSXBios.Validated, preferred: PSXRegion?,
                                  in window: NSWindow?, onReady: (() -> Void)?) {
        // Order the buttons so the region we're hoping for is the default (rightmost).
        let ordered = PSXRegion.allCases.sorted { a, _ in a == preferred }
        var actions: [AppAlert.Action] = [.init(title: "Cancel", isCancel: true)]
        for (i, region) in ordered.enumerated() {
            actions.append(.init(title: "\(region.flag) \(region.displayName)",
                                 isDefault: i == ordered.count - 1) {
                do {
                    let name = try PSXBios.install(validated, as: region)
                    afterInstall(name: name, in: window, onReady: onReady)
                } catch {
                    showError(in: window, message: error.localizedDescription, preferred: preferred, onReady: onReady)
                }
            })
        }
        AppAlert.present(
            in: window,
            symbol: "globe",
            title: "Which Region?",
            message: "This is a valid PlayStation BIOS, but it isn’t one we recognize by name. Which "
                + "region is it from? It’ll be installed under that region’s standard filename so games "
                + "auto-detect it correctly."
                + (preferred.map { "\n\nA \($0.displayName) game prompted this — \($0.displayName) is likely." } ?? ""),
            actions: actions)
    }

    /// After a successful install, either invite the next missing region or confirm we're ready.
    private static func afterInstall(name: String, in window: NSWindow?, onReady: (() -> Void)?) {
        let missing = PSXBios.missingRegions
        if let next = missing.first {
            AppAlert.present(
                in: window,
                symbol: "checkmark.circle",
                title: "Installed \(name)",
                message: "That region is set. You can add the \(next.displayName) \(next.flag) BIOS too so "
                    + "those games run on their own — or stop here; your library still plays.",
                actions: [
                    .init(title: "Done", isCancel: true) { onReady?() },
                    .init(title: "Add \(next.displayName)…", isDefault: true) {
                        chooseFile(in: window, preferred: next, onReady: onReady)
                    },
                ])
        } else {
            AppAlert.present(
                in: window,
                symbol: "checkmark.circle",
                title: "You’re All Set",
                message: "Every region is covered — all your PlayStation games boot on their intended BIOS.",
                actions: [.init(title: "Done", isDefault: true) { onReady?() }])
        }
    }

    private static func showError(in window: NSWindow?, message: String,
                                  preferred: PSXRegion?, onReady: (() -> Void)?) {
        AppAlert.present(
            in: window,
            symbol: "exclamationmark.triangle",
            title: "That File Won’t Work",
            message: message + "\n\nA PlayStation BIOS is a 512 KB file dumped from your own console.",
            actions: [
                .init(title: "Cancel", isCancel: true),
                .init(title: "Choose Another…", isDefault: true) {
                    chooseFile(in: window, preferred: preferred, onReady: onReady)
                },
            ])
    }
}
