import AppKit
import LibraryKit

// Milestone M6 — the app now opens to a wooden shelf **Library**; selecting a game opens a
// **Play** window (the skeuomorphic console shell from M2–M5). Direct play is still available:
//   emu-window --rom <path.gba>     (skip the library, play immediately)
//   emu-window --mock               (run the mock core in a play window)
//
// Controls (play window): Arrows = D-pad · Z=A · X=B · A=L · S=R · Return=Start · RShift=Select
//                         F5 quicksave · F9 quickload

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var library: LibraryWindowController?
    private var playControllers: [PlayWindowController] = []
    private var settings: SettingsWindowController?   // one shared window for library + play
    private var continueItem: NSMenuItem?             // File ▸ Continue “…” — refreshed as the menu opens

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIcon()
        AmbientPlayer.shared.apply()   // resume any saved background ambience; then it self-drives
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--rom"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            openPlay(romURL: url, title: "\(AppInfo.name) — \(url.lastPathComponent)", gameID: nil)
        } else if args.contains("--mock") {
            openPlay(romURL: nil, title: "\(AppInfo.name) — mock core", gameID: nil)
        } else {
            let lib = LibraryWindowController()
            lib.onOpenSettings = { [weak self] in self?.openSettings() }
            lib.show()
            library = lib
            installMenu(addGamesTarget: lib)
        }
    }

    /// Set the Dock/app icon from the bundled `AppIcon.icns`. We run as a plain SPM executable
    /// (no `.app` bundle / Info.plist), so there's no `CFBundleIconFile` to pick it up — we set
    /// `applicationIconImage` at launch instead. Harmless no-op if the resource is ever missing.
    private func applyDockIcon() {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else {
            NSLog("emu-window: AppIcon.icns resource missing — using default Dock icon")
            return
        }
        NSApp.applicationIconImage = image
    }

    /// Minimal main menu so the app has Quit + "Add Games…" (⌘O) — the dashboard itself takes
    /// drag-and-drop, but a menu affordance keeps import discoverable.
    private func installMenu(addGamesTarget: LibraryWindowController) {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let reveal = NSMenuItem(title: "Reveal Crash Reports…",
                                action: #selector(revealCrashReports), keyEquivalent: "")
        reveal.target = self
        appMenu.addItem(reveal)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        // We drive the Continue item's title/thumbnail/enabled state ourselves in menuNeedsUpdate,
        // so opt out of AppKit's automatic enabling (it would light up Continue even with no game).
        fileMenu.autoenablesItems = false
        fileMenu.delegate = self
        let cont = NSMenuItem(title: "Continue",
                              action: #selector(LibraryWindowController.continueLastPlayed), keyEquivalent: "l")
        cont.target = addGamesTarget
        continueItem = cont
        fileMenu.addItem(cont)
        fileMenu.addItem(.separator())
        let add = NSMenuItem(title: "Add Games…", action: #selector(LibraryWindowController.addGames), keyEquivalent: "o")
        add.target = addGamesTarget
        fileMenu.addItem(add)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Standard Edit menu so text fields (e.g. RetroAchievements login) get Cut/Copy/Paste/Select All.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    /// Refresh the File ▸ Continue item just before the menu shows (and before ⌘L validates), so it
    /// always names the game you'd actually resume. Disabled with a plain "Continue" title when the
    /// library is empty or nothing's been played yet.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = continueItem else { return }
        if let game = library?.lastPlayedGame {
            item.title = "Continue “\(game.displayTitle)”"
            item.isEnabled = true
            item.image = continueThumbnail(for: game)
        } else {
            item.title = "Continue"
            item.isEnabled = false
            item.image = nil
        }
    }

    /// A small cover thumbnail for the Continue item — the skeuomorphic touch that makes the menu feel
    /// like the shelf. 18pt tall, width scaled from the art's own aspect. Nil if no cover on disk.
    private func continueThumbnail(for game: Game) -> NSImage? {
        guard let url = game.coverURL, let src = NSImage(contentsOf: url), src.size.height > 0 else { return nil }
        let height: CGFloat = 18
        let width = (height * src.size.width / src.size.height).rounded()
        let size = NSSize(width: max(width, 1), height: height)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }

    @objc private func revealCrashReports() {
        let dir = CrashReporter.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Present the single shared Settings window (from the menu, the library, or a play window).
    @objc private func openSettings() {
        let controller = settings ?? SettingsWindowController()
        settings = controller
        controller.onClose = { [weak self] in self?.library?.refreshAchievements() }
        controller.onResetImageCache = { [weak self] in self?.library?.resetImageCache() }
        controller.show()
    }

    private func openPlay(romURL: URL?, title: String, gameID: UUID?) {
        let controller = PlayWindowController(romURL: romURL, title: title)
        controller.onClose = { [weak self, weak controller] in
            guard let controller else { return }
            DispatchQueue.main.async { self?.playControllers.removeAll { $0 === controller } }
        }
        controller.onPlaytime = { [weak self] seconds in
            if let gameID { self?.library?.recordPlaytime(gameID: gameID, seconds: seconds) }
        }
        playControllers.append(controller)
    }

    func applicationWillTerminate(_ notification: Notification) {
        playControllers.forEach { $0.saveAndStop() }
        library?.saveActivePlay()   // persist the game running inside the library window, if any
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

CrashReporter.install()   // catch crashes as early as possible

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
