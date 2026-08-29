import SwiftUI
import UIKit
import UniformTypeIdentifiers
import LibraryKit
import ContinuityKit

/// The library, "Analogue OS" style: games as hero **cartridges** on a horizontal carousel, a
/// Continue banner on top when there's a resumable session, and `＋` to import a `.gba` from Files.
struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ContinuityService.self) private var continuity
    @Environment(LaunchCoordinator.self) private var launcher
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var importError: String?
    /// Index of the centered cart in the coverflow — the single source of truth for which cart is
    /// focused (its title shows, it's the one that launches). The carousel keeps this in sync so the
    /// visual centre and the "focused" cart can never drift apart.
    @State private var selected = 0
    @State private var settingsGame: Game?
    @State private var detailsGame: Game?
    /// Set when a Continue capsule (or its long-press menu of recent sessions) is chosen — pushes the
    /// game with `resume: true`. Item-based so a menu Button can navigate (a NavigationLink can't live
    /// in a `.contextMenu`); keyed on `Game`, distinct from the `PlayRequest` destination above.
    @State private var resumeGame: Game?
    /// True while the Continue "folder" is fanned open — a long-press spreads the recent sessions as
    /// their own capsules over the shelf, dimmed behind a tap-away scrim.
    @State private var continueFanOpen = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var arrival: ArrivalInfo?
    /// The in-flight send animation: the (up to three) cartridges streaking toward iCloud, the
    /// destination label, and the live upload result — nil while uploading, then success/failure — so
    /// the flourish resolves into a real "Sent ✓ / couldn't reach iCloud" beat instead of firing and
    /// forgetting. Nil when idle.
    struct SendFlight {
        let games: [Game]
        let dest: String
        var result: Bool?
    }
    @State private var sendFlight: SendFlight?
    /// A game currently dropping away in the delete flourish; nil when idle.
    @State private var deleteFlourish: Game?
    @State private var focusedCartFrame: CGRect?
    /// Set when the user taps "Send to My Devices" while game transfer is still off — drives the
    /// one-time consent alert before the first send. `target` is the chosen device (nil = broadcast).
    @State private var sendConsent: (game: Game, target: String?)?
    /// Non-nil drives the multi-select send sheet, pre-selecting this cartridge.
    @State private var sendPickerPreselect: Game?
    /// Set when confirming a multi-select send while game transfer is still off — the one-time consent
    /// alert before the batch is offered.
    @State private var sendMultipleConsent: (games: [Game], target: String?)?
    /// The user's other devices, so the context menu can offer "Send to → [device]". Empty → a plain
    /// broadcast "Send to My Devices".
    @State private var sendTargets: [String] = []
    /// Ambience quick-access from the shelf's top-left toolbar button — the same background soundscape
    /// the in-game audio popover controls, so it can be set (or muted) right from the library.
    @State private var ambiencePopover = false
    @AppStorage(SettingsKey.ambientScene) private var ambientSceneRaw = SettingsDefault.ambientScene
    @AppStorage(SettingsKey.ambientVolume) private var ambientVolume = SettingsDefault.ambientVolume

    /// A just-received transfer, driving the NameDrop-style arrival animation. Built from the *offer*
    /// (before the ROM downloads/imports) so the animation can start the instant the card is tapped;
    /// `cover` is filled in as the art downloads.
    struct ArrivalInfo: Identifiable {
        let id = UUID()
        let system: GameSystem
        let title: String
        let deviceName: String
        var cover: UIImage?
    }
    /// Flips true once the background download/import finishes and the new cart is focused — the arrival
    /// overlay then morphs into its real shelf slot (until then it holds, radar-waving).
    @State private var arrivalReady = false

    // Every ROM extension iOS can actually *play* (GBA + Game Boy / Color), as UTTypes for the Files
    // picker. PS1 disc extensions are deliberately excluded — the shared enum carries `.ps1`, but this
    // build has no PlayStation core, so offering to import one would only produce an unplayable game.
    private static let romTypes: [UTType] =
        GameSystem.iosPlayableExtensions.compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()
            if library.games.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .onPreferenceChange(FocusedCartFrameKey.self) { focusedCartFrame = $0 }
        .overlay {
            if let arrival {
                TransferArrivalOverlay(system: arrival.system, title: arrival.title,
                                       deviceName: arrival.deviceName, cover: arrival.cover,
                                       ready: arrivalReady, targetFrame: focusedCartFrame) {
                    self.arrival = nil          // cart has morphed into its shelf slot; remove the overlay
                    self.arrivalReady = false
                }
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .overlay {
            if let flight = sendFlight {
                SendFlourishView(games: flight.games, covers: library.covers,
                                 dest: flight.dest, result: flight.result) { sendFlight = nil }
                    .allowsHitTesting(false)
                    .zIndex(25)
            }
        }
        .overlay {
            if let game = deleteFlourish {
                DeleteFlourishView(game: game, covers: library.covers) { deleteFlourish = nil }
                    .allowsHitTesting(false)
                    .zIndex(26)
            }
        }
        .overlay {
            if continueFanOpen {
                ContinueFolder(items: recentResolved,
                               cover: { library.covers[$0] },
                               source: { continuity.sourceLabel(for: $0) },
                               onResume: { continueFanOpen = false; resumeGame = $0 },
                               onClose: { withAnimation(.easeOut(duration: 0.22)) { continueFanOpen = false } })
                    .transition(.opacity)
                    .zIndex(30)
            }
        }
        .navigationDestination(for: PlayRequest.self) { GameView(game: $0.game, resume: $0.resume) }
        .navigationDestination(item: $resumeGame) { GameView(game: $0, resume: true) }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { ambiencePopover = true } label: {
                    Image(systemName: ambientSceneRaw == AmbientScene.off.rawValue
                          ? "speaker.wave.2" : "speaker.wave.2.fill")
                }
                .accessibilityLabel("Ambience")
                .foregroundStyle(ambientSceneRaw == AmbientScene.off.rawValue ? DS.textSecondary : DS.accent)
                .popover(isPresented: $ambiencePopover) { ambiencePopoverContent }
            }
            if !library.games.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search")
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            GameSearchView(games: library.games, covers: library.covers) { game in
                showSearch = false
                if let idx = library.games.firstIndex(where: { $0.id == game.id }) {
                    withAnimation(.snappy) { selected = idx }
                }
            }
        }
        // Incoming shared ROM: its own always-visible banner at the top, so it isn't hidden by a
        // Continue session competing for the bottom bar's single slot. Springs in when it appears.
        .safeAreaInset(edge: .top) {
            incomingTransferBanner
                .animation(.spring(response: 0.5, dampingFraction: 0.62),
                           value: continuity.pendingTransfers.count)
        }
        // Apple-Music-style floating bottom bar: Settings · now-playing capsule · Import.
        .safeAreaInset(edge: .bottom) { bottomBar }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: Self.romTypes + [.data],
            allowsMultipleSelection: true
        ) { handleImport($0) }
        .alert("Import failed", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
        .alert("Send to your devices?", isPresented: .constant(sendConsent != nil), presenting: sendConsent) { pending in
            Button("Send") {
                AppSettings.setTransferEnabled(true)   // remember the choice, like the Settings toggle
                sendConsent = nil
                Task { await sendToDevices(pending.game, target: pending.target) }
            }
            Button("Cancel", role: .cancel) { sendConsent = nil }
        } message: { _ in
            Text("This copies the game to your other devices through your own private iCloud — never our "
                + "servers — so you can pick it up there. Only send games you legally own.")
        }
        .alert("Send to your devices?", isPresented: .constant(sendMultipleConsent != nil), presenting: sendMultipleConsent) { pending in
            Button("Send") {
                AppSettings.setTransferEnabled(true)   // remember the choice, like the Settings toggle
                sendMultipleConsent = nil
                Task { await sendMultiple(pending.games, target: pending.target) }
            }
            Button("Cancel", role: .cancel) { sendMultipleConsent = nil }
        } message: { pending in
            Text("This copies \(pending.games.count) game\(pending.games.count == 1 ? "" : "s") to your other "
                + "devices through your own private iCloud — never our servers — so you can pick them up there. "
                + "Only send games you legally own.")
        }
        .sheet(item: $settingsGame) { GameSettingsView(game: $0) }
        .sheet(item: $detailsGame) { GameDetailsSheet(game: $0) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $sendPickerPreselect) { game in
            SendMultipleSheet(games: library.games, covers: library.covers,
                              preselect: game.id, sendTargets: sendTargets) { chosen, target in
                handleSendMultiple(chosen, target: target)
            }
        }
        .task(id: library.games.count) {
            await continuity.refreshBanner(for: library.games)
            await continuity.refreshTransferOffer(for: library.games)
            sendTargets = await continuity.sendTargets()
        }
        .onAppear {
            Task {
                await continuity.refreshBanner(for: library.games)
                await continuity.refreshTransferOffer(for: library.games)
            }
            if ProcessInfo.processInfo.environment["EMU_OPEN_SETTINGS"] != nil { showSettings = true }
        }
        // Live refresh: re-check iCloud for incoming shares while the library is on screen, so a game
        // sent from another device appears without reopening the app (we have no push channel).
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                await continuity.refreshTransferOffer(for: library.games)
                await continuity.refreshBanner(for: library.games)
            }
        }
        // And immediately when the app returns to the foreground (e.g. you switch to the phone to grab
        // a game you just sent from the Mac).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await continuity.refreshTransferOffer(for: library.games)
                await continuity.refreshBanner(for: library.games)
            }
        }
    }

    static let cardAspect: CGFloat = 1.78
    static let maxCardHeight: CGFloat = 148   // portrait size; landscape shrinks to fit

    private var content: some View {
        GeometryReader { geo in
            // Landscape is vertically tight and its floating bars are shorter, so it reserves less
            // chrome (letting the coverflow fill more of the short row) and tightens the vertical
            // rhythm; portrait keeps its roomier spacing. Size the cart to the space actually
            // available (capped at the portrait size) so the title + handle always clear the bars.
            let landscape = geo.size.width > geo.size.height
            let cardH = min(Self.maxCardHeight, max(96, geo.size.height - (landscape ? 120 : 180)))
            let cardW = cardH * Self.cardAspect

            VStack(spacing: landscape ? 12 : 20) {
                Spacer(minLength: 0)

                // Coverflow shelf: the centered cart is always `selected` (its title shows below, and
                // it's the one that launches). Ports the macOS shelf's feel — 1:1 drag scrub, continuous
                // distance-scale/dim, momentum-projected spring settle — so centre and focus never drift.
                CartShelf(
                    games: library.games,
                    covers: library.covers,
                    cardW: cardW,
                    selected: $selected,
                    onLaunch: { game, frame in
                        launcher.begin(game, coverURL: library.covers[game.romHash], from: frame)
                    },
                    sendTargets: sendTargets,
                    onContextDetails: { detailsGame = $0 },
                    onContextSettings: { settingsGame = $0 },
                    onContextSend: { handleSend($0, target: $1) },
                    onContextSendMultiple: { sendPickerPreselect = $0 },
                    onContextDelete: { handleDelete($0) })
                    .frame(height: cardH + (landscape ? 50 : 56))   // room for taller GBC carts (cardH+48)

                VStack(spacing: landscape ? 4 : 8) {
                    focusedTitle
                    // Landscape is too short to stack the handle below the title without it colliding
                    // with the floating bottom bar — so drop the visible affordance there. Swipe-up on
                    // the shelf (the simultaneousGesture below) still opens details, as does the context
                    // menu, so nothing is lost but the redundant chevron.
                    if !landscape { detailsHandle }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())   // make the whole shelf area a swipe target, gaps included
            // Swipe up anywhere on the shelf to raise the focused cart's details — the tiny handle
            // below was a hard-to-hit target. Simultaneous (not high-priority) so the horizontal
            // carousel still scrolls; only a dominant *upward* drag opens details, so a sideways
            // flick to change carts never triggers it.
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        let up = value.translation.height < -40
                        let vertical = abs(value.translation.height) > abs(value.translation.width) * 1.3
                        if up, vertical, let game = focusedGame { detailsGame = game }
                    }
            )
        }
    }

    /// The currently centered cart (the coverflow keeps `selected` clamped to a valid index).
    private var focusedGame: Game? {
        library.games.indices.contains(selected) ? library.games[selected] : library.games.first
    }

    private var focusedTitle: some View {
        VStack(spacing: 4) {
            Text(focusedGame?.displayTitle ?? "")
                .font(DS.mono(16, .semibold)).foregroundStyle(DS.textPrimary)
                .lineLimit(1)
            Text(focusedGame?.system.displayName ?? "")
                .font(DS.mono(10)).foregroundStyle(DS.textTertiary)
        }
        .animation(.default, value: selected)
    }

    /// A tucked-away pull-up handle — the iOS echo of the Mac's hidden filter drawer. Faint by
    /// default; tap it (or swipe up on it) to raise the details drawer for the focused cart.
    private var detailsHandle: some View {
        Button {
            detailsGame = focusedGame
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                Text("DETAILS")
                    .font(DS.mono(8, .semibold)).kerning(1.5)
            }
            .foregroundStyle(DS.textTertiary)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(focusedGame == nil)
        .highPriorityGesture(
            DragGesture(minimumDistance: 8).onEnded { value in
                if value.translation.height < -20 { detailsGame = focusedGame }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller").font(.system(size: 40)).foregroundStyle(DS.textTertiary)
            Text("NO GAMES").font(DS.mono(15, .semibold)).foregroundStyle(DS.textSecondary)
            Text("Tap ＋ to import a .gba, .gbc or .gb ROM from Files")
                .font(DS.mono(12)).foregroundStyle(DS.textTertiary).multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Floating bottom bar (Apple Music-style)

    /// A shared game waiting to be received — shown as its own banner just under the title so it's
    /// always visible, independent of the Continue strip. Tapping downloads + imports it.
    @ViewBuilder private var incomingTransferBanner: some View {
        let items = continuity.pendingTransfers
        if let first = items.first {
            TransferCapsule(card: first.card, count: items.count) { await handleReceiveAll(items) }
                .contextMenu(menuItems: {
                    Button(role: .destructive) { continuity.dismissPendingTransfers() } label: {
                        Label(items.count > 1 ? "Dismiss All" : "Dismiss", systemImage: "xmark.circle")
                    }
                }, preview: {
                    PressMenuBox {
                        TransferCapsule(card: first.card, count: items.count) { }
                            .frame(width: 300)
                    }
                })
                .padding(.horizontal, 16)
                .padding(.top, 6)
                // Swoop down from the top edge with a springy scale as it arrives.
                .transition(.move(edge: .top).combined(with: .opacity)
                    .combined(with: .scale(scale: 0.9, anchor: .top)))
                .id(first.card.metadata.romHash)   // re-trigger the entrance when the lead game changes
        }
    }

    /// The three most-recent resumable sessions (newest first), resolved to their games — the contents
    /// of the Continue "folder".
    private var recentResolved: [(card: ContinuityCard, game: Game)] {
        Array(continuity.recentSessions
            .compactMap { c in game(forHash: c.metadata.romHash).map { (card: c, game: $0) } }
            .prefix(3))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            circleButton("gearshape") { showSettings = true }
                .accessibilityLabel("Settings")

            if !continuity.recentSessions.isEmpty {
                ContinueStrip(
                    sessions: continuity.recentSessions,
                    game: { game(forHash: $0) },
                    covers: library.covers,
                    source: { continuity.sourceLabel(for: $0) },
                    onResume: { resumeGame = $0 },
                    onLongPress: { withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { continueFanOpen = true } })
            } else {
                Spacer(minLength: 0)
            }

            circleButton("plus") { importing = true }
                .accessibilityLabel("Import ROM")
        }
        // Standard 16pt side margins; balanced vertical padding leaves breathing room above the home
        // indicator per HIG (rather than sitting flush against the bottom safe-area inset).
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The shelf's ambience popover: pick a background soundscape and set its volume. Mirrors the
    /// in-game audio popover's ambience section (same settings, same live `AmbientPlayer.apply()`),
    /// minus the per-game volume — there's no game playing on the shelf.
    private var ambiencePopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ambience").font(.headline)

            Picker("Soundscape", selection: ambientBinding) {
                ForEach(AmbientScene.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if ambientSceneRaw != AmbientScene.off.rawValue {
                HStack {
                    Image(systemName: "cloud.rain").foregroundStyle(.secondary).frame(width: 22)
                    Slider(value: ambientVolumeBinding, in: 0...1)
                }
            }
        }
        .padding()
        .frame(width: 320)
        .tint(DS.accent)
        .presentationCompactAdaptation(.popover)
    }

    private var ambientBinding: Binding<Int> {
        Binding(get: { ambientSceneRaw }, set: { ambientSceneRaw = $0; AmbientPlayer.shared.apply() })
    }
    private var ambientVolumeBinding: Binding<Double> {
        Binding(get: { ambientVolume }, set: { ambientVolume = $0; AmbientPlayer.shared.apply() })
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(DS.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func game(forHash hash: String) -> Game? {
        library.games.first { $0.romHash == hash }
    }

    /// "Send to My Devices": offer this game to the user's other devices through iCloud so it appears
    /// in their Continue strip. Gated by the same ownership consent as Settings ▸ Handoff — if that's
    /// off we ask once, then remember the choice.
    private func handleSend(_ game: Game, target: String?) {
        if AppSettings.transferEnabled {
            Task { await sendToDevices(game, target: target) }
        } else {
            sendConsent = (game, target)
        }
    }

    /// Kick off the send flourish — the first three sent cartridges streak up toward the iCloud chip,
    /// which then holds until the real upload resolves.
    private func playSendFlourish(_ games: [Game], dest: String) {
        sendFlight = SendFlight(games: Array(games.prefix(3)), dest: dest, result: nil)
    }

    /// Delete a game with a matching flourish: the cartridge drops away with a soft power-down cue, then
    /// it's removed from the library (the falling overlay covers the shelf re-laying behind it).
    private func handleDelete(_ game: Game) {
        SoundFX.shared.playRemoved()
        deleteFlourish = game
        library.delete(game)
    }

    private func sendToDevices(_ game: Game, target: String?) async {
        // Cross-device send travels through your private iCloud; without a provisioned container there's
        // nowhere for the game to go. Say that plainly instead of implying a network fault.
        guard ContinuityService.cloudKitUsable else {
            AppNotifier.shared.post(.info(
                "Sending needs iCloud — it isn’t set up on this build yet",
                symbol: "icloud.slash", caption: "Handoff"))
            return
        }
        let dest = target ?? "your devices"
        playSendFlourish([game], dest: dest)
        let ok = await continuity.offerROM(game: game, targetDevice: target)
        // The flourish's iCloud chip now carries the success confirmation; keep a banner only for the
        // failure case (it lingers longer / is announced), so the two signals don't double up.
        await MainActor.run { sendFlight?.result = ok }
        if !ok {
            AppNotifier.shared.post(
                .info("Couldn’t reach iCloud — try again", symbol: "icloud.slash", caption: "Handoff"))
        }
    }

    /// Batch "Send Multiple…": the same ownership consent as the single-game path (asked once, then
    /// remembered), then offer every chosen game. The consent alert is deferred so the picker sheet has
    /// finished dismissing before it presents.
    private func handleSendMultiple(_ games: [Game], target: String?) {
        guard !games.isEmpty else { return }
        if AppSettings.transferEnabled {
            Task { await sendMultiple(games, target: target) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sendMultipleConsent = (games, target) }
        }
    }

    private func sendMultiple(_ games: [Game], target: String?) async {
        guard ContinuityService.cloudKitUsable else {
            AppNotifier.shared.post(.info(
                "Sending needs iCloud — it isn’t set up on this build yet",
                symbol: "icloud.slash", caption: "Handoff"))
            return
        }
        let dest = target ?? "your devices"
        playSendFlourish(games, dest: dest)
        var sent = 0
        for game in games where await continuity.offerROM(game: game, targetDevice: target) { sent += 1 }
        let ok = sent == games.count
        // Resolve the flourish (delivered if anything got through); the banner carries the exact count.
        await MainActor.run { sendFlight?.result = sent > 0 }
        AppNotifier.shared.post(.info(
            ok ? "Sent \(sent) game\(sent == 1 ? "" : "s") to \(dest)"
               : sent == 0 ? "Couldn’t reach iCloud — try again"
                           : "Sent \(sent) of \(games.count) — some couldn’t reach iCloud",
            symbol: ok ? "checkmark.circle" : "icloud.slash", caption: "Handoff"))
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                // Defence-in-depth against the picker or a Continuity hand-off surfacing a disc image:
                // iOS can't run PS1, so skip anything that isn't a GBA / Game Boy ROM.
                guard GameSystem.isPlayableOnIOS(extension: url.pathExtension) else {
                    importError = "\(url.lastPathComponent) isn’t a Game Boy / GBA game — this app can’t play it."
                    continue
                }
                do { try library.importROM(from: url) }
                catch { importError = error.localizedDescription }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    /// Accept a transfer: download the offered ROM, import it, retire the cloud offer, then play the
    /// arrival animation. Once local, the game owns the accompanying session so the green resume capsule
    /// appears — a second tap continues where the other device left off.
    /// Receive one or many shared games in a single tap — imports each, retires each cloud offer, then
    /// plays one arrival animation for the last cart and refreshes. Downloads a "pack" at once instead
    /// of confirming one by one.
    private func handleReceiveAll(_ offers: [(card: ContinuityCard, fileName: String)]) async {
        guard let hero = offers.last else { return }   // the cart the animation lands on (last in the pack)
        // Start the arrival the instant the card is tapped — from the offer's own info, before anything
        // downloads. The overlay swoops the cart in and holds; the shelf is updated behind it, so when it
        // morphs into the slot you're already sitting on the new cart.
        let ext = (hero.fileName as NSString).pathExtension.lowercased()
        let system: GameSystem = (ext == "gba") ? .gba : .gbc
        let heroTitle = (hero.fileName as NSString).deletingPathExtension
        arrivalReady = false
        withAnimation(.easeOut(duration: 0.2)) {
            arrival = ArrivalInfo(system: system, title: heroTitle,
                                  deviceName: hero.card.metadata.deviceName, cover: nil)
        }
        // Pull the hero's cover in quickly so the flying cart shows real art (best-effort, non-blocking).
        Task {
            if let data = await continuity.downloadROMCover(romHash: hero.card.metadata.romHash),
               let img = UIImage(data: data) { arrival?.cover = img }
        }
        // Download + import the whole pack in the background while the animation plays.
        var received: [(game: Game, cover: UIImage?, deviceName: String)] = []
        for offer in offers {
            if let one = await receiveOne(offer) {
                received.append((one.game, one.cover, offer.card.metadata.deviceName))
            }
        }
        await continuity.refreshBanner(for: library.games)
        await continuity.refreshTransferOffer(for: library.games)
        sendTargets = await continuity.sendTargets()
        // Nothing imported (all fetches failed) → drop the overlay; the error is surfaced by receiveOne.
        guard let last = received.last, let idx = library.games.firstIndex(where: { $0.id == last.game.id }) else {
            withAnimation(.easeOut(duration: 0.2)) { arrival = nil }
            arrivalReady = false
            return
        }
        // Focus the newly-arrived cart so the overlay's morph target is its real shelf slot, then release
        // the morph — the overlay was holding until now. A batch also posts a "Received N games" summary.
        withAnimation(.snappy) { selected = idx }
        if let c = last.cover { arrival?.cover = c }
        arrivalReady = true
        if received.count > 1 {
            AppNotifier.shared.post(.info("Received \(received.count) games",
                                          symbol: "square.and.arrow.down", caption: "Handoff"))
        }
    }

    /// Download + import one shared game (no arrival / refresh — the caller batches those), returning the
    /// imported game and its cover. Nil if the fetch/import fails or the bytes don't match.
    private func receiveOne(_ offer: (card: ContinuityCard, fileName: String)) async -> (game: Game, cover: UIImage?)? {
        let romHash = offer.card.metadata.romHash
        guard let data = await continuity.downloadROM(romHash: romHash) else {
            importError = "Couldn’t fetch the game from your other device."
            return nil
        }
        // Name the imported file from the offer's title, keeping the sender's extension (it drives
        // GBA/GBC system detection).
        let ext = (offer.fileName as NSString).pathExtension
        let title = offer.card.metadata.romTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let importName = (title.isEmpty || ext.isEmpty) ? offer.fileName : "\(title).\(ext)"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(importName)
        do {
            try data.write(to: tmp)
            let game = try library.importROM(from: tmp)
            try? FileManager.default.removeItem(at: tmp)
            guard game.romHash == romHash else {
                importError = "That transfer didn’t match the game."
                return nil
            }
            // Apply the sender's box art (if any) before retiring the offer, so the cart shows the
            // exact same cover — a cleaned title often won't re-match the thumbnail repo here.
            var cover: UIImage?
            if let coverData = await continuity.downloadROMCover(romHash: romHash) {
                library.setCover(fromImageData: coverData, for: game)
                cover = UIImage(data: coverData)
            }
            // Land the sender's cartridge save so the game opens on their actual progress. This device
            // didn't own the game (offers for owned games are filtered out), so there's nothing to
            // overwrite. Fetch before clearing the offer — clearROM deletes the whole record.
            if let battery = await continuity.downloadROMBattery(romHash: romHash), !battery.isEmpty {
                let saveURL = SavePaths.directory(forHash: game.romHash).appendingPathComponent("battery.sav")
                try? battery.write(to: saveURL, options: .atomic)
            }
            await continuity.clearROM(romHash: romHash)   // ROM is local now — keep the cloud copy ephemeral
            return (game, cover)
        } catch {
            importError = error.localizedDescription
            return nil
        }
    }
}

/// A coverflow cartridge shelf — the iOS port of the macOS `LibraryDashboardView` carousel. The
/// `selected` cart sits dead-centre; neighbours fan out on both sides and *continuously* scale + dim
/// with their distance from centre, so the visual centre, the focused cart, and the title below are
/// always the same game. A 1:1 horizontal drag scrubs; on release the flick's momentum
/// (`predictedEndTranslation`) is projected to the nearest cart and the shelf springs to it — the same
/// feel as the Mac shelf, but without SwiftUI's `ScrollView`, whose `.scrollPosition` reported a
/// different cart than the one on screen (the centre/focus drift you filmed).
private struct CartShelf: View {
    let games: [Game]
    let covers: [String: URL]
    let cardW: CGFloat
    @Binding var selected: Int
    /// The centered cart was tapped — launch it, with its exact on-screen (global) frame so the
    /// cinematic lifts off from the shelf.
    var onLaunch: (Game, CGRect) -> Void
    var sendTargets: [String]
    var onContextDetails: (Game) -> Void
    var onContextSettings: (Game) -> Void
    /// (game, targetDevice) — targetDevice nil means broadcast to all the user's devices.
    var onContextSend: (Game, String?) -> Void
    /// Open the multi-select send picker, pre-selecting this cartridge.
    var onContextSendMultiple: (Game) -> Void
    var onContextDelete: (Game) -> Void

    private static let gap: CGFloat = 22
    /// Live 1:1 finger offset during a horizontal scrub (0 at rest).
    @State private var drag: CGFloat = 0
    /// Axis lock, decided on the first meaningful movement: a vertical drag is left to the shelf's
    /// swipe-up-for-details gesture, so scrubbing and details-swipe never fight.
    @State private var axis: Axis?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let step = cardW + Self.gap
            let center = w / 2
            let cardH = cardW / LibraryView.cardAspect
            let sel = min(max(0, selected), games.count - 1)

            ZStack {
                ForEach(visibleIndices(around: sel), id: \.self) { i in
                    let x = center + CGFloat(i - sel) * step + drag
                    let d = min(1, abs(x - center) / step)     // 0 at centre → 1 a full step away
                    CartCard(game: games[i], coverURL: covers[games[i].romHash],
                             width: cardW, isFocused: true)
                        .background {
                            // Report the centered cart's on-screen frame so a received transfer's
                            // arrival animation can morph the cart into this exact shelf slot.
                            if i == sel {
                                GeometryReader { g in
                                    Color.clear.preference(key: FocusedCartFrameKey.self,
                                                           value: g.frame(in: .global))
                                }
                            }
                        }
                        .scaleEffect(1 - d * 0.12)            // centre full size, neighbours recede
                        .opacity(1 - d * 0.45)                // …and dim with distance (depth)
                        .position(x: x, y: h / 2)
                        .zIndex(1 - d)                        // centre cart draws on top
                        .contextMenu(menuItems: {
                            Button { onContextDetails(games[i]) } label: {
                                Label("Details", systemImage: "info.circle")
                            }
                            Button { onContextSettings(games[i]) } label: {
                                Label("Settings", systemImage: "slider.horizontal.3")
                            }
                            if sendTargets.isEmpty {
                                Button { onContextSend(games[i], nil) } label: {
                                    Label("Send to My Devices", systemImage: "iphone.and.arrow.forward")
                                }
                            } else {
                                Menu {
                                    ForEach(sendTargets, id: \.self) { device in
                                        Button { onContextSend(games[i], device) } label: {
                                            Label(device, systemImage: "laptopcomputer.and.iphone")
                                        }
                                    }
                                    Divider()
                                    Button { onContextSend(games[i], nil) } label: {
                                        Label("All My Devices", systemImage: "square.stack.3d.up")
                                    }
                                } label: {
                                    Label("Send to…", systemImage: "iphone.and.arrow.forward")
                                }
                            }
                            Button { onContextSendMultiple(games[i]) } label: {
                                Label("Send Multiple…", systemImage: "square.on.square")
                            }
                            Button(role: .destructive) { onContextDelete(games[i]) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }, preview: {
                            // Long-press lifts a clean Apple TV-style card: the cover art with a gentle
                            // tilt gloss, the console name and title beneath.
                            GamePreviewCard(
                                system: games[i].system,
                                cover: CoverStore.image(at: covers[games[i].romHash]),
                                title: games[i].displayTitle,
                                systemTag: games[i].system.shortName,
                                crop: games[i].coverCrop)
                        })
                        .onTapGesture {
                            if i == sel {
                                let g = geo.frame(in: .global)
                                let frame = CGRect(x: g.minX + center - cardW / 2,
                                                   y: g.minY + h / 2 - cardH / 2,
                                                   width: cardW, height: cardH)
                                onLaunch(games[i], frame)
                            } else {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { selected = i }
                            }
                        }
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(scrub(step: step))
            .onChange(of: games.count) { _, count in
                if selected >= count { selected = max(0, count - 1) }
            }
        }
    }

    /// Render only the carts near the centre (±4) — the rest are off-screen either way.
    private func visibleIndices(around sel: Int) -> [Int] {
        let lo = max(0, sel - 4), hi = min(games.count - 1, sel + 4)
        return lo <= hi ? Array(lo...hi) : []
    }

    private func scrub(step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                if axis == nil {
                    axis = abs(v.translation.width) >= abs(v.translation.height) ? .horizontal : .vertical
                }
                if axis == .horizontal { drag = v.translation.width }
            }
            .onEnded { v in
                defer { axis = nil }
                guard axis == .horizontal else { return }
                // Project where the flick coasts to, snap to the nearest cart (cap the jump so a hard
                // fling stays controllable), then spring there while the finger offset unwinds to 0.
                let move = Int((-v.predictedEndTranslation.width / step).rounded())
                let target = min(max(0, selected + max(-4, min(4, move))), games.count - 1)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    selected = target
                    drag = 0
                }
            }
    }
}

/// A single hero cartridge: the GBA cart silhouette with the cover art in its label window —
/// the same treatment as the macOS shelf (see `GBACartridgeView`). Wide (1.78:1) like a real cart;
/// the game's title/system show in the carousel's focused label beneath, so the cart stays clean.
private struct CartCard: View {
    let game: Game
    let coverURL: URL?
    /// Cart width; height follows the fixed cartridge aspect. Driven by the library's available space.
    var width: CGFloat = LibraryView.maxCardHeight * LibraryView.cardAspect
    /// The centered cart renders at full glass; off-center carts recede to the Mac's side values.
    var isFocused: Bool = true

    var body: some View {
        // Every cell keeps the same landscape *width* (so the coverflow's scroll math stays uniform),
        // but a Game Boy / Color cart is portrait and, at real scale, taller than a GBA cart — so it
        // renders taller than the GBA cell, filling the row's vertical slack, and reads as a proper
        // cartridge instead of a tiny chip. A GBA cart fills the landscape cell as before.
        let cellH = width / LibraryView.cardAspect
        let isGBA = game.system == .gba
        let cartH = isGBA ? cellH : cellH + 48                       // taller portrait cart (bounded by the row padding)
        let cartW = isGBA ? width : cartH * CartridgeView.cartAspect(for: game.system)
        CartridgeView(
            system: game.system,
            cover: CoverStore.image(at: coverURL),
            title: game.displayTitle,
            systemTag: game.system.shortName,
            intensity: isFocused ? 1 : 0.62,
            coverOpacity: isFocused ? 1 : 0.85,
            crop: game.coverCrop
        )
        .frame(width: cartW, height: cartH)
        .frame(width: width, height: max(cellH, cartH))   // uniform width; the cell grows for a taller cart
        // Flatten the vector cart (Canvas) into one GPU texture so the carousel's scroll scaling is
        // pure compositing — without this the Canvas re-rasterises every frame as it scales and the
        // scroll visibly hitches (same trick the launch cinematic uses).
        .drawingGroup()
        .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
        .animation(.default, value: isFocused)
    }
}

/// The bottom bar's single "Continue" capsule. It shows the most-recent session and resumes it on
/// tap; a long-press opens a menu of the last few sessions (no more side-swiping through them). A
/// faint stacked edge peeks behind the capsule when there's more than one, hinting at the menu.
private struct ContinueStrip: View {
    let sessions: [ContinuityCard]
    let game: (String) -> Game?
    let covers: [String: URL]
    let source: (ContinuityCard) -> String?
    let onResume: (Game) -> Void
    /// Fired on long-press when there's more than one session — the parent opens the fan-out "folder"
    /// of recent capsules (rendered at the root so it can spread over the whole shelf with a scrim).
    var onLongPress: () -> Void

    /// True while a finger is down mid-hold: drives the subtle "shrink into the shelf" acknowledgement
    /// so the user sees the capsule react the instant they press, before the folder opens.
    @State private var pressing = false

    /// Resolve each card to its game (dropping any whose ROM is missing), newest first, capped at 4.
    private var resolved: [(card: ContinuityCard, game: Game)] {
        Array(sessions.compactMap { c in game(c.metadata.romHash).map { (card: c, game: $0) } }.prefix(4))
    }

    var body: some View {
        if let top = resolved.first {
            // A plain view (not a Button) so tap-to-resume and long-press-to-expand are recognised as
            // separate, mutually exclusive gestures — a hold no longer also fires the tap.
            let capsule = NowPlayingCapsule(card: top.card, game: top.game,
                                            coverURL: covers[top.card.metadata.romHash],
                                            source: source(top.card))
                .contentShape(Rectangle())
                .onTapGesture { onResume(top.game) }

            if resolved.count > 1 {
                // A faint duplicate capsule peeking up behind hints that a long-press reveals the rest.
                capsule
                    .background(alignment: .top) {
                        Capsule().fill(.ultraThinMaterial)
                            .overlay(Capsule().stroke(DS.hairline, lineWidth: 0.75))
                            .frame(height: 54)
                            .padding(.horizontal, 12)
                            .offset(y: -6)
                            .opacity(0.55)
                    }
                    // While the finger is held the capsule presses in slightly, so there's a visible
                    // "something's happening" before the 0.35s hold completes and the folder fans open.
                    .scaleEffect(pressing ? 0.955 : 1)
                    .animation(.spring(response: 0.28, dampingFraction: 0.7), value: pressing)
                    // Long-press fans the recent sessions open like a folder — their own capsules, not
                    // a text menu — so picking up an earlier game is a tap on the real thing. A soft
                    // haptic on press-down confirms the hold registered, then a firmer thump on release
                    // marks the moment the folder opens.
                    .onLongPressGesture(minimumDuration: 0.35) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onLongPress()
                    } onPressingChanged: { isPressing in
                        pressing = isPressing
                        if isPressing {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
                        }
                    }
            } else {
                capsule
            }
        } else {
            Spacer(minLength: 0)
        }
    }
}

/// The Continue "folder", fanned open over the shelf: the recent sessions as their own upright capsules
/// behind a tap-away scrim. Capsules stay straight (no tilt); the delight is the entrance — they rise
/// and fade in with a short staggered spring, the stack unfurling from the bottom bar upward. Tap one
/// to resume, tap the scrim to close.
private struct ContinueFolder: View {
    let items: [(card: ContinuityCard, game: Game)]
    let cover: (String) -> URL?
    let source: (ContinuityCard) -> String?
    let onResume: (Game) -> Void
    let onClose: () -> Void

    /// Flips true on appear to drive the staggered rise-in.
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Frosted-glass backdrop: blur the shelf behind the folder rather than a thin black tint —
            // a see-through scrim let the busy carts show through and hurt legibility. The material
            // obscures them while keeping a hint of depth. A faint dark wash lifts contrast further.
            Rectangle()
                .fill(.thinMaterial)
                .overlay(Color.black.opacity(0.18))
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: shown)
                .onTapGesture { onClose() }

            VStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.element.card.metadata.romHash) { idx, item in
                    Button { onResume(item.game) } label: {
                        NowPlayingCapsule(card: item.card, game: item.game,
                                          coverURL: cover(item.card.metadata.romHash),
                                          source: source(item.card))
                            .frame(maxWidth: 360)
                    }
                    .buttonStyle(.plain)
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 26)
                    .scaleEffect(shown ? 1 : 0.96, anchor: .bottom)
                    // Bottom card first, then up the stack — the folder unfurls from the bar.
                    .animation(.spring(response: 0.4, dampingFraction: 0.74)
                        .delay(Double(items.count - 1 - idx) * 0.06), value: shown)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)   // sit lower, clear of the Library title above
        }
        .onAppear { shown = true }
    }
}

/// Apple-Music-style "now playing" capsule: the session's cartridge thumbnail, the game's title +
/// subtitle, and a Play glyph — glass background to match the mini-player. Purely visual; the enclosing
/// `ContinueStrip` owns the tap-to-resume and long-press menu.
private struct NowPlayingCapsule: View {
    let card: ContinuityCard
    let game: Game
    /// The game's box art, so the mini cartridge carries the same label as the shelf.
    var coverURL: URL? = nil
    /// The device this session came from, or nil when it's this device's own session.
    var source: String? = nil

    var body: some View {
        HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 1) {
                    Text(game.displayTitle)
                        .font(DS.mono(13, .semibold)).foregroundStyle(DS.textPrimary).lineLimit(1)
                    Text(subtitle)
                        .font(DS.mono(9)).foregroundStyle(DS.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.accent)
                    .padding(.trailing, 18)
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                // Liquid-glass rim: a soft, static top-lit specular highlight along the edge.
                Capsule().stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.5),
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.04),
                        ],
                        startPoint: UnitPoint(x: 0.5, y: 0.15),
                        endPoint: UnitPoint(x: 0.5, y: 0.95)
                    ),
                    lineWidth: 0.75
                )
            )
            .contentShape(Capsule())   // the whole capsule is the tap / long-press target
    }

    // The stylized cartridge — same visual language as the shelf and hero cart — reads crisp at this
    // size and stays on-brand, unlike the raw GBA framebuffer (a muddy, arbitrarily-cropped thumbnail).
    private var thumbnail: some View {
        // No systemTag — the "GBA" stamp is redundant clutter at this thumbnail size.
        CartridgeView(system: game.system, cover: CoverStore.image(at: coverURL),
                      title: game.displayTitle, systemTag: "",
                      crop: game.coverCrop)
            .frame(width: 44, height: 44)
    }

    private var subtitle: String {
        let time = card.metadata.timestamp.formatted(.relative(presentation: .named))
        // Tag the source hardware for a cross-device session; "Continue" for this device's own.
        return (source.map { "\($0) · " } ?? "Continue · ") + time
    }
}

/// The bottom-bar affordance for a session on a game this device doesn't have yet, whose source device
/// offered the ROM for transfer. Tapping downloads + imports the game (the opt-in, ephemeral Handoff
/// transfer); the normal resume capsule then appears for the actual continue.
private struct TransferCapsule: View {
    let card: ContinuityCard
    /// How many games are waiting (this card is the newest). >1 turns the capsule into a "pack" that
    /// receives them all in one tap.
    var count: Int = 1
    /// Runs the download + import; the parent view owns the async work and error surface.
    let accept: () async -> Void
    @State private var transferring = false

    private var titleText: String {
        count > 1 ? "\(count) games from \(card.metadata.deviceName)" : card.metadata.romTitle
    }
    private var subtitleText: String {
        if transferring { return "Transferring…" }
        return count > 1 ? "Tap to receive all" : "Transfer from \(card.metadata.deviceName)"
    }

    @State private var glow = false

    var body: some View {
        Button {
            guard !transferring else { return }
            transferring = true
            Task { await accept(); transferring = false }
        } label: {
            HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleText)
                        .font(DS.mono(13, .semibold)).foregroundStyle(DS.textPrimary).lineLimit(1)
                    Text(subtitleText)
                        .font(DS.mono(9)).foregroundStyle(DS.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: transferring ? "arrow.down.circle" : "square.and.arrow.down")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.textSecondary)
                    .symbolEffect(.pulse, isActive: transferring)
                    .padding(.trailing, 12)
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(.ultraThinMaterial, in: Capsule())
            // A slow breathing hairline so a waiting transfer quietly draws the eye without nagging —
            // monochrome, no coloured glow.
            .overlay(Capsule().stroke(.white.opacity(glow ? 0.5 : 0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(transferring)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { glow = true }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = card.thumbnailPNG, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            RoundedRectangle(cornerRadius: 7).fill(DS.background).frame(width: 40, height: 40)
        }
    }
}

/// The send "whoosh": the first three sent cartridges streak up off the top edge — toward iCloud —
/// fanned and staggered, over a soft launch flash and glowing trail. Mirrors the macOS `SendFlourish`.
/// Purely decorative; auto-dismisses via `onDone`.
private struct SendFlourishView: View {
    let games: [Game]
    let covers: [String: URL]
    let dest: String
    /// The live upload result: nil while uploading, then success/failure. Drives the chip's resolve.
    let result: Bool?
    let onDone: () -> Void

    @State private var launched = false
    @State private var arrived = false          // carts reached the iCloud chip; the chip pops in
    @State private var minHoldElapsed = false   // the chip has been on screen long enough to resolve
    @State private var finished = false

    private let cardW: CGFloat = 118
    private let flightDuration = 0.72

    var body: some View {
        GeometryReader { geo in
            let n = min(games.count, 3)
            let startY = geo.size.height - 150      // near the shelf / send origin
            // Sit the chip just clear of the nav bar — below the "Library" title, not crowding it.
            let cloud = CGPoint(x: geo.size.width / 2, y: 150)   // the iCloud chip the carts fly into
            ZStack {
                // Launch flash — a quiet monochrome bloom at the lift-off point (no coloured glow).
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.35), .clear],
                                         center: .center, startRadius: 0, endRadius: 85))
                    .frame(width: 180, height: 180)
                    .scaleEffect(launched ? 1.7 : 0.5)
                    .opacity(launched ? 0 : 0.7)
                    .position(x: geo.size.width / 2, y: startY)
                    .animation(.easeOut(duration: 0.4), value: launched)

                // Cartridges streak up and converge into the iCloud chip (shrinking as they "upload").
                ForEach(Array(games.prefix(3).enumerated()), id: \.element.id) { i, game in
                    let xOff: CGFloat = n == 1 ? 0 : (CGFloat(i) / CGFloat(n - 1) - 0.5) * 84
                    CartCard(game: game, coverURL: covers[game.romHash], width: cardW, isFocused: true)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                        .scaleEffect(launched ? 0.3 : 0.72)
                        .opacity(launched ? 0 : 1)
                        .position(x: launched ? cloud.x : geo.size.width / 2 + xOff,
                                  y: launched ? cloud.y : startY)
                        .animation(.easeIn(duration: flightDuration).delay(Double(i) * 0.07), value: launched)
                }

                cloudChip.position(cloud)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            launched = true
            DispatchQueue.main.asyncAfter(deadline: .now() + flightDuration) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) { arrived = true }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                minHoldElapsed = true
                maybeFinish()
            }
            // Never hang if a result somehow never arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if !finished { finished = true; onDone() }
            }
        }
        .onChange(of: result != nil) { _, _ in maybeFinish() }
    }

    /// The iCloud target the carts fly into: pulses "Sending…" while uploading, then snaps to a ✓ (with
    /// a soft success haptic) or a "couldn't reach iCloud" slash.
    private var cloudChip: some View {
        let icon: String
        let text: String
        let tint: Color
        switch result {
        case .some(true):  icon = "checkmark.circle.fill";   text = "Sent to \(dest)";       tint = DS.textPrimary
        case .some(false): icon = "icloud.slash";            text = "Couldn’t reach iCloud"; tint = DS.textSecondary
        case .none:        icon = "icloud.and.arrow.up.fill"; text = "Sending to \(dest)…";   tint = DS.textSecondary
        }
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: result == nil)
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(DS.mono(12, .semibold))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: arrived ? 8 : 0, y: 3)
        .scaleEffect(arrived ? 1 : 0.6)
        .opacity(arrived ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: arrived)
        .animation(.easeInOut(duration: 0.28), value: result)
    }

    private func maybeFinish() {
        guard !finished, minHoldElapsed, result != nil else { return }
        finished = true
        if result == true { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onDone() }   // let the ✓/✗ read for a beat
    }
}

/// The delete flourish: the removed game's cartridge **drops away** — falling under gravity, tumbling,
/// and fading — while the shelf closes the gap behind it. Mirrors the macOS `DeleteFlourish`; pair with
/// `SoundFX.playRemoved()`.
private struct DeleteFlourishView: View {
    let game: Game
    let covers: [String: URL]
    let onDone: () -> Void

    @State private var dropped = false

    var body: some View {
        GeometryReader { geo in
            let cardW: CGFloat = 150
            CartCard(game: game, coverURL: covers[game.romHash], width: cardW, isFocused: true)
                .rotationEffect(.degrees(dropped ? (game.romHash.hashValue % 2 == 0 ? 24 : -24) : 0))
                .scaleEffect(dropped ? 0.7 : 1)
                .opacity(dropped ? 0 : 1)
                .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
                .position(x: geo.size.width / 2,
                          y: dropped ? geo.size.height + cardW : geo.size.height / 2 - 24)
                .animation(.easeIn(duration: 0.55), value: dropped)
        }
        .ignoresSafeArea()
        .onAppear {
            dropped = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { onDone() }
        }
    }
}

/// AirDrop / NameDrop-style arrival: a just-received game's cartridge swoops in from the top edge with
/// a glow + radar waves + heavy haptic, announces "RECEIVED from <device>", then — the key bit — the
/// cart **morphs into its actual slot in the shelf** (glides + scales to the focused cart's measured
/// frame) as the glow/scrim/text dissolve. Tap anywhere to dismiss early; auto-dismisses after a beat.
private struct TransferArrivalOverlay: View {
    let system: GameSystem
    let title: String
    let deviceName: String
    let cover: UIImage?
    /// True once the background import finished and the new cart is focused — the overlay holds (radar
    /// waves) until then, so it never morphs into an empty/wrong slot.
    let ready: Bool
    /// The focused shelf cart's frame in global coords — the exit-morph target. Nil ⇒ fade in place.
    let targetFrame: CGRect?
    let onDone: () -> Void

    @State private var landed = false
    @State private var leaving = false
    @State private var minHoldElapsed = false

    private let cartW: CGFloat = 300

    var body: some View {
        GeometryReader { geo in
            let cartH = cartW / 1.78
            let restCenter = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2 - 80)
            let topStart = CGPoint(x: geo.size.width / 2, y: -cartH)
            let target = targetFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? restCenter
            let targetScale = (targetFrame?.width ?? cartW) / cartW
            let cartCenter = leaving ? target : (landed ? restCenter : topStart)
            let cartScale = leaving ? targetScale : (landed ? 1 : 0.5)

            ZStack {
                Color.black.opacity(leaving ? 0 : 1).ignoresSafeArea()

                RadarWaves(active: landed && !leaving)
                    .frame(width: 240, height: 240)
                    .position(restCenter)
                    .opacity(leaving ? 0 : 1)

                RadialGradient(colors: [Color.white.opacity(0.16), .clear],
                               center: .center, startRadius: 2, endRadius: 240)
                    .frame(width: 480, height: 480)
                    .scaleEffect(landed ? 1 : 0.2)
                    .opacity(landed && !leaving ? 1 : 0)
                    .blur(radius: 6)
                    .position(restCenter)

                CartridgeView(system: system, cover: cover, title: title,
                              systemTag: system.shortName)
                    .frame(width: cartW, height: cartH)
                    .shadow(color: .black.opacity(0.6), radius: landed && !leaving ? 24 : 6, y: 12)
                    .rotationEffect(.degrees(landed ? 0 : -8))
                    .scaleEffect(cartScale)
                    .position(cartCenter)

                VStack(spacing: 5) {
                    Text("RECEIVED").font(DS.mono(11, .semibold)).tracking(3)
                        .foregroundStyle(DS.textSecondary)
                    Text(title).font(DS.mono(16, .bold))
                        .foregroundStyle(DS.textPrimary)
                        .multilineTextAlignment(.center).lineLimit(2)
                    Text("from \(deviceName)").font(DS.mono(11))
                        .foregroundStyle(DS.textTertiary)
                }
                .padding(.horizontal, 40)
                .frame(width: geo.size.width)
                .position(x: geo.size.width / 2, y: restCenter.y + cartH / 2 + 64)
                .opacity(landed && !leaving ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onAppear(perform: run)
            .onChange(of: ready) { _, isReady in if isReady { maybeFinish() } }
            .onTapGesture(perform: finish)
        }
        .ignoresSafeArea()
    }

    private func run() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { landed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            SoundFX.shared.playReceived()
        }
        // Minimum on-screen hold so the arrival always registers, then land as soon as the import's ready
        // (the cart holds, radar-waving, if the download is still in flight).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { minHoldElapsed = true; maybeFinish() }
        // Safety net: never hang if the download stalls.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { maybeFinish(force: true) }
    }

    private func maybeFinish(force: Bool = false) {
        guard !leaving, force || (minHoldElapsed && ready) else { return }
        finish()
    }

    private func finish() {
        guard !leaving else { return }
        // Morph: glide + scale the cart into its shelf slot while the glow, waves, scrim and text
        // dissolve — the cart lands exactly on the real shelf cart, then the overlay is removed.
        withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { leaving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { onDone() }
    }
}

/// Concentric "sonar" rings that scale up and fade out on a staggered repeating loop — the radiating
/// waves of Apple's AirDrop/NameDrop.
private struct RadarWaves: View {
    var active: Bool
    private let rings = 4
    private let period = 2.6
    @State private var go = false

    var body: some View {
        ZStack {
            ForEach(0..<rings, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 2)
                    .scaleEffect(go ? 2.9 : 0.18)
                    .opacity(go ? 0 : 0.8)
                    .animation(active
                        ? .easeOut(duration: period).repeatForever(autoreverses: false)
                            .delay(Double(i) * period / Double(rings))
                        : .default,
                        value: go)
            }
        }
        .onAppear { if active { go = true } }
        .onChange(of: active) { _, now in go = now }
    }
}

/// Reports the focused shelf cart's frame (global coords) so the arrival animation can morph into it.
private struct FocusedCartFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// A multi-select picker for sending several games to the user's other devices at once — the batch
/// companion to a cartridge's "Send to My Devices" long-press. A checklist of the library (the
/// long-pressed cart pre-selected), an optional device target, and **Send** offers every checked game
/// through the same private-iCloud transfer.
private struct SendMultipleSheet: View {
    let games: [Game]
    let covers: [String: URL]
    let preselect: Game.ID?
    let sendTargets: [String]
    var onSend: ([Game], String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Game.ID> = []
    @State private var target: String?           // nil = all devices

    var body: some View {
        NavigationStack {
            List {
                if !sendTargets.isEmpty {
                    Section {
                        Picker("Send to", selection: $target) {
                            Text("All Devices").tag(String?.none)
                            ForEach(sendTargets, id: \.self) { device in
                                Text(device).tag(String?.some(device))
                            }
                        }
                    }
                }
                Section {
                    ForEach(games) { game in
                        Button { toggle(game.id) } label: {
                            HStack(spacing: 12) {
                                cover(for: game)
                                Text(game.displayTitle)
                                    .font(DS.mono(14)).foregroundStyle(DS.textPrimary).lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: selected.contains(game.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(game.id) ? DS.textPrimary : DS.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("\(selected.count) selected")
                        Spacer()
                        Button(selected.count == games.count ? "Deselect All" : "Select All") {
                            selected = selected.count == games.count ? [] : Set(games.map(\.id))
                        }
                        .textCase(nil)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.background)
            .navigationTitle("Send to My Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSend(games.filter { selected.contains($0.id) }, target)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if let preselect { selected = [preselect] } }
    }

    private func toggle(_ id: Game.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    @ViewBuilder private func cover(for game: Game) -> some View {
        Group {
            if let url = covers[game.romHash] {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.white.opacity(0.06)
                }
            } else {
                Color.white.opacity(0.06)
                    .overlay { Image(systemName: "gamecontroller").foregroundStyle(DS.textTertiary) }
            }
        }
        .frame(width: 42, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
