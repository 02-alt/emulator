import Foundation

/// Which console a game belongs to. Derived from the ROM's file extension, so it needs no
/// persistence/migration. 1.0 targets GBA; the enum is where future consoles land.
public enum GameSystem: String, Codable, Sendable, CaseIterable {
    case gba

    public var shortName: String { "GBA" }
    public var displayName: String { "Game Boy Advance" }

    /// Width÷height of the cartridge's cover label — a **landscape** slot on a GBA cart. The per-game
    /// cover cropper locks to this so what you crop is exactly what shows on the cartridge (the tile
    /// draws the cover aspect-fill into this same shape).
    public var coverAspect: Double { 1.88 }

    public static func infer(fromPath path: String) -> GameSystem { .gba }
}

/// A normalized crop rectangle over a cover's source image: origin + size in `[0,1]`, measured from
/// the image's **top-left** (so it maps straight onto a `CGImage`). Persisted with the game so the
/// cropper reopens on the last framing, and so the displayed cover can be re-rendered non-destructively
/// from the untouched source at any time.
public struct CoverCrop: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// The whole image, uncropped.
    public static let full = CoverCrop(x: 0, y: 0, width: 1, height: 1)
}

/// One game in the library. Persisted as JSON; UI-agnostic.
public struct Game: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var title: String            // cleaned, display-friendly
    public var romFilenameStem: String  // original filename (for box-art matching)
    public var romPath: String
    public var romHash: String          // sha256 hex prefix — library identity
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var secondsPlayed: Int
    public var coverPath: String?       // the cover shown on the cartridge (cropped output, if edited)
    // Per-game cover editing. `coverSourcePath` is the untouched original (downloaded box art or a
    // user-chosen image) that `coverCrop` is applied to → `coverPath`. Kept separate so re-cropping is
    // non-destructive. Both nil for games that only have the plain downloaded art (in which case
    // `coverPath` itself is the uncropped source until the user first edits it).
    public var coverSourcePath: String?
    public var coverCrop: CoverCrop?

    // Per-game settings (all optional so older library.json keeps decoding). `nil` on the gameplay
    // overrides means "inherit the app default"; the UI surfaces that as a "Default" choice.
    public var customTitle: String?     // overrides the auto-cleaned title in the UI
    public var notes: String?           // free-form reminder, shown in the detail panel
    public var isFavorite: Bool?        // pinned to the front of the carousel
    public var isHidden: Bool?          // tucked out of the normal carousel (still under the Hidden scope)
    public var overrideFilter: Int?     // Settings.DisplayFilter raw value (0 sharp / 1 smooth)
    public var overrideSpeed: Double?   // launch speed multiplier
    public var overrideSwapAB: Bool?    // swap the A/B buttons for this game only

    public var shelfIndex: Int          // which shelf (page) — used by M7
    public var slotIndex: Int           // position on the shelf

    public init(
        id: UUID = UUID(),
        title: String,
        romFilenameStem: String,
        romPath: String,
        romHash: String,
        addedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        secondsPlayed: Int = 0,
        coverPath: String? = nil,
        coverSourcePath: String? = nil,
        coverCrop: CoverCrop? = nil,
        customTitle: String? = nil,
        notes: String? = nil,
        isFavorite: Bool? = nil,
        isHidden: Bool? = nil,
        overrideFilter: Int? = nil,
        overrideSpeed: Double? = nil,
        overrideSwapAB: Bool? = nil,
        shelfIndex: Int = 0,
        slotIndex: Int = 0
    ) {
        self.id = id
        self.title = title
        self.romFilenameStem = romFilenameStem
        self.romPath = romPath
        self.romHash = romHash
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.secondsPlayed = secondsPlayed
        self.coverPath = coverPath
        self.coverSourcePath = coverSourcePath
        self.coverCrop = coverCrop
        self.customTitle = customTitle
        self.notes = notes
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.overrideFilter = overrideFilter
        self.overrideSpeed = overrideSpeed
        self.overrideSwapAB = overrideSwapAB
        self.shelfIndex = shelfIndex
        self.slotIndex = slotIndex
    }

    public var romURL: URL { URL(fileURLWithPath: romPath) }
    public var coverURL: URL? { coverPath.map { URL(fileURLWithPath: $0) } }

    /// The image the cropper should treat as its source: the explicit source if set, otherwise the
    /// current (still-uncropped) downloaded cover.
    public var coverSourceURL: URL? {
        (coverSourcePath ?? coverPath).map { URL(fileURLWithPath: $0) }
    }

    /// The title to show the player: their custom override if set, otherwise the cleaned filename title.
    public var displayTitle: String {
        if let t = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return title
    }

    public var favorite: Bool { isFavorite ?? false }
    public var hidden: Bool { isHidden ?? false }

    /// The console this game runs on, inferred from the ROM file extension.
    public var system: GameSystem { GameSystem.infer(fromPath: romPath) }
}
