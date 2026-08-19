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
        .sheet(item: $settingsGame) { GameSettingsView(game: $0) }
        .sheet(item: $detailsGame) { GameDetailsSheet(game: $0) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task(id: library.games.count) { await continuity.refreshBanner(for: library.games) }
        .onAppear {
            Task { await continuity.refreshBanner(for: library.games) }
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
                    onContextDetails: { detailsGame = $0 },
                    onContextSettings: { settingsGame = $0 },
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

            if let card = continuity.banner, let game = game(forHash: card.metadata.romHash) {
                NowPlayingCapsule(card: card, game: game)
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
    var onContextDetails: (Game) -> Void
    var onContextSettings: (Game) -> Void
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
private struct NowPlayingCapsule: View {
    let card: ContinuityCard
    let game: Game

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
        "Continue · " + card.metadata.timestamp.formatted(.relative(presentation: .named))
    }
}
