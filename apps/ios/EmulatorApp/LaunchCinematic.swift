import SwiftUI
import AVFoundation
import UIKit
import LibraryKit

// The iOS cartridge launch cinematic — a SwiftUI port of the macOS `LaunchSequence.swift`
// (`Sources/emu-window/LaunchSequence.swift`). The focused cart lifts off the carousel to centre
// stage, holds a beat, then dives straight down into the (black) screen with a seat haptic — and the
// screen powers on into the Game Boy Advance startup clip before the live game is revealed.
//
// Drop this file into apps/ios/EmulatorApp/, add `gba-boot.mp4` to the app's Resources, and wire it
// up per INTEGRATION.md (edits to EmulatorApp.swift and LibraryView.swift).

// MARK: - Coordinator (shared via @Environment)

/// Holds the in-flight launch. `LibraryView` calls `begin` on a cart tap; the app root shows the
/// cinematic while `game != nil` and calls `end` when it finishes.
@MainActor
@Observable
final class LaunchCoordinator {
    private(set) var game: Game?
    private(set) var coverURL: URL?
    private(set) var startFrame: CGRect = .zero

    func begin(_ game: Game, coverURL: URL?, from frame: CGRect) {
        self.coverURL = coverURL
        self.startFrame = frame
        self.game = game
    }

    func end() { game = nil; coverURL = nil; startFrame = .zero }
}

// MARK: - Tuning (mirrors the macOS `LaunchAnimationConfig`)

private enum Cine {
    static let baseWidthCap: CGFloat = 360   // cart's centre-stage width, capped
    static let baseWidthFrac: CGFloat = 0.82 // …as a fraction of screen width otherwise
    static let stageCenterY: CGFloat = 0.42  // rest height as a fraction of the stage
    static let lift: Double = 0.55           // lift off the shelf
    static let hold: Double = 0.15           // beat at centre before the drop
    static let dive: Double = 0.5            // straight drop
    static let diveScale: CGFloat = 0.7      // shrink as it plunges
    static let diveDepth: CGFloat = 0.8      // how far below the bottom edge (× cart height)
    static let seatLead: Double = 0.12       // haptic lands this long before the cart is gone
    static let videoGap: Double = 0.1        // pause between the cart vanishing and power-on
    static let bootLength: Double = 4.0      // boot clip runtime before crossfading to the game
    static let toBlack: Double = 0.32        // dip to black at the end of the clip
    static let reveal: Double = 0.35         // fade the overlay away to reveal the game
    static let cartAspect: CGFloat = 1.78    // cart w:h (matches GBACartridgeView / LibraryView)
    static let screenAspect: CGFloat = 1.5   // GBA screen is 3:2
}

// MARK: - Cinematic view

struct LaunchCinematicView: View {
    let game: Game
    let coverURL: URL?
    /// The focused cart's frame in global (screen) coords, captured at tap time.
    let startFrame: CGRect
    /// Present the live game *beneath* the (opaque-black) overlay — push GameView onto the nav path.
    let onPresentGame: () -> Void
    /// Tear the cinematic down (root clears its coordinator so a future launch can start).
    let onDone: () -> Void

    private enum Phase { case shelf, lifted, dived }

    @State private var phase: Phase = .shelf
    @State private var cartFaded = false
    @State private var screenOn = false       // boot panel opacity
    @State private var screenSeated = false   // boot panel spring scale (0.9 → 1)
    @State private var blacked = false        // final fade-to-black cover
    @State private var rootGone = false       // fade the whole overlay away
    @State private var didFinish = false
    @State private var runTask: Task<Void, Never>?

    private let player = BootPlayer()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let baseWidth = min(w * Cine.baseWidthFrac, Cine.baseWidthCap)
            let baseHeight = baseWidth / Cine.cartAspect
            let stage = CGPoint(x: w / 2, y: h * Cine.stageCenterY)
            let panelW = min(w * 0.86, 440)
            let panelH = panelW / Cine.screenAspect

            ZStack {
                // Black stage: the library (already pure black) is hidden instantly beneath it.
                Color.black.ignoresSafeArea()

                // The GBA boot clip, seated where the cart lands.
                BootPlayerView(player: player)
                    .frame(width: panelW, height: panelH)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1))
                    .scaleEffect(screenSeated ? 1 : 0.9)
                    .opacity(screenOn ? 1 : 0)
                    .position(stage)

                // The hero cartridge — same artwork the carousel draws.
                GBACartridgeView(cover: coverImage, title: game.displayTitle,
                                 systemTag: game.system.shortName, intensity: 1, coverOpacity: 1)
                    .frame(width: baseWidth, height: baseHeight)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
                    .scaleEffect(cartScale(baseWidth: baseWidth))
                    .opacity(cartFaded ? 0 : 1)
                    .position(cartCenter(stage: stage, h: h, baseHeight: baseHeight))

                // Final dip to black, then the whole overlay fades away to reveal the game.
                Color.black.opacity(blacked ? 1 : 0).ignoresSafeArea()
            }
            .opacity(rootGone ? 0 : 1)
            .contentShape(Rectangle())
            .onTapGesture { finish() }   // a tap skips straight to the game
            .task { run() }
            .onDisappear { runTask?.cancel(); player.teardown() }
        }
    }

    // MARK: Poses (derived from `phase`, so animating `phase` animates position + scale)

    private func cartCenter(stage: CGPoint, h: CGFloat, baseHeight: CGFloat) -> CGPoint {
        switch phase {
        case .shelf:  return CGPoint(x: startFrame.midX, y: startFrame.midY)
        case .lifted: return stage
        case .dived:  return CGPoint(x: stage.x, y: h + baseHeight * Cine.diveDepth)
        }
    }

    private func cartScale(baseWidth: CGFloat) -> CGFloat {
        switch phase {
        case .shelf:  return max(0.2, startFrame.width / baseWidth)
        case .lifted: return 1
        case .dived:  return Cine.diveScale
        }
    }

    private var coverImage: UIImage? {
        coverURL.flatMap { UIImage(contentsOfFile: $0.path) }
    }

    // MARK: Sequence

    private func run() {
        runTask = Task { @MainActor in
            await Task.yield()   // let the first frame render at the shelf pose before animating

            // Phase 1 — lift off the shelf to centre stage (ease-in-out, like the Mac's lift).
            withAnimation(.timingCurve(0.42, 0, 0.2, 1, duration: Cine.lift)) { phase = .lifted }
            try? await Task.sleep(for: .seconds(Cine.lift + Cine.hold))
            if Task.isCancelled { return }

            // Phase 2 — drop straight down into the dark, shrinking and (near the end) fading out.
            withAnimation(.timingCurve(0.4, 0, 0.85, 0.6, duration: Cine.dive)) { phase = .dived }
            withAnimation(.easeIn(duration: Cine.dive * 0.4).delay(Cine.dive * 0.6)) { cartFaded = true }
            try? await Task.sleep(for: .seconds(Cine.dive - Cine.seatLead))
            if Task.isCancelled { return }
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()   // the "cha-chunk" seat
            try? await Task.sleep(for: .seconds(Cine.seatLead + Cine.videoGap))
            if Task.isCancelled { return }

            // Phase 3 — the screen powers on into the Game Boy Advance startup clip.
            if player.hasClip {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { screenSeated = true }
                withAnimation(.easeInOut(duration: 0.28)) { screenOn = true }
                player.onEnded = { finish() }   // fallback if the clip is shorter than bootLength
                player.play()
                try? await Task.sleep(for: .seconds(Cine.bootLength))
                if Task.isCancelled { return }
            }
            finish()
        }
    }

    /// End the intro: dip the clip to black, present the game beneath the opaque overlay, then fade the
    /// overlay away to reveal it. Idempotent (natural end, clip-ended fallback, and skip all call it).
    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        runTask?.cancel()
        Task { @MainActor in
            withAnimation(.easeInOut(duration: Cine.toBlack)) { blacked = true; screenOn = false }
            try? await Task.sleep(for: .seconds(Cine.toBlack))
            onPresentGame()
            try? await Task.sleep(for: .seconds(0.05))   // let GameView mount underneath
            withAnimation(.easeInOut(duration: Cine.reveal)) { rootGone = true }
            try? await Task.sleep(for: .seconds(Cine.reveal))
            player.teardown()
            onDone()
        }
    }
}

// MARK: - Boot clip (bundled gba-boot.mp4)

/// Owns the AVPlayer for the bundled Game Boy Advance startup clip. `hasClip` is false if the mp4 is
/// missing, so the caller can skip the power-on stage cleanly.
@MainActor
private final class BootPlayer {
    let player: AVPlayer?
    var onEnded: (() -> Void)?
    private var endObserver: NSObjectProtocol?

    init() {
        guard let url = Bundle.main.url(forResource: "gba-boot", withExtension: "mp4") else {
            NSLog("LaunchCinematic: missing gba-boot.mp4"); player = nil; return
        }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        player = p
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }
    }

    var hasClip: Bool { player != nil }
    func play() { player?.play() }

    func teardown() {
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

/// The clip filling a rounded 3:2 panel like a real console screen (videoGravity `.resize`, no letterbox).
private struct BootPlayerView: UIViewRepresentable {
    let player: BootPlayer
    func makeUIView(context: Context) -> PlayerLayerView { PlayerLayerView(player: player.player) }
    func updateUIView(_ uiView: PlayerLayerView, context: Context) {}
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(player: AVPlayer?) {
        super.init(frame: .zero)
        backgroundColor = .white   // the clip's own background is white
        playerLayer.player = player
        playerLayer.videoGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }
}
