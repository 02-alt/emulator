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
    @State private var importing = false
    @State private var importError: String?
    @State private var focusedID: Game.ID?
    @State private var settingsGame: Game?
    @State private var detailsGame: Game?
    @State private var showSettings = false
    @State private var showSearch = false

    private static let gbaType = UTType(filenameExtension: "gba") ?? .data

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
                withAnimation(.snappy) { focusedID = game.id }
            }
        }
        // Apple-Music-style floating bottom bar: Settings · now-playing capsule · Import.
        .safeAreaInset(edge: .bottom) { bottomBar }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [Self.gbaType, .data],
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
            // Symmetric leading/trailing inset = half the free width, so the snap-aligned (focused)
            // cart lands dead-center in any orientation instead of being pinned to a fixed margin.
            let sideInset = max(20, (geo.size.width - cardW) / 2)

            VStack(spacing: 20) {
                Spacer(minLength: 0)

                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(library.games) { game in
                            // Tap the centered cart to launch it; tap any other cart to bring it to
                            // focus (scrolls it to center) rather than launching from off-center.
                            Group {
                                if game.id == focusedGame?.id {
                                    NavigationLink(value: PlayRequest(game: game)) {
                                        CartCard(game: game, coverURL: library.covers[game.romHash],
                                                 width: cardW, isFocused: true)
                                    }
                                } else {
                                    Button {
                                        withAnimation(.snappy) { focusedID = game.id }
                                    } label: {
                                        CartCard(game: game, coverURL: library.covers[game.romHash],
                                                 width: cardW, isFocused: false)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { detailsGame = game } label: {
                                    Label("Details", systemImage: "info.circle")
                                }
                                Button { settingsGame = game } label: {
                                    Label("Settings", systemImage: "slider.horizontal.3")
                                }
                                Button(role: .destructive) { library.delete(game) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            // Distance-scale for depth; the focus recede (glass + cover dim) is baked
                            // into the cart itself so a centered cart matches the Mac's selected cart.
                            .scrollTransition { view, phase in
                                view.scaleEffect(phase.isIdentity ? 1 : 0.9)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, sideInset)
                }
                // Pin the scroll view to the cart's height (+shadow room) so a horizontal scroll
                // view doesn't greedily claim the vertical space and push everything upward.
                .frame(height: cardH + 36)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $focusedID)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()   // let card shadows / receding neighbors overflow cleanly

                VStack(spacing: 8) {
                    focusedTitle
                    detailsHandle
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The currently centered cart (falls back to the first game before any scroll).
    private var focusedGame: Game? {
        library.games.first { $0.id == focusedID } ?? library.games.first
    }

    private var focusedTitle: some View {
        VStack(spacing: 4) {
            Text(focusedGame?.displayTitle ?? "")
                .font(DS.mono(16, .semibold)).foregroundStyle(DS.textPrimary)
                .lineLimit(1)
            Text(focusedGame?.system.displayName ?? "")
                .font(DS.mono(10)).foregroundStyle(DS.textTertiary)
        }
        .animation(.default, value: focusedID)
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
            Text("Tap ＋ to import a .gba ROM from Files")
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
        .padding(.horizontal, 16)
        .padding(.top, 8)
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
        GBACartridgeView(
            cover: coverURL.flatMap { UIImage(contentsOfFile: $0.path) },
            title: game.displayTitle,
            systemTag: game.system.shortName,
            intensity: isFocused ? 1 : 0.62,
            coverOpacity: isFocused ? 1 : 0.85
        )
        .frame(width: width, height: width / LibraryView.cardAspect)
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
            .overlay(Capsule().stroke(Color.green.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
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

    private var subtitle: String {
        "Continue · " + card.metadata.timestamp.formatted(.relative(presentation: .named))
    }
}
