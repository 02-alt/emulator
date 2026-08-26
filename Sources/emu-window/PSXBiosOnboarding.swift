import AppKit
import UniformTypeIdentifiers

/// The one-time, friendly "set up PlayStation" flow — a themed card, not a scary error. It explains
/// why a BIOS is needed, lets the user pick their own dump, validates it, and confirms success.
/// Triggered from the app menu and (once PS1 launch is wired) from a `.biosRequired` at launch.
@MainActor
enum PSXBiosOnboarding {

    /// Present the onboarding over `window`. `onReady` fires only if a valid BIOS ends up installed
    /// (either it already was, or the user just added one) — callers use it to continue into a launch.
    static func present(in window: NSWindow?, onReady: (() -> Void)? = nil) {
        if PSXBios.isInstalled {
            confirmReady(in: window, alreadyHad: true, onReady: onReady)
            return
        }
        explain(in: window, onReady: onReady)
    }

    private static func explain(in window: NSWindow?, onReady: (() -> Void)?) {
        AppAlert.present(
            in: window,
            symbol: "cpu",
            title: "Set Up PlayStation",
            message: """
            PlayStation games need your console’s start-up file — its BIOS — to run. You only add it once.

            It’s a 512 KB file, usually named something like scph5501.bin, dumped from a PlayStation you own. Choose it below and you’re set.
            """,
            actions: [
                .init(title: "Not Now", isCancel: true),
                .init(title: "Choose BIOS File…", isDefault: true) {
                    chooseFile(in: window, onReady: onReady)
                },
            ])
    }

    private static func chooseFile(in window: NSWindow?, onReady: (() -> Void)?) {
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
                let name = try PSXBios.install(from: url)
                confirmReady(in: window, alreadyHad: false, installedName: name, onReady: onReady)
            } catch {
                showError(in: window, message: error.localizedDescription, onReady: onReady)
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    private static func confirmReady(in window: NSWindow?, alreadyHad: Bool,
                                     installedName: String? = nil, onReady: (() -> Void)?) {
        let detail = installedName.map { "Installed \($0)." }
            ?? PSXBios.installedDescription.map { "Using \($0)." }
            ?? ""
        AppAlert.present(
            in: window,
            symbol: "checkmark.circle",
            title: alreadyHad ? "PlayStation Is Ready" : "You’re All Set",
            message: (alreadyHad
                ? "Your PlayStation BIOS is already installed. PlayStation games are ready to play."
                : "Your PlayStation BIOS is installed. PlayStation games are ready to play.")
                + (detail.isEmpty ? "" : "\n\n\(detail)"),
            actions: [.init(title: "Done", isDefault: true) { onReady?() }])
    }

    private static func showError(in window: NSWindow?, message: String, onReady: (() -> Void)?) {
        AppAlert.present(
            in: window,
            symbol: "exclamationmark.triangle",
            title: "That File Won’t Work",
            message: message + "\n\nA PlayStation BIOS is a 512 KB file dumped from your own console.",
            actions: [
                .init(title: "Cancel", isCancel: true),
                .init(title: "Choose Another…", isDefault: true) {
                    chooseFile(in: window, onReady: onReady)
                },
            ])
    }
}
