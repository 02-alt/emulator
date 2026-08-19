import SwiftUI
import LibraryKit

/// Navigation route into the play screen. `resume` = launched from the Continue banner, so the
/// game should load its Continuity snapshot after booting.
struct PlayRequest: Hashable {
    let game: Game
    var resume: Bool = false
}

@main
struct EmulatorApp: App {
    @State private var library = LibraryModel()
    @State private var continuity = ContinuityService()
    @State private var launcher = LaunchCoordinator()

    @State private var path: [PlayRequest] = []
    @State private var whatsNew: ReleaseNote?

    init() {
        CrashReporter.install()   // capture crashes to Application Support/Emulator/crashes before any UI
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                NavigationStack(path: $path) {
                    LibraryView()
                        .navigationDestination(for: PlayRequest.self) {
                            GameView(game: $0.game, resume: $0.resume)
                        }
                }

                // Cartridge launch cinematic: while a launch is in flight it covers the screen with an
                // opaque black stage, lifts the focused cart, dives it into the screen, plays the GBA
                // boot clip, then presents the game beneath itself and fades away to reveal it.
                if let game = launcher.game {
                    LaunchCinematicView(
                        game: game,
                        coverURL: launcher.coverURL,
                        startFrame: launcher.startFrame,
                        // Mount the game with the push animation SUPPRESSED, so it doesn't slide in
                        // from the trailing edge. The cinematic is still opaque-black over it at this
                        // point; it then fades away (rootGone) to cross-dissolve the game into view.
                        onPresentGame: {
                            var tx = Transaction()
                            tx.disablesAnimations = true
                            withTransaction(tx) { path.append(PlayRequest(game: game)) }
                        },
                        onDone: { launcher.end() })
                        .ignoresSafeArea()
                        .zIndex(1)
                }

                // In-app notification banners (trophy unlocks, etc.) ride above everything, including
                // the launch cinematic, and never intercept touches to the game or shelf beneath.
                NotificationBannerHost()
                    .zIndex(2)
            }
            .environment(library)
            .environment(continuity)
            .environment(launcher)
            .preferredColorScheme(.dark)
            .tint(.white)
            .sheet(item: $whatsNew) { note in
                WhatsNewView(note: note)
            }
            .task {
                AmbientPlayer.shared.apply()   // start the chosen soundscape (no-op if Off)
                // Diagnostic seam: EMU_DIAG_SEND attempts a real cross-device send on launch and logs
                // exactly why it fails (whether iCloud is usable at all, then any CloudKit error).
                if ProcessInfo.processInfo.environment["EMU_DIAG_SEND"] != nil, let g = library.games.first {
                    let signedIn = FileManager.default.ubiquityIdentityToken != nil
                    NSLog("[Encore] diag: cloudKitUsable=\(ContinuityService.cloudKitUsable) iCloudSignedIn=\(signedIn) container=\(ContinuityService.cloudContainer)")
                    let ok = await continuity.offerROM(game: g)
                    NSLog("[Encore] diag: offerROM returned \(ok) for \(g.displayTitle)")
                }
                // Automation seam: EMU_PREVIEW_BANNER pops a sample trophy banner on launch, so the
                // in-app notification can be demonstrated on-device where taps can't be scripted.
                if ProcessInfo.processInfo.environment["EMU_PREVIEW_BANNER"] != nil {
                    Task {
                        try? await Task.sleep(for: .seconds(1.0))
                        AppNotifier.shared.post(.trophy(title: "Nice! Got the hang of it", points: 5))
                    }
                }
                // Automation seam: EMU_AUTOPLAY opens the first game on launch (used to drive the
                // play screen from the simulator, where taps can't be scripted). No-op otherwise.
                if ProcessInfo.processInfo.environment["EMU_AUTOPLAY"] != nil,
                   let first = library.games.first {
                    path = [PlayRequest(game: first)]
                    return
                }
                // Auto-resume: jump straight into the most recent session when the setting is on.
                if AppSettings.autoResume {
                    await continuity.refreshBanner(for: library.games)
                    if let card = continuity.banner,
                       let game = library.games.first(where: { $0.romHash == card.metadata.romHash }) {
                        path = [PlayRequest(game: game, resume: true)]
                    }
                }
                // What's New: on the first launch after an update, present the release's notes — but
                // only when we're landing on the library, not jumping straight into a game.
                if path.isEmpty { whatsNew = WhatsNew.pending() }
            }
        }
    }
}

/// Flat "Analogue OS" tokens: pure-black canvas, monochrome white/grey, a monospaced type voice.
/// A small local echo of the macOS `DesignSystem` so the iOS UI reads from the same intent.
enum DS {
    static let background = Color.black
    static let hairline = Color.white.opacity(0.14)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.34)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
