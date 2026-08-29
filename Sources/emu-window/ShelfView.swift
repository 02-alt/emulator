import AppKit
import LibraryKit
import QuartzCore

/// The library screen, modeled on **Analogue OS**: a horizontal cartridge carousel with the
/// selected cart centered (coverflow-style), an inline detail panel beneath (title +
/// metadata table with pixel chips), a top bar (logo · "Library" · L/R), and a bottom bar
/// (page dots + button-prompt actions). Navigated like a console — ←/→ move, Return plays,
/// Delete removes. Games can also be dragged in.
@MainActor
final class LibraryDashboardView: NSView {
    var onLaunch: ((Game) -> Void)?
    var onRemove: ((Game) -> Void)?
    var onGameSettings: ((Game) -> Void)?
    var onToggleFavorite: ((Game) -> Void)?
    var onToggleHidden: ((Game) -> Void)?
    var onReveal: ((Game) -> Void)?
    /// (game, targetDevice) — targetDevice nil means broadcast to all the user's devices.
    var onContextSend: ((Game, String?) -> Void)?
    /// Open the multi-select send picker with `Game` pre-selected — "Send Multiple…" in a cart's menu.
    var onContextSendMultiple: ((Game) -> Void)?
    /// Show a PlayStation game's memory card — "Memory Card…" in a cart's menu.
    var onContextMemoryCard: ((Game) -> Void)?
    var onDropURLs: (([URL]) -> Void)?
    /// The user's other devices, cached by the controller and read when a tile's right-click menu
    /// opens, so "Send to →" can list them without an async hop mid-menu.
    var sendTargets: [String] = []

    var onConfigure: (() -> Void)?    // opens Settings (not per-game)
    var onAddROMs: (() -> Void)?
    /// Right-click "Dismiss" on the cross-device Continue/Transfer card — hides just the one showing.
    var onCrossDeviceDismiss: (() -> Void)?

    /// Which slice of the library the carousel shows, driven by the pull-up filter drawer.
    /// `.system` narrows to one console (only offered when the library holds more than one).
    enum Scope: Equatable { case all, system(GameSystem), hidden }

    private var allGames: [Game] = []          // everything in the library
    private var games: [Game] = []             // the visible slice (after the scope filter)
    private var scope: Scope = .all
    private var scopeOptions: [Scope] = [.all, .hidden]   // drawer segments, in order (mirrors the titles)
    private var tiles: [CartridgeTileView] = []
    private var actionBar: GlassBar?           // Apple-Music-style footer capsule of actions
    private var ambiencePopover: NSPopover?     // background-sound picker, hung off the footer bar
    private var ambienceMonitor: Any?           // outside-click monitor while that popover is open
    private var continueBanner: ContinueBanner?   // top-left "Continue" pill for the last-played game
    private var continueBannerVisible = false
    private let filterDrawer = FilterDrawer(titles: ["All Games", "Hidden"])
    private let dropOverlay = DropTargetOverlay()   // shown only while a valid ROM drag hovers
    private var bandTracking: NSTrackingArea?   // reveals the drawer handle on bottom-bar hover
    private var carouselTracking: NSTrackingArea?  // mouse-moved over the carousel, to self-heal scales
    private var selected = 0
    private var scrubbing = false                // true between a drag's .began and .ended
    private var dragOffsetX: CGFloat = 0         // live horizontal shift while dragging the carousel
    private var lastDragX: CGFloat = 0           // velocity tracking for momentum on release
    private var lastDragT: CFTimeInterval = 0
    private var dragVelocity: CGFloat = 0        // points/sec, +right
    private var settleVelocityX: CGFloat = 0     // release velocity handed to the settle spring (once)

    /// Drives the detail panel's transition when the selection changes: 0 → 1 as the outgoing game's
    /// info dissolves + slides out and the incoming game's info dissolves + slides in, moving in the
    /// scrub direction so the text travels with the cartridges (custom-drawn, so CA can't tween it).
    private lazy var detailXfade = ValueAnimator(1)
    private var detailDir: CGFloat = 1              // +1 = moving to a later game, −1 = earlier
    private let detailSlideDistance: CGFloat = 90   // how far the info glides during the morph

    /// A frozen copy of the previously-selected game's info, drawn sliding away during the morph.
    private struct DetailSnapshot {
        let game: Game
        let groups: [[(String, String?)]]
        let ra: RAState
    }
    private var detailOutgoing: DetailSnapshot?

    /// What to show in the trophies column for the selected game. Every case draws *something* so the
    /// panel is never a silent void.
    enum RAState {
        case hidden          // not a system RA supports — draw nothing
        case notConfigured   // no credentials — prompt to sign in
        case loading         // fetch in flight
        case notFound        // ROM isn't a game RA tracks
        case failed          // couldn't reach RA (offline / bad key)
        case loaded(RAGameProgress)
    }

    /// Cached metadata rows for the selected game — computed once per selection (they read the ROM
    /// and save files), never during drawing, which repeats every crossfade frame.
    private var detailGroups: [[(String, String?)]] = []
    private var detailGameID: UUID?
    private var detailRA: RAState = .hidden     // RetroAchievements state for the selected game

    // Layout metrics. Every size below is a *base* value at the design reference size; the shelf reads
    // them through `contentScale` so the whole dashboard — cartridges, margins, type, detail table —
    // grows together on larger/fullscreen windows (see `contentScale`, `sc`, `scf`).
    private let bottomBarHBase: CGFloat = 76
    private let carouselTopMinBase: CGFloat = 36
    private let continueBannerHBase: CGFloat = 46
    private let continueBannerTopBase: CGFloat = 16
    private let tileSideBase: CGFloat = 285
    private let tileGapBase: CGFloat = 36
    private let labelXBase: CGFloat = 40
    private let titleToContentGapBase: CGFloat = 74

    private var bottomBarH: CGFloat { sc(bottomBarHBase) }        // footer band height
    /// Lift the footer capsule off the very bottom edge so it isn't cramped against the window frame
    /// (HIG breathing room) — applied to both the capsule's layout and its hover tracking so they stay
    /// in sync.
    private var footerBottomInset: CGFloat { sc(10) }
    private var carouselTopMin: CGFloat { sc(carouselTopMinBase) }   // top margin before we can center
    private var continueBannerH: CGFloat { sc(continueBannerHBase) }   // the Continue row's height
    private var continueBannerTop: CGFloat { sc(continueBannerTopBase) }   // its inset from the top edge
    private var tileSide: CGFloat { sc(tileSideBase) }
    private var tileGap: CGFloat { sc(tileGapBase) }
    private var labelX: CGFloat { sc(labelXBase) }      // content left margin
    /// Vertical gap from the top of the title down to the first metadata/trophies row.
    private var titleToContentGap: CGFloat { sc(titleToContentGapBase) }

    /// Top space reserved for the Continue row, so the carousel+detail block centers *below* it and
    /// never overlaps (zero when there's nothing to resume).
    private var continueTopInset: CGFloat { continueBannerVisible ? continueBannerTop + continueBannerH + sc(14) : 0 }

    /// Uniform scale for the whole dashboard, driven by window size relative to the design reference
    /// (~1040×820). Never shrinks below 1 (small windows look as before); clamped so it can't blow up
    /// on ultrawide displays. This is the one knob that makes the shelf fill a fullscreen window.
    private var contentScale: CGFloat {
        let s = min(bounds.width / 1040, bounds.height / 820)
        return min(max(s, 1), 1.6)
    }
    /// Scale a layout metric.
    private func sc(_ v: CGFloat) -> CGFloat { v * contentScale }
    /// Scale a font point size, rounded to a whole point so the pixel face stays crisp.
    private func scf(_ v: CGFloat) -> CGFloat { (v * contentScale).rounded() }

    /// Y of the carousel's top. The carousel + detail panel form one block; center it vertically in
    /// the space above the bottom bar so a taller window doesn't leave a big void beneath the detail
    /// (falls back to a fixed top margin once the block no longer fits).
    private var carouselTop: CGFloat {
        let rows = detailGroups.reduce(0) { $0 + $1.count }
        // Detail height below the cartridge square: 40pt gap + title band + metadata rows.
        let detailH: CGFloat = selectedGame == nil
            ? tileSide / 2
            : sc(40) + titleToContentGap + CGFloat(rows) * sc(20) + CGFloat(detailGroups.count) * sc(14)
        let blockH = tileSide + detailH
        let inset = continueTopInset
        return max(carouselTopMin + inset, inset + (bounds.height - inset - bottomBarH - blockH) / 2)
    }

    override var isFlipped: Bool { true }        // top-left origin, top-to-bottom
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = DS.Color.background.cgColor
        registerForDraggedTypes([.fileURL])
        detailXfade.onChange = { [weak self] v in
            self?.needsDisplay = true
            if v >= 0.999 { self?.detailOutgoing = nil }   // morph done — drop the old copy
        }

        // Library scope, tucked into a pull-up drawer above the footer bar (see FilterDrawer).
        addSubview(filterDrawer)
        filterDrawer.onSelect = { [weak self] idx in
            guard let self, self.scopeOptions.indices.contains(idx) else { return }
            self.setScope(self.scopeOptions[idx])
        }
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// The metadata value column — a fixed indent from the label margin (doesn't spread on resize).
    private var contentX: CGFloat { labelX + sc(180) }

    private var selectedGame: Game? { games.indices.contains(selected) ? games[selected] : nil }

    /// The on-screen frame (this view's flipped coordinates) of the cartridge tile for `game`, if it's
    /// currently in the carousel — the launch cinematic starts its cartridge here so the insert reads
    /// as the same cart lifting straight off the shelf.
    func tileFrame(for game: Game) -> CGRect? {
        tiles.first { $0.game.id == game.id }?.frame
    }

    /// Hide (or restore) a single cartridge tile while the launch cinematic lifts its own copy off the
    /// shelf — so the shelf's tile doesn't sit as a duplicate behind the animated one.
    func setLaunchTileHidden(_ hidden: Bool, for game: Game) {
        tiles.first { $0.game.id == game.id }?.isHidden = hidden
    }

    /// How much of the shelf's own content is showing (1 = fully, 0 = dissolved) — the launch cinematic
    /// fades this to 0 as the cartridge lifts off, so the detail text dissolves cleanly to black.
    private var launchChromeAlpha: CGFloat = 1
    private lazy var launchChromeFade = ValueAnimator(1)
    /// While dissolving, `layout()` is frozen so it can't re-lay the tiles and reset their opacity (which
    /// would clobber the fade — that's why the side cartridges kept showing).
    private var launchDissolving = false

    /// Dissolve (or restore) everything the shelf draws itself — the detail text, footer/admin buttons,
    /// the filter drawer, and the side cartridges — leaving only the black background as the launch
    /// cinematic carries the selected cart away. Nothing is left on the shelf as it goes.
    func setLaunchChrome(hidden: Bool, duration: CFTimeInterval) {
        launchDissolving = hidden
        // Disable each tile's own hover while dissolving — otherwise mousing over a fading side cart
        // re-asserts its opacity and it pops back into view.
        tiles.forEach { $0.hoverEnabled = !hidden }
        let target: CGFloat = hidden ? 0 : 1
        if !hidden {                                   // restore: re-lay the tiles to their resting look
            tiles.forEach { $0.alphaValue = 1 }
            layoutTiles(animated: false)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = Motion.timing
            actionBar?.animator().alphaValue = target
            filterDrawer.animator().alphaValue = target
            if continueBannerVisible { continueBanner?.animator().alphaValue = target }
            if hidden {
                for t in tiles where !t.isHidden {
                    // Start from what's actually on screen (side carts sit at ~0.4) so there's no flash.
                    t.alphaValue = CGFloat(t.layer?.presentation()?.opacity ?? t.layer?.opacity ?? 1)
                    t.animator().alphaValue = 0
                }
            }
        }
        launchChromeFade.onChange = { [weak self] v in self?.launchChromeAlpha = v; self?.needsDisplay = true }
        launchChromeFade.animate(to: target, duration: duration)
    }

    /// The currently-selected game.
    var currentGame: Game? { selectedGame }

    // MARK: - Data

    func setGames(_ games: [Game]) {
        allGames = games
        refreshScopeOptions()
        applyFilter(resetSelection: false)
    }

    /// Rebuild the drawer's segments from what's in the library: **All Games**, then one segment per
    /// console present (only when more than one console is present — a single-system library needs no
    /// per-console filter), then **Hidden**. Keeps the current scope selected if it's still on offer,
    /// otherwise falls back to All Games.
    private func refreshScopeOptions() {
        let systems = GameSystem.allCases.filter { sys in
            allGames.contains { !$0.hidden && $0.system == sys }
        }
        var options: [Scope] = [.all]
        if systems.count > 1 { options += systems.map { .system($0) } }
        options.append(.hidden)

        scopeOptions = options
        if !options.contains(scope) { scope = .all }
        let selectedIdx = options.firstIndex(of: scope) ?? 0
        filterDrawer.setOptions(options.map(title(for:)), selected: selectedIdx)
        needsLayout = true   // segment widths may have changed → re-center the drawer
    }

    /// Human label for a scope segment.
    private func title(for scope: Scope) -> String {
        switch scope {
        case .all:            return "All Games"
        case .system(let s):  return s.shortName
        case .hidden:         return "Hidden"
        }
    }

    /// Recompute the visible slice from the current scope, then rebuild the carousel. Hidden games are
    /// tucked away from every normal scope and only surface under the dedicated Hidden scope.
    private func applyFilter(resetSelection: Bool) {
        switch scope {
        case .all:            games = allGames.filter { !$0.hidden }
        case .system(let s):  games = allGames.filter { !$0.hidden && $0.system == s }
        case .hidden:         games = allGames.filter { $0.hidden }
        }
        selected = resetSelection ? 0 : min(selected, max(0, games.count - 1))

        tiles.forEach { $0.removeFromSuperview() }
        tiles = games.map { game in
            let t = CartridgeTileView(game: game)
            t.onClick = { [weak self] g in self?.tileClicked(g) }
            t.onPlay = { [weak self] in self?.onLaunch?(game) }
            t.onToggleFavorite = { [weak self] in self?.onToggleFavorite?(game) }
            t.onToggleHidden = { [weak self] in self?.onToggleHidden?(game) }
            t.onReveal = { [weak self] in self?.onReveal?(game) }
            t.onContextRemove = { [weak self] in self?.onRemove?(game) }
            t.onContextSettings = { [weak self] in self?.onGameSettings?(game) }
            t.onContextSendTo = { [weak self] target in self?.onContextSend?(game, target) }
            t.onContextSendMultiple = { [weak self] in self?.onContextSendMultiple?(game) }
            t.onContextMemoryCard = { [weak self] in self?.onContextMemoryCard?(game) }
            t.sendTargets = { [weak self] in self?.sendTargets ?? [] }
            t.onCarouselDrag = { [weak self] phase, dx in self?.handleCarouselDrag(phase, dx) }
            addSubview(t)
            return t
        }
        rebuildPrompts()
        refreshDetail()
        refreshContinueBanner()
        layoutTiles(animated: false)
        // A reload while the search overlay is up rebuilds the tiles/chrome (un-hiding them) and adds
        // them above the overlay — re-hide the shelf and keep the overlay front-most.
        if let overlay = searchOverlay {
            setShelfContentHidden(true)
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        needsDisplay = true
    }

    /// The most recently played game across the whole library (not just the visible slice) — drives
    /// the Continue pill. Uses `lastPlayedAt`, so it's the literal last thing booted.
    private var lastPlayedGame: Game? {
        allGames.filter { $0.lastPlayedAt != nil }
            .max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
    }

    /// A cross-device Continuity session (e.g. from the iPhone) to surface in the Continue row instead
    /// of the local last-played game. When set, the row reads "CONTINUE FROM <device>" and its click
    /// resumes that session; the owner (LibraryWindowController) fills this in from `ContinuityService`.
    var crossDeviceContinue: (game: Game, eyebrow: String, isTransfer: Bool, onResume: () -> Void)? {
        didSet { refreshContinueBanner(); layoutContinueBanner() }
    }

    /// Show/update the top-left Continue pill, creating it on first need and hiding it when there's
    /// nothing to resume. Prefers a cross-device Continuity session over the local last-played game so
    /// "Continue from iPhone" wins when one is available. Re-added each time so it stays above the tiles.
    private func refreshContinueBanner() {
        let game: Game
        let eyebrow: String
        let isTransfer: Bool
        let action: () -> Void
        if let x = crossDeviceContinue {
            game = x.game
            eyebrow = x.eyebrow
            isTransfer = x.isTransfer
            action = x.onResume
        } else if let last = lastPlayedGame {
            game = last
            eyebrow = "CONTINUE"
            isTransfer = false
            action = { [weak self] in self?.onLaunch?(last) }
        } else {
            continueBannerVisible = false
            continueBanner?.isHidden = true
            return
        }
        let banner = continueBanner ?? {
            let b = ContinueBanner()
            b.onClick = { [weak self] in self?.continueAction?() }
            continueBanner = b
            return b
        }()
        continueGame = game
        continueEyebrow = eyebrow
        continueIsTransfer = isTransfer
        continueAction = action
        banner.uiScale = contentScale
        // Only a cross-device card (Continue/Transfer from another device) is dismissible; the local
        // last-played row isn't — there's nothing to hide, it just reflects your history.
        banner.onDismiss = (crossDeviceContinue != nil) ? { [weak self] in self?.onCrossDeviceDismiss?() } : nil
        banner.update(game: game, eyebrow: eyebrow, transfer: isTransfer)
        banner.isHidden = false
        addSubview(banner)   // keep it front-most (tiles are re-added on each filter pass)
        continueBannerVisible = true
    }
    private var continueGame: Game?   // the game the Continue row currently points at
    private var continueEyebrow = "CONTINUE"   // its eyebrow, kept so rescales redraw the right label
    private var continueIsTransfer = false     // whether the current row is an incoming transfer
    private var continueAction: (() -> Void)?  // what a click on the row does (launch, or cross-device resume)

    /// Set by the pull-up filter drawer (All Games / Hidden).
    func setScope(_ scope: Scope) {
        self.scope = scope
        applyFilter(resetSelection: true)
    }

    /// Recompute the cached metadata rows when the selected game changes.
    private func refreshDetail() {
        guard let game = selectedGame else {
            detailGroups = []; detailGameID = nil; detailRA = .hidden; return
        }
        if game.id == detailGameID { return }
        detailGameID = game.id
        detailGroups = GameDetails.groups(for: game)
        fetchAchievements(for: game)
    }

    /// Fetch RetroAchievements progress for a game (async); redraw when it lands, if still selected.
    private func fetchAchievements(for game: Game) {
        guard game.system == .gba || game.system == .ps1 else { detailRA = .hidden; return }
        guard RACredentials.isConfigured else { detailRA = .notConfigured; return }
        detailRA = .loading
        let id = game.id
        Task { @MainActor [weak self] in
            let result = await RetroAchievements.fetch(forROMAt: game.romURL, system: game.system)
            guard let self, self.detailGameID == id else { return }
            switch result {
            case .ok(let progress): self.detailRA = .loaded(progress)
            case .notFound: self.detailRA = .notFound
            case .failed: self.detailRA = .failed
            }
            self.needsDisplay = true
        }
    }

    /// Re-fetch achievements for the current selection (e.g. after the user signs in to RA).
    func refreshAchievements() {
        if let game = selectedGame { fetchAchievements(for: game) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// Rebuild the footer action bar — one Liquid-Glass capsule of icon actions (enabled state
    /// depends on a game existing).
    private func rebuildPrompts() {
        actionBar?.removeFromSuperview()
        let hasGame = !games.isEmpty
        let items: [GlassBar.Item] = [
            .init(symbol: "play.fill", tooltip: "Play Cartridge", enabled: hasGame,
                  onClick: { [weak self] in if let g = self?.selectedGame { self?.onLaunch?(g) } }),
            .init(symbol: "magnifyingglass", tooltip: "Search", enabled: hasGame,
                  onClick: { [weak self] in self?.toggleSearch() }),
            // Add ROMs sits dead-centre — the shelf's primary "grow your library" action.
            // (Removing a game lives ONLY on the per-cartridge right-click menu and the Delete key,
            // deliberately not here, so it's never a stray click away.)
            .init(symbol: "plus", tooltip: "Add ROMs",
                  onClick: { [weak self] in self?.onAddROMs?() }),
            // Background sound is otherwise only in Settings and in-game — surface it on the shelf too.
            .init(symbol: "cloud", tooltip: "Background Sound",
                  onClick: { [weak self] in self?.toggleAmbiencePanel() }),
            .init(symbol: "slider.horizontal.3", tooltip: "Settings",
                  onClick: { [weak self] in self?.onConfigure?() }),
        ]
        let bar = GlassBar(items: items)
        addSubview(bar)
        actionBar = bar
        layoutPrompts()
    }

    /// Hang the shared background-sound picker off the footer bar (same panel as the in-game toolbar).
    /// Transient like a popover, with a global monitor so a click in another app closes it too.
    private func toggleAmbiencePanel() {
        if let p = ambiencePopover, p.isShown { p.performClose(nil); return }
        guard let anchor = actionBar else { return }

        let panel = AmbiencePanelView { _ in }   // the footer icon is a fixed cloud, nothing to re-sync
        let vc = NSViewController()
        vc.view = panel
        vc.preferredContentSize = panel.frame.size

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.delegate = self
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)   // above the footer bar
        ambiencePopover = pop
        panel.beginControllerFocus()

        ambienceMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak pop] _ in
            pop?.performClose(nil)
        }
    }

    func updateCover(for gameID: UUID, image: NSImage) {
        tiles.first { $0.game.id == gameID }?.setCover(image)
    }

    // MARK: - Selection & input

    private func tileClicked(_ game: Game) {
        // Clicking only selects — launching is via the Play button / Return.
        if let idx = games.firstIndex(where: { $0.id == game.id }) { select(idx) }
        window?.makeFirstResponder(self)
    }

    private func select(_ index: Int) {
        guard !games.isEmpty else { return }
        // Any selection (click, arrow key, or drag release) ends the scrub. A plain click fires the
        // tile's `.began` but never `.ended`, so without this `scrubbing` would stay stuck true and
        // silently disable the mouse-moved self-heal.
        scrubbing = false
        let wrapped = ((index % games.count) + games.count) % games.count   // loop at the ends
        // Even when the selection doesn't change (e.g. clicking the already-centered cart, or a
        // scrub that snaps back to the same game), still settle: a scrub may have left tiles at
        // their live focus scale, and without this they'd stay stuck oversized until hovered.
        guard wrapped != selected else { settleTiles(); return }
        // Shortest circular direction of the move (+1 = to a later game, −1 = earlier), so the
        // detail glides in from the same side the new cartridge arrives from.
        let n = games.count
        var delta = wrapped - selected
        if delta > n / 2 { delta -= n } else if delta < -n / 2 { delta += n }
        detailDir = delta >= 0 ? 1 : -1

        // Freeze the outgoing game's info so it can slide/fade out while the new one slides in.
        if let g = selectedGame {
            detailOutgoing = DetailSnapshot(game: g, groups: detailGroups, ra: detailRA)
        }
        selected = wrapped
        refreshDetail()
        settleTiles()
        // Morph the detail panel in step with the cartridge settle: 0 → 1 over the same beat.
        detailXfade.jump(to: 0)
        detailXfade.animate(to: 1, duration: Motion.base)
        needsDisplay = true
    }

    /// Drag the carousel left/right to scrub between games. The cartridges track the finger 1:1 (with
    /// the centered one growing as it reaches the middle); on release we project where a flick's
    /// momentum would coast to (iOS-style) and snap to the nearest game with a springy settle.
    private func handleCarouselDrag(_ phase: CartridgeTileView.DragPhase, _ dx: CGFloat) {
        switch phase {
        case .began:
            scrubbing = true
            dragOffsetX = 0
            lastDragX = 0; lastDragT = CACurrentMediaTime(); dragVelocity = 0
        case .changed:
            let now = CACurrentMediaTime()
            let dt = now - lastDragT
            if dt > 0.001 { dragVelocity = (dx - lastDragX) / CGFloat(dt) }
            lastDragX = dx; lastDragT = now
            dragOffsetX = dx
            layoutTilesDrag()
        case .ended:
            scrubbing = false
            let step = tileSide + tileGap
            let projected = dx + Motion.project(dragVelocity)         // where momentum coasts to
            let maxSteps = tiles.count > 1 ? min(4, tiles.count - 1) : 0
            // Bias the step count so a deliberate drag past ~35% of a cart advances (not the full 50%
            // a plain round needs) — small swipes feel like they "take" instead of springing back.
            let raw = -projected / step
            let biased = raw + (raw > 0 ? 0.15 : raw < 0 ? -0.15 : 0)
            let steps = max(-maxSteps, min(maxSteps, Int(biased.rounded())))
            dragOffsetX = 0
            settleVelocityX = dragVelocity                // continue the flick's momentum into the spring
            if steps != 0 { select(selected + steps) }   // select springs the settle
            else { settleTiles() }                        // snap back to center
            settleVelocityX = 0                           // consumed by the synchronous settle above
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌘F opens (or closes) the search grid.
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "f" {
            toggleSearch(); return
        }
        switch event.keyCode {
        case 123: moveSelection(by: -1)                // ←
        case 124: moveSelection(by: 1)                 // →
        case 36, 76: launchSelected()                  // Return / Enter
        case 51, 117: removeSelected()                 // Delete / Fwd-delete
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Search grid

    private var searchOverlay: SearchGridView?

    /// Show the search grid over the shelf, or dismiss it if it's already up (the ⌘F / footer toggle).
    func toggleSearch() {
        if searchOverlay != nil { closeSearch() } else { openSearch() }
    }

    private func openSearch() {
        guard searchOverlay == nil, !allGames.isEmpty else { return }
        let overlay = SearchGridView(games: allGames)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.onLaunch = { [weak self] game in self?.onLaunch?(game) }
        overlay.onClose = { [weak self] in self?.closeSearch() }
        addSubview(overlay, positioned: .above, relativeTo: nil)   // above the tiles + banner
        // Hide the shelf entirely behind the overlay: the selected carousel tile sets a high
        // layer.zPosition (which composites *over* the overlay), and the side tiles' tracking areas
        // still fire under the pointer (lighting them up as dim ghosts). Hiding them stops both.
        setShelfContentHidden(true)
        searchOverlay = overlay
        overlay.focusSearch()
    }

    private func closeSearch() {
        searchOverlay?.removeFromSuperview()
        searchOverlay = nil
        setShelfContentHidden(false)
        window?.makeFirstResponder(self)
    }

    /// Hide (or restore) everything the shelf draws — the cartridge tiles, the Continue pill, the
    /// footer bar, the filter drawer, and the custom-drawn detail panel — so the search overlay sits
    /// over a clean black canvas with nothing bleeding through from behind.
    private func setShelfContentHidden(_ hidden: Bool) {
        tiles.forEach { $0.isHidden = hidden }
        continueBanner?.isHidden = hidden || !continueBannerVisible
        actionBar?.isHidden = hidden
        filterDrawer.isHidden = hidden
        needsDisplay = true   // drawDetail() bails out while the overlay is up
    }

    // MARK: - Controller / keyboard navigation
    //
    // Shared entry points for the carousel, so the keyboard (`keyDown`) and a connected controller
    // (`MenuControllerInput`) drive the exact same navigation.

    /// Move the carousel selection by `delta` cartridges (wraps at the ends). No-op when empty.
    func moveSelection(by delta: Int) { select(selected + delta) }

    /// Launch the centered cartridge (Return / controller A). No-op when the library is empty.
    func launchSelected() { if let g = selectedGame { onLaunch?(g) } }

    /// Remove the centered cartridge from the library (Delete). No-op when the library is empty.
    func removeSelected() { if let g = selectedGame { onRemove?(g) } }

    // MARK: - Layout

    override func layout() {
        super.layout()
        if !dropOverlay.isHidden { dropOverlay.frame = bounds }   // track window resizes mid-drag
        // Frozen mid-dissolve so a stray layout pass can't reset the tiles' opacity and un-fade them.
        guard !launchDissolving else { return }
        layoutTiles(animated: false)
        layoutPrompts()
        layoutContinueBanner()
        needsDisplay = true   // the detail panel's Y tracks the window height (see carouselTop)
    }

    /// Pin the Continue pill to the top-left, aligned with the content left margin.
    private func layoutContinueBanner() {
        guard let banner = continueBanner, continueBannerVisible else { return }
        // Re-scale with the window (contentScale tracks size), recomputing the row's fonts/width.
        if banner.uiScale != contentScale, let game = continueGame {
            banner.uiScale = contentScale
            banner.update(game: game, eyebrow: continueEyebrow, transfer: continueIsTransfer)
        }
        // Shift left by the row's own leading inset so the cover lines up with the content margin
        // (the big title below starts at labelX).
        banner.frame = CGRect(x: labelX - banner.leadingInset, y: continueBannerTop,
                              width: banner.measuredWidth, height: continueBannerH)
    }

    /// Center the selected tile (coverflow-style): it sits in the middle, the next cart fans out to
    /// the right and the previous one exits to the left, symmetrically. Wrapping tiles snap
    /// (teleport off-screen) rather than sliding across the whole width.
    private func layoutTiles(animated: Bool) {
        let frameH = tileSide + sc(DS.Space.sm + 24)   // square + label room
        let step = tileSide + tileGap
        let anchorX = (bounds.width - tileSide) / 2   // selected cart centered; neighbors flank it
        let n = max(tiles.count, 1)
        func place() {
            for (i, t) in tiles.enumerated() {
                t.setSelected(i == selected, animated: animated)
                // Shortest circular distance from the selected index → position on either side.
                var offset = ((i - selected) % n + n) % n
                if offset > n / 2 { offset -= n }
                let x = anchorX + CGFloat(offset) * step + dragOffsetX
                let target = CGRect(x: x, y: carouselTop, width: tileSide, height: frameH)
                let wraps = abs(x - t.frame.origin.x) > step * CGFloat(max(1, n / 2))
                if animated && !wraps { t.animator().frame = target } else { t.frame = target }
            }
        }
        if animated { Motion.animateViews(Motion.base) { _ in place() } } else { place() }
    }

    /// Live drag update — moves tiles with the finger and scales each by how near the center it is
    /// (cover-flow focus follows the drag), with implicit animations off so it tracks the cursor
    /// exactly. Blur is left cleared for the whole drag, so this stays cheap and smooth per frame.
    private func layoutTilesDrag() {
        let frameH = tileSide + sc(DS.Space.sm + 24)
        let step = tileSide + tileGap
        let anchorX = (bounds.width - tileSide) / 2
        let n = max(tiles.count, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, t) in tiles.enumerated() {
            var offset = ((i - selected) % n + n) % n
            if offset > n / 2 { offset -= n }
            let shift = CGFloat(offset) * step + dragOffsetX   // distance of this tile from center
            t.frame = CGRect(x: anchorX + shift, y: carouselTop, width: tileSide, height: frameH)
            t.setFocus(1 - min(1, abs(shift) / step))          // 1 at center → 0 a step away
        }
        CATransaction.commit()
    }

    /// Spring-settle the carousel to the current selection. Both the horizontal translation and each
    /// tile's scale/dim ride a single Core Animation spring (render-server driven, so it holds a smooth
    /// cadence and interrupts cleanly under rapid input) with a snappy response and a touch of
    /// overshoot. Tiles that wrap around the ends teleport rather than sliding the full width.
    private func settleTiles() {
        let frameH = tileSide + sc(DS.Space.sm + 24)
        let step = tileSide + tileGap
        let anchorX = (bounds.width - tileSide) / 2
        let n = max(tiles.count, 1)
        let velocity = settleVelocityX                     // flick momentum, handed off once
        for (i, t) in tiles.enumerated() {
            t.setSelected(i == selected, animated: true)   // springs scale + fade, matched response
            var offset = ((i - selected) % n + n) % n
            if offset > n / 2 { offset -= n }
            let x = anchorX + CGFloat(offset) * step
            let target = CGRect(x: x, y: carouselTop, width: tileSide, height: frameH)
            let wraps = abs(x - t.frame.origin.x) > step * CGFloat(max(1, n / 2))
            if wraps { t.frame = target } else { t.springFrame(to: target, velocity: velocity) }
        }
    }

    /// Center the footer action bar (the glass capsule) in the bottom bar, with the filter drawer
    /// tucked just above it.
    private func layoutPrompts() {
        guard let bar = actionBar else { return }
        let w = bar.measuredWidth, h = bar.measuredHeight
        let barY = bounds.height - bottomBarH / 2 - h / 2 - footerBottomInset
        bar.frame = CGRect(x: (bounds.width - w) / 2, y: barY, width: w, height: h)
        bar.needsLayout = true

        let dw = filterDrawer.preferredWidth, dh = filterDrawer.preferredHeight
        filterDrawer.frame = CGRect(x: (bounds.width - dw) / 2, y: barY - 4 - dh, width: dw, height: dh)
        filterDrawer.needsDisplay = true
    }

    // Reveal the drawer handle only when the pointer is over (or just above) the glass bar — a snug
    // region around the bar/handle, not the whole bottom band.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let bandTracking { removeTrackingArea(bandTracking) }
        let barW = actionBar?.measuredWidth ?? 220
        let barH: CGFloat = 48
        let barY = bounds.height - bottomBarH / 2 - barH / 2 - footerBottomInset
        let handleZone: CGFloat = 36          // just enough room above the bar for the reveal handle
        let regionW = max(barW, filterDrawer.preferredWidth) + 24
        let top = barY - handleZone
        let rect = CGRect(x: (bounds.width - regionW) / 2, y: top,
                          width: regionW, height: (barY + barH) - top)
        let t = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(t); bandTracking = t

        // A mouse-moved area over the carousel band so a tile left at a stale scale (an interrupted
        // scrub) self-heals on the next pointer move — the same resync a hover does, but without
        // needing the pointer to land exactly on the tile.
        if let carouselTracking { removeTrackingArea(carouselTracking) }
        let carousel = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, top))
        let ct = NSTrackingArea(rect: carousel, options: [.mouseMoved, .activeInKeyWindow], owner: self)
        addTrackingArea(ct); carouselTracking = ct
    }

    override func mouseEntered(with event: NSEvent) { filterDrawer.setBarHovered(true) }
    override func mouseExited(with event: NSEvent) { filterDrawer.setBarHovered(false) }

    override func mouseMoved(with event: NSEvent) {
        guard !scrubbing, !launchDissolving else { return }
        for (i, t) in tiles.enumerated() { t.reassertResting(selected: i == selected) }
    }

    // MARK: - Draw (chrome + detail)

    override func draw(_ dirtyRect: NSRect) {
        DS.Color.background.setFill()
        dirtyRect.fill()
        guard searchOverlay == nil else { return }   // the search overlay owns the screen
        drawDetail()
    }

    private func drawDetail() {
        guard let game = selectedGame else {
            let msg: String
            switch scope {
            case .hidden: msg = "No hidden games"
            default: msg = "Drop a ROM to begin"
            }
            let empty = DS.Text.plain(msg, size: scf(16), color: DS.Color.textSecondary)
            empty.draw(at: CGPoint(x: labelX, y: carouselTop + tileSide / 2))
            return
        }

        let p = detailXfade.value                       // 0 → 1 through the morph
        // Outgoing info dissolves + slides away in the scrub direction; incoming arrives from the
        // opposite side, both moving the same way as the cartridges for a unified morph.
        if let out = detailOutgoing, p < 1 {
            drawDetailPanel(game: out.game, groups: out.groups, ra: out.ra,
                            alpha: 1 - p, dx: -p * sc(detailSlideDistance) * detailDir)
        }
        drawDetailPanel(game: game, groups: detailGroups, ra: detailRA,
                        alpha: p, dx: (1 - p) * sc(detailSlideDistance) * detailDir)
    }

    /// Draw one game's info block (title + metadata + achievements) at a given opacity and horizontal
    /// offset — the unit the selection-change morph slides and dissolves.
    private func drawDetailPanel(game: Game, groups: [[(String, String?)]], ra: RAState,
                                 alpha: CGFloat, dx: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha * launchChromeAlpha)   // also dissolves with the launch cinematic
        ctx.translateBy(x: dx, y: 0)
        defer { ctx.restoreGState() }

        let titleY = carouselTop + tileSide + sc(40)
        DS.Text.title(game.displayTitle, size: scf(32)).draw(
            with: CGRect(x: labelX, y: titleY, width: bounds.width - labelX - sc(40), height: sc(44)),
            options: [.usesLineFragmentOrigin])

        // Metadata table: labels at labelX, values at contentX. "-" for what we don't know yet.
        var y = titleY + titleToContentGap
        let rowH = sc(20), groupGap = sc(14)
        for group in groups {
            for (label, value) in group {
                DS.Text.label(label, size: scf(13)).draw(at: CGPoint(x: labelX, y: y))
                DS.Text.value(value, size: scf(13)).draw(at: CGPoint(x: contentX, y: y))
                y += rowH
            }
            y += groupGap
        }

        drawAchievements(titleY: titleY, ra: ra)
    }

    /// Story progress bar + trophies summary (RetroAchievements), in the right column of the detail.
    private func drawAchievements(titleY: CGFloat, ra state: RAState) {
        let x = contentX + sc(320), w = sc(220)
        var y = titleY + titleToContentGap

        // A short status line for every non-loaded case, so the column is never a blank mystery.
        func status(_ text: String) {
            DS.Text.label(text, size: scf(12), color: DS.Color.textTertiary).draw(at: CGPoint(x: x, y: y))
        }

        let ra: RAGameProgress
        switch state {
        case .hidden: return
        case .notConfigured: status("Sign in to RetroAchievements for trophies"); return
        case .loading: status("Loading achievements…"); return
        case .notFound: status("No RetroAchievements set for this game"); return
        case .failed: status("Couldn't reach RetroAchievements"); return
        case .loaded(let progress): ra = progress
        }

        // STORY progress bar.
        DS.Text.label("Story Progress", size: scf(13)).draw(at: CGPoint(x: x, y: y))
        y += sc(22)
        let barH = sc(8), radius = sc(4)
        let track = CGRect(x: x, y: y, width: w, height: barH)
        DS.Color.surfaceRaised.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let pct = max(0, min(1, ra.storyPercent))
        if pct > 0 {
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: y, width: max(barH, w * pct), height: barH),
                         xRadius: radius, yRadius: radius).fill()
        }
        DS.Text.value("\(Int((pct * 100).rounded()))%", size: scf(13))
            .draw(at: CGPoint(x: x + w + sc(10), y: y - sc(4)))

        // TROPHIES summary.
        y += sc(30)
        DS.Text.label("Trophies", size: scf(13)).draw(at: CGPoint(x: x, y: y))
        y += sc(22)
        DS.Text.value("\(ra.earned) / \(ra.total)", size: scf(15)).draw(at: CGPoint(x: x, y: y))
        DS.Text.label("\(ra.earnedPoints) / \(ra.points) pts", size: scf(12), color: DS.Color.textSecondary)
            .draw(at: CGPoint(x: x + sc(90), y: y + sc(1)))
    }

    // MARK: - Drag & drop

    /// True when the drag carries at least one supported ROM file — the only thing worth accepting, and
    /// what gates both the drop-target highlight and the actual drop.
    private func containsSupportedROM(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL] else { return false }
        return urls.contains { ROMImporter.isSupported($0) }
    }

    /// Reveal (or hide) the full-shelf drop-target overlay, keeping it frontmost while shown.
    private func showDropTarget(_ show: Bool) {
        if show {
            dropOverlay.frame = bounds
            addSubview(dropOverlay, positioned: .above, relativeTo: nil)   // above the tiles + banner
        }
        dropOverlay.isHidden = !show
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard containsSupportedROM(sender) else { return [] }
        showDropTarget(true)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        containsSupportedROM(sender) ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { showDropTarget(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { showDropTarget(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropTarget(false)
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else { return false }
        onDropURLs?(urls)
        return true
    }
}

// MARK: - Drop-target overlay

/// A full-bleed prompt shown over the shelf while a valid ROM drag hovers: a dimming scrim, a dashed
/// rounded frame, and a centered "＋ Drop ROMs to add" caption — so a drop reads as an intentional,
/// invited action rather than a blind guess.
private final class DropTargetOverlay: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // Purely decorative — never intercept the drag (the dashboard is the drop destination).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        bounds.fill()

        let inset: CGFloat = 28
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                 xRadius: DS.Radius.tile, yRadius: DS.Radius.tile)
        frame.lineWidth = 2
        frame.setLineDash([9, 7], count: 2, phase: 0)
        DS.Color.hairlineStrong.setStroke()
        frame.stroke()

        // Centered plus glyph above the caption.
        let plus = DS.Text.plain("+", size: 46, color: DS.Color.textPrimary)
        let caption = DS.Text.label("Drop ROMs to add", size: 16, color: DS.Color.textPrimary)
        let ps = plus.size(), cs = caption.size()
        let gap: CGFloat = 8
        let blockH = ps.height + gap + cs.height
        let top = bounds.midY + blockH / 2
        plus.draw(at: CGPoint(x: bounds.midX - ps.width / 2, y: top - ps.height))
        caption.draw(at: CGPoint(x: bounds.midX - cs.width / 2, y: top - ps.height - gap - cs.height))
    }
}

extension LibraryDashboardView: NSPopoverDelegate {
    /// Drop the outside-click monitor whenever the background-sound picker closes (however it closed).
    func popoverDidClose(_ notification: Notification) {
        if let m = ambienceMonitor { NSEvent.removeMonitor(m); ambienceMonitor = nil }
        ambiencePopover = nil
    }
}
