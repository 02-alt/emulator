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

    @State private var path: [PlayRequest] = []

    init() {
        CrashReporter.install()   // capture crashes to Application Support/Emulator/crashes before any UI
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                LibraryView()
                    .navigationDestination(for: PlayRequest.self) {
                        GameView(game: $0.game, resume: $0.resume)
                    }
            }
            .environment(library)
            .environment(continuity)
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
    static let surface = Color(white: 0.10)
    static let hairline = Color.white.opacity(0.14)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.34)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
