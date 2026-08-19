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
            }
            .environment(library)
            .environment(continuity)
            .environment(launcher)
            .preferredColorScheme(.dark)
            .tint(.white)
            .task {
                AmbientPlayer.shared.apply()   // start the chosen soundscape (no-op if Off)
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
