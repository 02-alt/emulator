import AppKit
import LibraryKit
import UniformTypeIdentifiers

/// The library window — an Analogue-OS-style console dashboard (`LibraryDashboardView`): a cartridge
/// carousel + inline detail, navigated with the keyboard/controller. Return launches a play window;
/// Delete removes from the library; ROMs can be dragged in or added via the menu.
@MainActor
final class LibraryWindowController: NSObject {
    private let window: NSWindow
    private let store = LibraryStore()
    private let covers = CoverArtService()
    private let dashboard = LibraryDashboardView()

    // Reads cross-device Continuity sessions (e.g. from the iPhone) to offer "Continue from iPhone"
    // in the shelf's Continue row. Read-only for now — the Mac doesn't publish its own sessions yet.
    private let continuity = ContinuityService()

    private let slotStride = 1000   // slot bookkeeping for stable ordering (paging is gone)

    // The game plays *inside this window*, in place of the shelf — swapped back when the player exits.
    private var playSession: PlaySession?
    private var playingGame: Game?   // the Game backing `playSession`, for Continuity publishing
    // Publishes cross-device state when the app deactivates. nonisolated(unsafe) so the nonisolated
    // deinit can remove it — it's only ever touched on the main thread (set in init, read in deinit).
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    /// Whether a game is currently running inside the library window (drives the app's terminate flush).
    var hasActivePlay: Bool { playSession != nil }
    private var savedToolbar: NSToolbar?
    private var savedContentSize: NSSize?    // library window size, restored when the game exits
    private var savedMinSize: NSSize?
    private var launchCinematic: LaunchCinematic?   // the play-cartridge → boot-clip launch animation
    /// Master switch for the launch cinematic.
    private let launchCinematicEnabled = true

    // Held while the per-game settings sheet is up.
    private var gameSettings: GameSettingsWindowController?

    // Lets a connected controller drive the shelf carousel. Goes dormant while a game plays in this
    // same window (the play session owns the controller then — see `presentPlay`/`dismissPlay`).
    private let menuInput = MenuControllerInput()

    /// Open the shared app Settings window (owned by the app so the library and every play window
    /// present the same one).
    var onOpenSettings: (() -> Void)?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        setupUI()
        scanRomsFolder()   // creates the ROMs folder if missing + picks up any ROMs dropped into it
        reload()
        backfillArt()      // re-fetch any missing covers (offline at import, or a cleared cache)
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(dashboard)
        NSApp.activate(ignoringOtherApps: true)
        presentLaunchNotices()
    }

    /// The one-time notices that greet a launch, in priority order so they never stack: a crash report
    /// (if we died last run), then the "What's new" card (once per update), then an update offer (if a
    /// newer build is out). Whichever shows first wins the screen; the rest defer to a later launch.
    /// Deferred to the next run loop so they land after the window is fully on screen.
    private func presentLaunchNotices() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.presentCrashReportIfNeeded() { return }
            if WhatsNew.maybeShow(in: self.window) { return }
            LaunchUpdatePrompt.checkAndPrompt(in: self.window)
        }
    }

    /// If the app crashed on a previous run, surface a one-time, non-fatal notice offering the
    /// diagnostic log. Returns whether a report was pending (and thus a card shown).
    @discardableResult
    private func presentCrashReportIfNeeded() -> Bool {
        guard let report = CrashReporter.pendingReport() else { return false }
        AppAlert.present(in: window, symbol: "exclamationmark.triangle",
            title: "The app closed unexpectedly last time",
            message: "Sorry about that — your library and saves are safe. A diagnostic report was "
                + "saved; you can reveal it in Finder to keep or share it.",
            actions: [
                AppAlert.Action(title: "Reveal Report") {
                    NSWorkspace.shared.activateFileViewerSelecting([report])
                },
                AppAlert.Action(title: "OK", isDefault: true, isCancel: true),
            ])
        return true
    }

    /// The shelf's text/buttons dissolve over exactly the cart's **lift** (initial → centre position), so
    /// they're completely gone by the time it reaches centre and holds — before it drops away.
    private var chromeDissolveDuration: CFTimeInterval {
        CFTimeInterval(LaunchAnimationConfig.shared.liftDuration * LaunchAnimationConfig.shared.textFade)
    }

    /// Re-fetch RetroAchievements progress for the current selection (after the user signs in).
    func refreshAchievements() { dashboard.refreshAchievements() }

    /// Open the shared app Settings window (Video · Audio · Emulation · Achievements · Storage).
    func showSettings() { onOpenSettings?() }

    // MARK: - UI

    private func setupUI() {
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = DS.Color.background
        window.animationBehavior = .none   // avoid AppKit's crash-prone window transform animation
        window.isReleasedWhenClosed = false   // ARC owns the strong `let window`; no double-release
        // Keep the window wide enough that the in-game control bar always fits (it's the same window).
        window.contentMinSize = NSSize(width: 820, height: 600)

        // Native unified toolbar + titlebar (HIG chrome), but transparent so the black content
        // shows through the top bar — no toolbar material, no baseline separator.
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "LibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.delegate = self   // re-scan the ROMs folder when the window regains focus

        dashboard.onLaunch = { [weak self] in self?.launch($0) }
        dashboard.onRemove = { [weak self] in self?.remove($0) }
        dashboard.onGameSettings = { [weak self] in self?.openGameSettings($0) }
        dashboard.onToggleFavorite = { [weak self] in self?.toggleFavorite($0) }
        dashboard.onToggleHidden = { [weak self] in self?.toggleHidden($0) }
        dashboard.onReveal = { [weak self] in self?.revealROM($0) }
        dashboard.onDropURLs = { [weak self] in self?.importURLs($0) }
        dashboard.onAddROMs = { [weak self] in self?.addGames() }
        dashboard.onConfigure = { [weak self] in self?.showSettings() }
        window.contentView = dashboard

        // Controller navigation for the menu: D-pad/stick move the carousel, A/Menu launch the
        // centered cart, X opens Settings — mirroring the ←/→/Return keyboard controls.
        menuInput.onLeft = { [weak self] in self?.dashboard.moveSelection(by: -1) }
        menuInput.onRight = { [weak self] in self?.dashboard.moveSelection(by: 1) }
        menuInput.onSelect = { [weak self] in self?.dashboard.launchSelected() }
        menuInput.onSettings = { [weak self] in self?.showSettings() }

        // When the user switches away from the app (e.g. Cmd-Tab to grab their phone) while a game's
        // running, publish the current state so another device can pick it up. Debounced, since it's
        // the natural "I'm switching devices" moment — the Mac keeps running, so the upload completes.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishContinuity(immediate: false) }
        }
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    // MARK: - Data

    private var sortedGames: [Game] {
        store.games.sorted { a, b in
            if a.favorite != b.favorite { return a.favorite }   // favorites pinned to the front
            if a.shelfIndex != b.shelfIndex { return a.shelfIndex < b.shelfIndex }
            return a.slotIndex < b.slotIndex
        }
    }

    private func reload() {
        dashboard.setGames(sortedGames)
        let n = store.games.count
        window.title = "Library"
        window.subtitle = n == 0 ? "" : "\(n) game\(n == 1 ? "" : "s")"   // native titlebar subtitle
        refreshContinueCard()
    }

    // MARK: - Cross-device Continuity

    /// Ask CloudKit whether another device left a resumable session for a game we own, and if so point
    /// the shelf's Continue row at it ("Continue from iPhone"). Cheap (metadata + thumbnail only) and
    /// best-effort — no iCloud / no session just clears the card. Fetch is off the main actor; the UI
    /// update lands back on it.
    private func refreshContinueCard() {
        let games = store.games
        Task { [weak self] in
            guard let self else { return }
            if let hit = await continuity.newestResumable(in: games) {
                dashboard.crossDeviceContinue = (
                    game: hit.game,
                    eyebrow: "CONTINUE FROM \(hit.deviceName.uppercased())",
                    onResume: { [weak self] in self?.resumeCrossDevice(hit) }
                )
                return
            }
            // No session for a game we own — fall back to a transferable session (a game we lack whose
            // source device has offered its ROM). Shown as a "Transfer from iPhone" card.
            if let offer = await continuity.newestTransferOffer(excluding: games) {
                dashboard.crossDeviceContinue = (
                    game: displayGame(for: offer),
                    eyebrow: "TRANSFER FROM \(offer.deviceName.uppercased())",
                    onResume: { [weak self] in self?.transferAndResume(offer) }
                )
                return
            }
            dashboard.crossDeviceContinue = nil
        }
    }

    /// A display-only `Game` for a transfer offer: no ROM on disk yet, just the title and (if present)
    /// the card's thumbnail written out so the Continue row can show cover + title. The real Game is
    /// created by `transferAndResume` after the ROM downloads and imports.
    private func displayGame(for offer: CrossDeviceTransfer) -> Game {
        var coverPath: String?
        if let png = offer.card.thumbnailPNG {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("transfer-\(offer.romHash).png")
            if (try? png.write(to: url)) != nil { coverPath = url.path }
        }
        return Game(
            title: offer.card.metadata.romTitle,
            romFilenameStem: (offer.fileName as NSString).deletingPathExtension,
            romPath: "",
            romHash: offer.romHash,
            coverPath: coverPath)
    }

    /// Accept a transfer: download the offered ROM, import it into the library, then resume the session
    /// (or launch fresh if the savestate is an incompatible core version). The ROM offer is cleared from
    /// iCloud on success so the cloud copy stays ephemeral. Falls back gracefully if the offer vanished.
    private func transferAndResume(_ offer: CrossDeviceTransfer) {
        Task { [weak self] in
            guard let self else { return }
            guard let romData = await continuity.downloadROM(romHash: offer.romHash) else {
                Toast.show(in: window, "Couldn’t fetch the game from your other device.", style: .error)
                refreshContinueCard()
                return
            }
            // Write the downloaded ROM to a temp file with its original name, then run the normal import
            // path (hash-dedupe, copy into the managed ROMs folder, place on the shelf).
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(offer.fileName)
            guard (try? romData.write(to: tmp)) != nil,
                  let base = try? ROMImporter.makeGame(from: tmp),
                  base.romHash == offer.romHash else {
                Toast.show(in: window, "That transfer didn’t match the game.", style: .error)
                return
            }
            var game = base
            if let managed = copyIntoLibrary(tmp) { game.romPath = managed.path }
            try? FileManager.default.removeItem(at: tmp)
            place(&game)
            reload()

            // ROM is now local — retire the ROM offer so it doesn't linger in iCloud. The savestate
            // *session* is intentionally left in place so the Continue card can resume it below.
            await continuity.clearROM(romHash: offer.romHash)

            // Confirm the arrival visibly rather than jumping straight into the game: a toast the user
            // can actually read, plus `refreshContinueCard` re-points the shelf's Continue row at the
            // freshly-imported game ("CONTINUE FROM <device>"). One more click resumes where they left
            // off — the same two-step the iPhone side uses.
            Toast.show(in: window, "\(game.displayTitle) — transferred from \(offer.deviceName)", style: .info)
            refreshContinueCard()
        }
    }

    /// Download the cross-device savestate and boot the game straight into it. On success the session
    /// is cleared from iCloud so it isn't offered twice (this Mac now holds the live state). If the
    /// download fails (offline, or the session was cleared elsewhere) we fall back to a normal launch.
    private func resumeCrossDevice(_ hit: CrossDeviceContinue) {
        Task { [weak self] in
            guard let self else { return }
            guard let state = await continuity.resumeState(romHash: hit.game.romHash) else {
                launch(hit.game)   // nothing to resume — just play it normally
                return
            }
            await continuity.clear(romHash: hit.game.romHash)
            dashboard.crossDeviceContinue = nil
            launch(hit.game, resumeState: state)
        }
    }

    /// Publish the in-window game's current state for cross-device resume. `immediate` awaits the
    /// upload (terminal moments: leaving the game); otherwise it's debounced (bursty app-deactivation).
    /// No-op when nothing's playing or iCloud is unavailable.
    private func publishContinuity(immediate: Bool) {
        guard let session = playSession, let game = playingGame,
              let snap = session.captureContinuitySnapshot() else { return }
        if immediate {
            Task {
                await continuity.publish(game: game, state: snap.state,
                                         thumbnailPNG: snap.thumbnailPNG, secondsPlayed: snap.seconds)
                // Terminal moment — also offer this game's ROM for transfer, if the user opted in.
                await continuity.offerROMIfEnabled(game: game)
            }
        } else {
            continuity.schedulePublish(game: game, state: snap.state,
                                       thumbnailPNG: snap.thumbnailPNG, secondsPlayed: snap.seconds)
        }
    }

    /// Publish the running game and stop it on app termination — awaited (bounded by `timeout`) so a
    /// "quit here, continue on iPhone" hand-off actually reaches iCloud without hanging the quit if the
    /// network stalls. Called from `applicationShouldTerminate`.
    func flushContinuityForTermination(timeout: Duration = .seconds(3)) async {
        if let session = playSession, let game = playingGame,
           let snap = session.captureContinuitySnapshot() {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.continuity.publish(
                    game: game, state: snap.state,
                    thumbnailPNG: snap.thumbnailPNG, secondsPlayed: snap.seconds) }
                group.addTask { try? await Task.sleep(for: timeout) }
                await group.next()   // return as soon as EITHER the upload finishes or the timeout fires
                group.cancelAll()
            }
        }
        saveActivePlay()
    }

    // MARK: - Import

    @objc func addGames() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ROMImporter.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.importURLs(panel.urls) }
        }
    }

    private func importURLs(_ urls: [URL]) {
        var added = 0, unsupported = 0, duplicates = 0, failed = 0
        for url in urls {
            guard ROMImporter.isSupported(url) else { unsupported += 1; continue }
            guard let base = try? ROMImporter.makeGame(from: url) else { failed += 1; continue }
            guard store.game(withHash: base.romHash) == nil else { duplicates += 1; continue }
            var game = base
            // Copy the ROM into the app's managed folder so the library can't break if the
            // original file is moved or deleted.
            if let managed = copyIntoLibrary(url) {
                game.romPath = managed.path
            }
            place(&game)
            added += 1
        }
        if added > 0 { reload() }
        reportImport(added: added, unsupported: unsupported, duplicates: duplicates, failed: failed)
    }

    /// Summarize an import as a non-blocking toast. A clean single-add stays silent — the new cart
    /// sliding onto the shelf is feedback enough; we only speak up when something needs explaining.
    private func reportImport(added: Int, unsupported: Int, duplicates: Int, failed: Int) {
        guard unsupported > 0 || duplicates > 0 || failed > 0 else { return }
        if added == 0 && duplicates == 0 && failed == 0 {   // only unsupported files were dropped
            Toast.show(in: window, unsupported == 1 ? "That’s not a GBA ROM." : "Those aren’t GBA ROMs.",
                       style: .error)
            return
        }
        var parts: [String] = []
        if added > 0 { parts.append("Added \(added)") }
        if duplicates > 0 { parts.append("\(duplicates) already in your library") }
        if failed > 0 { parts.append("\(failed) couldn’t be read") }
        if unsupported > 0 { parts.append("\(unsupported) skipped") }
        Toast.show(in: window, parts.joined(separator: " · "), style: added > 0 ? .info : .error)
    }

    /// Pick up ROM files the user dropped straight into the app's ROMs folder (Settings ▸ Storage ▸
    /// Reveal ROMs Folder) rather than adding them through the app. Files already in the library are
    /// skipped by hash; new ones join it in place, so no copy is made — they already live here.
    /// Runs at launch and whenever the library window regains focus (e.g. after a trip to Finder).
    func scanRomsFolder() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.romsDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return }
        var added = false
        for url in urls where ROMImporter.isSupported(url) {
            guard let base = try? ROMImporter.makeGame(from: url),
                  store.game(withHash: base.romHash) == nil else { continue }
            var game = base
            place(&game)
            added = true
        }
        if added { reload() }
    }

    /// Assign the next free shelf slot, persist the game, and kick off its cover-art fetch.
    private func place(_ game: inout Game) {
        let slot = store.nextSlot(onShelf: 0, perShelf: slotStride)
        game.shelfIndex = slot.shelf
        game.slotIndex = slot.slot
        store.add(game)
        fetchArt(for: game)
    }

    /// Copy `src` into `AppPaths.romsDir`, keeping its original human-readable filename so the folder
    /// stays browsable in Finder. Only genuinely new games reach here (callers dedupe by hash first),
    /// so a name clash means a *different* game — it gets a " (2)", " (3)"… suffix rather than
    /// overwriting. Returns the managed URL, or nil on failure (leaving the original path in place).
    private func copyIntoLibrary(_ src: URL) -> URL? {
        let dir = AppPaths.romsDir
        let ext = src.pathExtension
        let base = src.deletingPathExtension().lastPathComponent
        var dest = dir.appendingPathComponent(src.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        do { try FileManager.default.copyItem(at: src, to: dest); return dest }
        catch { NSLog("ROM copy failed: \(error)"); return nil }
    }

    private func fetchArt(for game: Game) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let url = await self.covers.fetchCover(
                forStem: game.romFilenameStem, hash: game.romHash, system: game.system) {
                var updated = game
                updated.coverPath = url.path
                self.store.update(updated)
                if let image = NSImage(contentsOf: url) {
                    self.dashboard.updateCover(for: updated.id, image: image)
                }
            }
        }
    }

    /// Wipe the downloaded art cache (box art + screenshots) and re-fetch it fresh. Games the user
    /// customised (a cropped or replaced cover) are left as-is; only plain downloaded art is reset.
    /// ROMs, saves, and captured screenshots are never touched. Invoked from Settings ▸ Storage.
    func resetImageCache() {
        ImageCache.clearDownloaded()
        for game in store.games {
            guard let path = game.coverPath else { continue }
            if path.hasSuffix("-cover.png") || path.hasSuffix("-source.png") { continue }
            var g = game
            g.coverPath = nil
            store.update(g)
        }
        reload()
        backfillArt()
    }

    /// Re-fetch a cover for every game that has none on disk — art that never downloaded (offline at
    /// import) or was cleared by ``resetImageCache`` comes back without needing a re-import.
    private func backfillArt() {
        for game in store.games where !hasCover(game) { fetchArt(for: game) }
    }

    private func hasCover(_ game: Game) -> Bool {
        guard let path = game.coverPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Per-game settings

    /// Open the per-game settings sheet (cover editing, for now). Reads the freshest copy from the
    /// store by id so a re-open reflects the last saved crop.
    private func openGameSettings(_ game: Game) {
        let latest = store.games.first { $0.id == game.id } ?? game
        let controller = GameSettingsWindowController(game: latest)
        controller.onSaved = { [weak self] updated, image in
            guard let self else { return }
            self.store.update(updated)
            if let image { self.dashboard.updateCover(for: updated.id, image: image) }
            self.reload()   // pick up title/favorite/hidden changes (reorders + re-titles the detail)
        }
        controller.onClose = { [weak self] in self?.gameSettings = nil }
        gameSettings = controller
        controller.present(in: window)
    }

    /// Toggle a game's favorite flag (favorites pin to the front of the carousel).
    private func toggleFavorite(_ game: Game) {
        guard var g = store.games.first(where: { $0.id == game.id }) else { return }
        g.isFavorite = !g.favorite
        store.update(g)
        reload()
    }

    /// Toggle a game's hidden flag (hidden carts move under the Hidden scope in the filter drawer).
    private func toggleHidden(_ game: Game) {
        guard var g = store.games.first(where: { $0.id == game.id }) else { return }
        g.isHidden = !g.hidden
        store.update(g)
        reload()
    }

    /// Reveal the game's ROM file in Finder.
    private func revealROM(_ game: Game) {
        NSWorkspace.shared.activateFileViewerSelecting([game.romURL])
    }

    // MARK: - Remove & launch

    private func remove(_ game: Game) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(game.displayTitle)” from your library?"
        alert.informativeText = "This removes it from the library and deletes the imported copy. Your saves are kept."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store.remove(id: game.id)
        // Delete the app-managed ROM copy — but only if it lives in our folder (never touch a
        // ROM the user still keeps elsewhere).
        if game.romPath.hasPrefix(AppPaths.romsDir.path) {
            try? FileManager.default.removeItem(atPath: game.romPath)
        }
        reload()
    }

    /// The most recently played game, if any — drives the File ▸ Continue menu item. Uses
    /// `lastPlayedAt`, so it reflects the literal last thing booted (favorites/hidden don't reorder it).
    var lastPlayedGame: Game? {
        store.games
            .filter { $0.lastPlayedAt != nil }
            .max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
    }

    /// Re-launch the most recently played game (File ▸ Continue “…”, ⌘L). No-op if nothing's been played.
    @objc func continueLastPlayed() {
        guard let game = lastPlayedGame else { return }
        launch(game)
    }

    private func launch(_ game: Game, resumeState: Data? = nil) {
        // The ROM file can go missing (moved/deleted since import) — don't crash trying to boot it.
        guard FileManager.default.isReadableFile(atPath: game.romPath) else {
            warn("ROM file not found",
                 "“\(game.displayTitle)” can’t be played — its ROM file appears to have been moved or deleted:\n\n\(game.romPath)")
            return
        }
        // Make sure the core can actually load it — a corrupt/truncated ROM shows an alert instead of
        // failing deep in the launch (or falling back to the mock core mid-cinematic).
        guard PlaySession.canOpen(game.romURL) else {
            warn("This game can’t be opened",
                 "“\(game.displayTitle)” couldn’t be loaded — the ROM file may be corrupted or incomplete. Try re-importing it from a known-good copy.")
            return
        }
        var updated = game
        updated.lastPlayedAt = Date()
        store.update(updated)

        // Hand the controller to the game for the whole launch (cinematic included) — the play
        // session's own manager takes over; the shelf stops listening until we return to it.
        menuInput.isActive = false

        // The launch cinematic (cart lifts off the shelf → seats with the "cha-chunk" → GBA startup
        // clip) is written and lives in `LaunchCinematic`, but disabled for now — it still needs work.
        // Flip `launchCinematicEnabled` to bring it back. For now, boot straight in with the sound cue.
        guard launchCinematicEnabled, launchCinematic == nil,
              let tileFrame = dashboard.tileFrame(for: updated) else {
            SoundFX.shared.playCartridgeInsert()   // the cinematic plays its own seat cue when enabled
            presentPlay(updated, resumeState: resumeState)
            return
        }
        dashboard.setLaunchTileHidden(true, for: updated)   // its copy is lifted by the cinematic
        dashboard.setLaunchChrome(hidden: true, duration: chromeDissolveDuration)
        let cinematic = LaunchCinematic(
            parent: window, game: updated, startFrame: tileFrame,
            onPresentGame: { [weak self] in self?.presentPlay(updated, resumeState: resumeState) },
            onDone: { [weak self] in
                self?.dashboard.setLaunchTileHidden(false, for: updated)
                self?.dashboard.setLaunchChrome(hidden: false, duration: 0.2)
                self?.launchCinematic = nil
            })
        launchCinematic = cinematic
        cinematic.start()
    }

    // MARK: - In-window play

    /// Swap the shelf out for the game, played **inside this same window**. The player returns to the
    /// shelf via the footer LIBRARY button or Esc (``dismissPlay``). Returns the game screen's rect (in
    /// content-view coordinates) so the launch cinematic can morph the boot clip into it.
    @discardableResult
    private func presentPlay(_ game: Game, resumeState: Data? = nil) -> CGRect {
        let overrides = GameOverrides(
            filter: game.overrideFilter.flatMap { Settings.DisplayFilter(rawValue: $0) },
            speed: game.overrideSpeed,
            swapAB: game.overrideSwapAB)
        let session = PlaySession(romURL: game.romURL,
                                  title: "\(AppInfo.name) — \(game.displayTitle)",
                                  overrides: overrides,
                                  resumeState: resumeState)
        session.onExit = { [weak self] in self?.dismissPlay() }
        session.onPlaytime = { [weak self] seconds in
            self?.recordPlaytime(gameID: game.id, seconds: seconds)
        }
        playSession = session
        playingGame = game   // remembered for Continuity publishing on exit / deactivation / quit

        savedContentSize = window.contentRect(forFrameRect: window.frame).size   // remember shelf size
        savedMinSize = window.contentMinSize
        savedToolbar = window.toolbar
        window.toolbar = nil
        window.title = game.displayTitle
        window.subtitle = ""
        window.backgroundColor = PlayVoidView.backgroundTop   // blend the titlebar into the player
        window.contentView = session.view                     // enters Fill mode (game edge-to-edge)
        window.makeFirstResponder(session.keyView)

        // The player fills the window (Fill mode). Lock the window to the game's native aspect (3:2 for
        // GBA, 10:9 for Game Boy / Color) and default it to that shape so the game fills edge-to-edge
        // with no letterbox bars — and stays bar-free on resize. The shelf's own size is restored on exit.
        let aspect = game.system.screenAspect
        let w = savedContentSize?.width ?? 1040
        window.contentMinSize = NSSize(width: (320 * aspect).rounded(), height: 320)
        window.contentAspectRatio = NSSize(width: game.system.screenSize.width,
                                           height: game.system.screenSize.height)
        window.setContentSize(NSSize(width: w, height: (w / aspect).rounded()))

        session.view.layoutSubtreeIfNeeded()   // lay the player out now so the screen rect is final
        // Default to edge-to-edge Fill (deferred so it wins over the launch cinematic's re-parenting).
        DispatchQueue.main.async { [weak session] in session?.enterFill() }
        if session.audioStartFailed {
            Toast.show(in: window, "Sound is unavailable right now.", style: .error)
        }
        return session.gameScreenFrame
    }

    /// Tear the running game down (saving state) and restore the shelf.
    private func dismissPlay() {
        guard let session = playSession else { return }
        publishContinuity(immediate: true)   // hand this session off for cross-device resume (before teardown)
        session.saveAndStop()
        playSession = nil
        playingGame = nil

        window.contentView = dashboard   // leaving Fill restores the native titlebar
        // Drop the 3:2 play lock and restore the shelf's size.
        window.contentResizeIncrements = NSSize(width: 1, height: 1)   // clears the aspect constraint
        if let minSize = savedMinSize { window.contentMinSize = minSize }
        window.toolbar = savedToolbar
        window.backgroundColor = DS.Color.background   // back to the shelf's pure black
        if let size = savedContentSize { window.setContentSize(size) }
        reload()   // restores the "Library" title + game-count subtitle
        window.makeFirstResponder(dashboard)
        menuInput.isActive = true   // shelf is back — resume controller navigation
    }

    /// Save the running game (if any) — called on app termination.
    func saveActivePlay() { playSession?.saveAndStop() }

    private func warn(_ title: String, _ info: String) {
        // Prefer the themed in-window alert; fall back to a system alert only if there's no window yet.
        if AppAlert.present(in: window, title: title, message: info) { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Accumulate a finished play session's duration into the game's total (M8 playtime tracking).
    func recordPlaytime(gameID: UUID, seconds: Int) {
        guard seconds > 0, var game = store.games.first(where: { $0.id == gameID }) else { return }
        game.secondsPlayed += seconds
        store.update(game)
    }
}

// MARK: - Downloaded art cache

/// The app's downloadable art cache: box art + game screenshots pulled from the public libretro
/// thumbnails repo. Everything here re-downloads on demand, so it's safe to wipe.
enum ImageCache {
    /// Delete only *downloaded* art — box art (`<hash>.png`) and screenshots. User-customised covers
    /// (`-source.png` / `-cover.png`), the user's captured screenshots, ROMs, and saves are untouched.
    static func clearDownloaded() {
        let fm = FileManager.default
        if let covers = try? fm.contentsOfDirectory(at: AppPaths.coversDir, includingPropertiesForKeys: nil) {
            for url in covers {
                let name = url.lastPathComponent
                if name.hasSuffix("-source.png") || name.hasSuffix("-cover.png") { continue }
                try? fm.removeItem(at: url)
            }
        }
        if let snaps = try? fm.contentsOfDirectory(at: AppPaths.snapsDir, includingPropertiesForKeys: nil) {
            for url in snaps { try? fm.removeItem(at: url) }
        }
    }
}

// MARK: - Toolbar (native macOS chrome)

extension LibraryWindowController: NSWindowDelegate {
    /// Coming back from Finder (where the user may have just dropped a ROM into the folder) refreshes
    /// the library so freshly-added games appear without a relaunch.
    func windowDidBecomeKey(_ notification: Notification) {
        guard playSession == nil else { return }   // don't disturb an in-progress play session
        scanRomsFolder()
    }
}

extension LibraryWindowController: NSToolbarDelegate {
    // The toolbar is kept only for the unified titlebar chrome — it carries no items now. The library
    // scope (All Games / Hidden) lives in the pull-up FilterDrawer above the footer bar, and
    // Add ROMs lives in the footer glass buttons.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
}
