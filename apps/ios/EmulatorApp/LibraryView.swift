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
    @State private var importing = false
    @State private var importError: String?
    /// Index of the centered cart in the coverflow — the single source of truth for which cart is
    /// focused (its title shows, it's the one that launches). The carousel keeps this in sync so the
    /// visual centre and the "focused" cart can never drift apart.
    @State private var selected = 0
    @State private var settingsGame: Game?
    @State private var detailsGame: Game?
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var arrival: ArrivalInfo?
    @State private var focusedCartFrame: CGRect?
    /// Set when the user taps "Send to My Devices" while game transfer is still off — drives the
    /// one-time consent alert before the first send. `target` is the chosen device (nil = broadcast).
    @State private var sendConsent: (game: Game, target: String?)?
    /// The user's other devices, so the context menu can offer "Send to → [device]". Empty → a plain
    /// broadcast "Send to My Devices".
    @State private var sendTargets: [String] = []

    /// A just-received transfer, driving the NameDrop-style arrival animation.
    struct ArrivalInfo: Identifiable {
        let id = UUID()
        let game: Game
        let deviceName: String
        let cover: UIImage?
    }

    // Every ROM extension we import, across all supported systems (GBA + Game Boy / Color), as UTTypes
    // for the Files picker. `.data` stays in the list too, so a ROM Files reports as plain data is
    // still selectable; `handleImport` filters on the real extension.
    private static let romTypes: [UTType] =
        ROMImporter.supportedExtensions.compactMap { UTType(filenameExtension: $0) }

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
                TransferArrivalOverlay(game: arrival.game, deviceName: arrival.deviceName,
                                       cover: arrival.cover, targetFrame: focusedCartFrame) {
                    self.arrival = nil   // cart has morphed into its shelf slot; remove the overlay
                }
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .navigationDestination(for: PlayRequest.self) { GameView(game: $0.game, resume: $0.resume) }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .sheet(item: $settingsGame) { GameSettingsView(game: $0) }
        .sheet(item: $detailsGame) { GameDetailsSheet(game: $0) }
        .sheet(isPresented: $showSettings) { SettingsView() }
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
    }

    static let cardAspect: CGFloat = 1.78
    static let maxCardHeight: CGFloat = 148   // portrait size; landscape shrinks to fit

    private var content: some View {
        GeometryReader { geo in
            // Size the cart to the vertical space actually available (capped at the portrait size),
            // so the title + handle always clear the bottom bar in the short landscape layout.
            let cardH = min(Self.maxCardHeight, max(96, geo.size.height - 180))
            let cardW = cardH * Self.cardAspect

            VStack(spacing: 20) {
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
                    onContextDelete: { library.delete($0) })
                    .frame(height: cardH + 40)

                VStack(spacing: 8) {
                    focusedTitle
                    detailsHandle
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

    private var bottomBar: some View {
        HStack(spacing: 12) {
            circleButton("gearshape") { showSettings = true }
                .accessibilityLabel("Settings")

            if !continuity.recentSessions.isEmpty {
                ContinueStrip(
                    sessions: continuity.recentSessions,
                    game: { game(forHash: $0) },
                    source: { continuity.sourceLabel(for: $0) })
            } else if let offer = continuity.transferOffer {
                TransferCapsule(card: offer.card) { await handleTransfer(offer) }
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

    private func sendToDevices(_ game: Game, target: String?) async {
        // Cross-device send travels through your private iCloud; without a provisioned container there's
        // nowhere for the game to go. Say that plainly instead of implying a network fault.
        guard ContinuityService.cloudKitUsable else {
            AppNotifier.shared.post(.info(
                "Sending needs iCloud — it isn’t set up on this build yet",
                symbol: "icloud.slash", caption: "Handoff"))
            return
        }
        let ok = await continuity.offerROM(game: game, targetDevice: target)
        let dest = target ?? "your devices"
        AppNotifier.shared.post(ok
            ? .info("Sent to \(dest)", symbol: "iphone.and.arrow.forward", caption: "Handoff")
            : .info("Couldn’t reach iCloud — try again", symbol: "icloud.slash", caption: "Handoff"))
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
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
    private func handleTransfer(_ offer: (card: ContinuityCard, fileName: String)) async {
        let romHash = offer.card.metadata.romHash
        guard let data = await continuity.downloadROM(romHash: romHash) else {
            importError = "Couldn’t fetch the game from your other device."
            return
        }
        // Name the imported file from the session's real title, not the sender's (possibly content-hash)
        // filename — otherwise that hash becomes the game's title and defeats box-art lookup. Keep the
        // sender's extension (it drives GBA/GBC system detection).
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
                return
            }
            // Apply the sender's box art (if any) before retiring the offer, so the cart shows the
            // exact same cover — a cleaned title often won't re-match the thumbnail repo here.
            var arrivalCover: UIImage?
            if let coverData = await continuity.downloadROMCover(romHash: romHash) {
                library.setCover(fromImageData: coverData, for: game)
                arrivalCover = UIImage(data: coverData)
            }
            await continuity.clearROM(romHash: romHash)   // ROM is local now — keep the cloud copy ephemeral
            await continuity.refreshBanner(for: library.games)
            await continuity.refreshTransferOffer(for: library.games)
            sendTargets = await continuity.sendTargets()
            // Focus the received game so the shelf centers it (its frame becomes the morph target),
            // then celebrate the arrival, NameDrop-style.
            if let idx = library.games.firstIndex(where: { $0.id == game.id }) { selected = idx }
            withAnimation(.easeOut(duration: 0.2)) {
                arrival = ArrivalInfo(game: game, deviceName: offer.card.metadata.deviceName, cover: arrivalCover)
            }
        } catch {
            importError = error.localizedDescription
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
                        .contextMenu {
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
                            Button(role: .destructive) { onContextDelete(games[i]) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
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
        // Every cell is the same landscape size (so the coverflow's scroll math stays uniform). A GBA
        // cart fills it; a Game Boy cart is genuinely smaller — portrait, at the cell's full height —
        // and centers within the cell, so the shelf reads as a mix of real cartridge sizes.
        let cellH = width / LibraryView.cardAspect
        let cartW = game.system == .gba ? width : cellH * CartridgeView.cartAspect(for: game.system)
        CartridgeView(
            system: game.system,
            cover: CoverStore.image(at: coverURL),
            title: game.displayTitle,
            systemTag: game.system.shortName,
            intensity: isFocused ? 1 : 0.62,
            coverOpacity: isFocused ? 1 : 0.85,
            crop: game.coverCrop
        )
        .frame(width: cartW, height: cellH)
        .frame(width: width, height: cellH)   // center the (possibly narrower) cart in the uniform cell
        // Flatten the vector cart (Canvas) into one GPU texture so the carousel's scroll scaling is
        // pure compositing — without this the Canvas re-rasterises every frame as it scales and the
        // scroll visibly hitches (same trick the launch cinematic uses).
        .drawingGroup()
        .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
        .animation(.default, value: isFocused)
    }
}

/// Apple-Music-style "now playing" capsule for the floating bottom bar: the last session's thumbnail,
/// the game, and a Play button. Tapping resumes from the Continuity snapshot. Fills the space between
/// the two circle buttons; glass background to match Apple Music's mini-player.
/// A horizontally paging strip of resume capsules — one per in-progress game, newest first. With a
/// single session it looks and behaves exactly like the old mini-player; with several (e.g. one paused
/// on the phone and one on the Mac) you swipe between them, each labelled with its source device.
private struct ContinueStrip: View {
    let sessions: [ContinuityCard]
    let game: (String) -> Game?
    let source: (ContinuityCard) -> String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(sessions, id: \.metadata.romHash) { card in
                    if let g = game(card.metadata.romHash) {
                        NowPlayingCapsule(card: card, game: g, source: source(card))
                            .containerRelativeFrame(.horizontal)   // one capsule per page
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .frame(height: 54)
    }
}

private struct NowPlayingCapsule: View {
    let card: ContinuityCard
    let game: Game
    /// The device this session came from, or nil when it's this device's own session.
    var source: String? = nil

    var body: some View {
        NavigationLink(value: PlayRequest(game: game, resume: true)) {
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
                    .foregroundStyle(.green)
                    .padding(.trailing, 12)
            }
            .padding(.leading, 8)
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
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = card.thumbnailPNG, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            // No captured frame yet: preview the game's stylized cartridge label, like the shelf.
            CartridgeView(system: game.system, cover: nil,
                          title: game.displayTitle, systemTag: game.system.shortName)
                .frame(width: 40, height: 40)
        }
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
    /// Runs the download + import; the parent view owns the async work and error surface.
    let accept: () async -> Void
    @State private var transferring = false

    var body: some View {
        Button {
            guard !transferring else { return }
            transferring = true
            Task { await accept(); transferring = false }
        } label: {
            HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.metadata.romTitle)
                        .font(DS.mono(13, .semibold)).foregroundStyle(DS.textPrimary).lineLimit(1)
                    Text(transferring ? "Transferring…" : "Transfer from \(card.metadata.deviceName)")
                        .font(DS.mono(9)).foregroundStyle(DS.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: transferring ? "arrow.down.circle" : "square.and.arrow.down")
                    .font(.system(size: 15))
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, isActive: transferring)
                    .padding(.trailing, 12)
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.blue.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(transferring)
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

/// AirDrop / NameDrop-style arrival: a just-received game's cartridge swoops in from the top edge with
/// a glow + radar waves + heavy haptic, announces "RECEIVED from <device>", then — the key bit — the
/// cart **morphs into its actual slot in the shelf** (glides + scales to the focused cart's measured
/// frame) as the glow/scrim/text dissolve. Tap anywhere to dismiss early; auto-dismisses after a beat.
private struct TransferArrivalOverlay: View {
    let game: Game
    let deviceName: String
    let cover: UIImage?
    /// The focused shelf cart's frame in global coords — the exit-morph target. Nil ⇒ fade in place.
    let targetFrame: CGRect?
    let onDone: () -> Void

    @State private var landed = false
    @State private var leaving = false

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

                RadialGradient(colors: [Color.blue.opacity(0.5), .clear],
                               center: .center, startRadius: 2, endRadius: 240)
                    .frame(width: 480, height: 480)
                    .scaleEffect(landed ? 1 : 0.2)
                    .opacity(landed && !leaving ? 1 : 0)
                    .blur(radius: 6)
                    .position(restCenter)

                CartridgeView(system: game.system, cover: cover, title: game.displayTitle,
                              systemTag: game.system.shortName)
                    .frame(width: cartW, height: cartH)
                    .shadow(color: .blue.opacity(0.55), radius: landed && !leaving ? 34 : 6, y: 12)
                    .rotationEffect(.degrees(landed ? 0 : -8))
                    .scaleEffect(cartScale)
                    .position(cartCenter)

                VStack(spacing: 5) {
                    Text("RECEIVED").font(DS.mono(11, .semibold)).tracking(3)
                        .foregroundStyle(.blue)
                    Text(game.displayTitle).font(DS.mono(16, .bold))
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
            .onTapGesture(perform: finish)
        }
        .ignoresSafeArea()
    }

    private func run() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { landed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { finish() }
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
                    .stroke(Color.blue.opacity(0.55), lineWidth: 2.5)
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
