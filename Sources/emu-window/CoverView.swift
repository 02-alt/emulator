import AppKit
import LibraryKit

/// One cartridge in the carousel (Analogue-OS style). The **selected** tile sits on a bright white
/// rounded square with its art full-strength; unselected tiles recede onto a dark-grey square and
/// carry a small pixel label beneath. When no cover art has been fetched, a generic cartridge
/// silhouette stands in ("unknown cartridge"). Clicking asks the carousel to select-or-launch.
@MainActor
class CartridgeTileView: NSView {
    let game: Game
    var onClick: ((Game) -> Void)?
    var onPlay: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onToggleHidden: (() -> Void)?
    var onReveal: (() -> Void)?
    var onContextRemove: (() -> Void)?
    var onContextSettings: (() -> Void)?
    /// (targetDevice) — nil means broadcast to all the user's devices.
    var onContextSendTo: ((String?) -> Void)?
    /// Open the multi-select send picker, pre-selecting this cartridge, so several games can be sent at
    /// once. nil target is decided inside the picker.
    var onContextSendMultiple: (() -> Void)?
    /// Show this PlayStation game's memory card (right-click ▸ Memory Card…).
    var onContextMemoryCard: (() -> Void)?
    /// End this game's in-progress session (right-click ▸ Close Session) — clears the resume state.
    var onContextCloseSession: (() -> Void)?

    /// This game has a live suspend/resume session (draws the "in progress" badge + enables Close
    /// Session). Set by the shelf from the on-disk resume state.
    private(set) var sessionActive = false
    func setSessionActive(_ active: Bool) {
        guard sessionActive != active else { return }
        sessionActive = active
        needsDisplay = true
    }
    /// The user's other devices, read lazily when the right-click menu opens (sync), so "Send to →"
    /// can list them. Empty → a plain broadcast "Send to My Devices".
    var sendTargets: () -> [String] = { [] }

    /// Drag-to-scrub, forwarded to the carousel: a press that moves becomes a horizontal drag; a
    /// press that doesn't is a plain click (select/launch).
    enum DragPhase { case began, changed, ended }
    var onCarouselDrag: ((DragPhase, CGFloat) -> Void)?
    private var dragStartX: CGFloat = 0
    private var dragMoved = false

    private var cover: NSImage?
    private var hovered = false
    /// The launch cinematic drives this tile's transform itself; disabling hover stops the tile's own
    /// hover spring from clobbering that animation.
    var hoverEnabled = true
    private var tracking: NSTrackingArea?
    private(set) var isSelected = false

    // Side (non-selected) cartridges recede: smaller + dimmed, like a cover-flow. (Dim rather than
    // blur — blurring moving layers re-renders every frame with edge artifacts and stutters.)
    private let sideScale: CGFloat = 0.82
    private let sideAlpha: CGFloat = 0.4

    override var isFlipped: Bool { true }   // square at top, label beneath

    init(game: Game) {
        self.game = game
        super.init(frame: .zero)
        wantsLayer = true
        if let url = game.coverURL, let img = NSImage(contentsOf: url) { cover = img }
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setCover(_ image: NSImage?) { cover = image; needsDisplay = true }

    /// Render a game's full cartridge (Liquid-Glass body with its cover in the label window) to a
    /// standalone image, so the send flourish can fly the *cartridge* rather than a bare cover. Drawn
    /// offscreen at `side`×`side` with a transparent background, the cart centered.
    static func cartridgeImage(for game: Game, side: CGFloat = 260) -> NSImage {
        let tile = CartridgeTileView(game: game)
        tile.frame = CGRect(x: 0, y: 0, width: side, height: side)
        let image = NSImage(size: NSSize(width: side, height: side))
        // The tile draws in a flipped (top-left origin) space and its glass reads the context's flip;
        // lock focus flipped so the snapshot matches — plain lockFocus() renders it upside down.
        image.lockFocusFlipped(true)
        tile.draw(tile.bounds)
        image.unlockFocus()
        return image
    }

    /// Update selection state and animate the scale/dim transition (the carousel drives this).
    func setSelected(_ selected: Bool, animated: Bool) {
        isSelected = selected
        needsDisplay = true
        updateVisuals(animated: animated)
    }

    private func updateVisuals(animated: Bool) {
        let base = isSelected ? 1.0 : sideScale
        // The hover lift is side-cart feedback only. The selected/centered cart never lifts, so
        // clicking a (hovered) side cart lands it cleanly at 1.0× instead of overshooting to 1.06×
        // and then shrinking when the pointer leaves.
        let scale = base * (hovered && !isSelected ? 1.06 : 1.0)
        let alpha = Float(isSelected ? 1.0 : sideAlpha)
        layer?.zPosition = isSelected ? 2 : (hovered ? 1 : 0)
        let transform = Motion.scaleAboutCenter(scale, in: bounds.size)
        if animated, let layer {
            // Spring the scale (natural lift) and ease the opacity — both cheap to animate while the
            // tile is also moving. Same response/damping as the frame translation spring so the cart's
            // growth and its slide settle in lockstep, which is what reads as "smooth".
            Motion.spring(layer, keyPath: "transform", to: NSValue(caTransform3D: transform),
                          response: 0.3, dampingRatio: 0.86)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = (layer.presentation() ?? layer).opacity
            fade.toValue = alpha
            fade.duration = Motion.quick
            fade.timingFunction = Motion.timing
            layer.add(fade, forKey: "opacity")
            layer.opacity = alpha
        } else {
            layer?.transform = transform
            layer?.opacity = alpha
        }
    }

    /// Spring the tile to a new frame with Core Animation (render-server driven), so the carousel's
    /// horizontal translation settles on the same clock and curve as the scale lift — one unified,
    /// snappy motion instead of an AppKit frame animation racing a separate CA scale spring. Reads the
    /// live presentation position so rapid arrow presses / flicks interrupt smoothly.
    func springFrame(to target: CGRect, velocity: CGFloat = 0,
                     response: CGFloat = 0.3, dampingRatio: CGFloat = 0.86) {
        guard let layer else { frame = target; return }
        let from = (layer.presentation() ?? layer).position
        frame = target                       // model value — AppKit recomputes layer.position/bounds
        let to = layer.position
        let dx = to.x - from.x
        guard abs(dx) > 0.01 || abs(to.y - from.y) > 0.01 else { return }
        let anim = Motion.springAnimation("position", from: NSValue(point: from), to: NSValue(point: to),
                                          response: response, dampingRatio: dampingRatio)
        // Hand off the flick's momentum so the row flows through the release instead of stopping and
        // re-accelerating (the "unnatural" halt). `initialVelocity` is normalized — 1.0 == the full
        // from→to distance per second — so divide the physical points/sec by that distance, and clamp
        // so a tiny snap-back distance can't turn a fast flick into a violent overshoot.
        if velocity != 0, abs(dx) > 1 {
            anim.initialVelocity = max(-30, min(30, velocity / dx))
        }
        layer.add(anim, forKey: "position")
    }

    /// Snap the tile back to its canonical resting appearance (no animation) if it has drifted — a
    /// cheap self-heal for a scale left stale by an interrupted scrub. A no-op when already correct
    /// or while the pointer is on the tile (hover owns the transform then), so it never fights a
    /// live animation: a settle sets the model value immediately, so mid-settle this already matches.
    func reassertResting(selected: Bool) {
        isSelected = selected
        guard !hovered, let layer else { return }
        let target = Motion.scaleAboutCenter(isSelected ? 1.0 : sideScale, in: bounds.size)
        if !CATransform3DEqualToTransform(layer.transform, target) {
            layer.transform = target
            layer.opacity = Float(isSelected ? 1.0 : sideAlpha)
        }
    }

    /// Continuous cover-flow focus for live dragging: 1 = centered/full, 0 = fully receded. Scale +
    /// dim follow the finger; both are GPU-cheap, so tracking is smooth. Call inside a
    /// disabled-actions CATransaction.
    func setFocus(_ f: CGFloat) {
        let clamped = max(0, min(1, f))
        let scale = sideScale + (1 - sideScale) * clamped
        layer?.zPosition = clamped > 0.5 ? 2 : 0
        layer?.transform = Motion.scaleAboutCenter(scale, in: bounds.size)
        layer?.opacity = Float(sideAlpha + (1 - sideAlpha) * clamped)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        dragMoved = false
        onCarouselDrag?(.began, 0)
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - dragStartX
        if abs(dx) > 3 { dragMoved = true }
        onCarouselDrag?(.changed, dx)
    }

    override func mouseUp(with event: NSEvent) {
        if dragMoved { onCarouselDrag?(.ended, event.locationInWindow.x - dragStartX) }
        else { onClick?(game) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    /// A right-click menu in Apple's HIG shape: the primary **Play** first, then the per-game state
    /// toggles and editor grouped together, a Finder reveal, and the destructive **Remove** alone at
    /// the bottom. Each item carries an SF Symbol so it's scannable at a glance; groups (not individual
    /// items) are the only things a divider separates — three dividers, four groups.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // A touch larger than the default system menu font so the menu reads clearly, with icons sized
        // to match the taller rows.
        let pointSize: CGFloat = 15
        menu.font = .menuFont(ofSize: pointSize)
        let symbolCfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        func icon(_ symbol: String) -> NSImage? {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolCfg)
            image?.isTemplate = true   // adopt the menu's text colour (incl. highlighted state)
            return image
        }
        func item(_ title: String, symbol: String, _ selector: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.image = icon(symbol)
            return item
        }
        func add(_ title: String, symbol: String, _ selector: Selector) {
            menu.addItem(item(title, symbol: symbol, selector))
        }

        add("Play", symbol: "play.fill", #selector(contextPlay))
        if sessionActive {
            add("Close Session", symbol: "stop.circle", #selector(contextCloseSession))
        }
        menu.addItem(.separator())
        add(game.favorite ? "Remove from Favorites" : "Add to Favorites",
            symbol: game.favorite ? "star.slash" : "star", #selector(contextToggleFavorite))
        add(game.hidden ? "Show Cartridge" : "Hide Cartridge",
            symbol: game.hidden ? "eye" : "eye.slash", #selector(contextToggleHidden))
        add("Game Settings…", symbol: "gearshape", #selector(contextSettings))
        if game.system == .ps1 {
            add("Memory Card…", symbol: "memorychip", #selector(contextMemoryCard))
        }
        menu.addItem(.separator())
        add("Show ROM in Finder", symbol: "folder", #selector(contextReveal))

        // Send / transfer — omitted for PlayStation: disc images (hundreds of MB per disc) are far
        // too large to hand off the way a small cartridge ROM is.
        if game.system != .ps1 {
            menu.addItem(.separator())
            // Send: a plain broadcast item, or — once the user has other devices with sessions — a
            // "Send to →" submenu that addresses one device (plus an "All My Devices" broadcast).
            let targets = sendTargets()
            if targets.isEmpty {
                add("Send to My Devices", symbol: "iphone.and.arrow.forward", #selector(contextSendBroadcast))
            } else {
                let sendItem = item("Send to…", symbol: "iphone.and.arrow.forward", #selector(contextSendBroadcast))
                sendItem.action = nil   // parent of a submenu isn't itself clickable
                let submenu = NSMenu()
                submenu.font = .menuFont(ofSize: pointSize)
                for device in targets {
                    let deviceItem = NSMenuItem(title: device, action: #selector(contextSendToDevice(_:)), keyEquivalent: "")
                    deviceItem.target = self
                    deviceItem.image = icon("laptopcomputer.and.iphone")
                    deviceItem.representedObject = device
                    submenu.addItem(deviceItem)
                }
                submenu.addItem(.separator())
                submenu.addItem(item("All My Devices", symbol: "square.stack.3d.up", #selector(contextSendBroadcast)))
                sendItem.submenu = submenu
                menu.addItem(sendItem)
            }
            // Pick several games to send in one go (opens a checklist, this cartridge pre-selected).
            add("Send Multiple…", symbol: "square.on.square", #selector(contextSendMultiple))
        }

        menu.addItem(.separator())
        add("Remove from Library", symbol: "trash", #selector(contextRemove))
        return menu
    }
    @objc private func contextPlay() { onPlay?() }
    @objc private func contextToggleFavorite() { onToggleFavorite?() }
    @objc private func contextToggleHidden() { onToggleHidden?() }
    @objc private func contextReveal() { onReveal?() }
    @objc private func contextRemove() { onContextRemove?() }
    @objc private func contextSettings() { onContextSettings?() }
    @objc private func contextSendBroadcast() { onContextSendTo?(nil) }
    @objc private func contextSendToDevice(_ sender: NSMenuItem) { onContextSendTo?(sender.representedObject as? String) }
    @objc private func contextSendMultiple() { onContextSendMultiple?() }
    @objc private func contextMemoryCard() { onContextMemoryCard?() }
    @objc private func contextCloseSession() { onContextCloseSession?() }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp],
                               owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ on: Bool) {
        guard hoverEnabled, hovered != on else { return }
        hovered = on
        updateVisuals(animated: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current != nil else { return }

        // The cartridge fills a square at the top of the tile — no name label beneath (the selected
        // cart's title shows big in the detail panel; side carts stay clean).
        let side = min(bounds.width, bounds.height)
        let tile = CGRect(x: (bounds.width - side) / 2, y: 0, width: side, height: side)

        // No background panel — the cartridge itself floats on the canvas. The body is Liquid Glass;
        // the fetched cover, if any, sits in its label window.
        let art = tile.insetBy(dx: side * 0.04, dy: side * 0.04)
        switch game.system {
        case .gba: drawGBACartridge(in: art)
        case .gbc: drawGBCCartridge(in: art)
        case .ps1: drawPS1Disc(in: art)
        }

        if game.favorite { drawFavoriteBadge(in: tile) }
        if sessionActive { drawSessionBadge(in: tile) }
    }

    /// Marks a game with a live resume session ("session running"). A small dark chip in the
    /// bottom-right with a white ▸ glyph — monochrome, so it reads as a status light, not a coloured
    /// accent, and out of the way of the favorite star (top-right) and the cover art's focal point.
    private func drawSessionBadge(in tile: CGRect) {
        let d: CGFloat = 22
        let badge = CGRect(x: tile.maxX - d - 6, y: tile.maxY - d - 6, width: d, height: d)  // flipped: bottom = maxY
        NSColor(white: 0, alpha: 0.5).setFill()
        NSBezierPath(ovalIn: badge).fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let glyph = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Session in progress")?
            .withSymbolConfiguration(cfg) {
            let s = glyph.size
            let box = CGRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2, width: s.width, height: s.height)
            glyph.draw(in: box, from: .zero, operation: .sourceOver, fraction: isSelected ? 1 : 0.85,
                       respectFlipped: true, hints: nil)
        }
    }

    /// A small gold star pinned to the cartridge's top-right, on a soft dark disc so it reads over any
    /// cover. Marks a favorited game (favorites also sort to the front of the carousel).
    private func drawFavoriteBadge(in tile: CGRect) {
        let d: CGFloat = 24
        let badge = CGRect(x: tile.maxX - d - 6, y: tile.minY + 6, width: d, height: d)  // flipped: top = minY
        NSColor(white: 0, alpha: 0.5).setFill()
        NSBezierPath(ovalIn: badge).fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemYellow]))
        if let star = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite")?
            .withSymbolConfiguration(cfg) {
            let s = star.size
            let box = CGRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2,
                             width: s.width, height: s.height)
            star.draw(in: box, from: .zero, operation: .sourceOver, fraction: isSelected ? 1 : 0.85,
                      respectFlipped: true, hints: nil)
        }
    }

    /// Recessed areas (grip, divider, label backing) — dark, so details read against the body.
    private var groundColor: NSColor { NSColor(calibratedWhite: 0.09, alpha: 1) }
    /// Etched detail on the glass (disc ring, hub) — a translucent white so it catches the light.
    private var glassDetail: NSColor { NSColor(white: 1, alpha: isSelected ? 0.22 : 0.14) }

    /// The cartridge body as Liquid Glass. Side carts sit dimmer (the parent blur/scale recede
    /// handles the rest); the selected cart is full-strength. See `DS.liquidGlass`.
    private func fillGlass(_ path: NSBezierPath, in rect: CGRect) {
        DS.liquidGlass(path, in: rect, intensity: isSelected ? 1.0 : 0.62)
    }

    /// Fill a media label region with the fetched cover art (aspect-fill, clipped to `path`), or —
    /// when no cover has been fetched yet — a minimalist default label (a monogram + system tag).
    private func fillLabel(_ path: NSBezierPath, bounds rect: CGRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        if let cover {
            cover.draw(in: CartridgeTileView.aspectFill(cover.size, in: rect),
                       from: .zero, operation: .sourceOver,
                       fraction: isSelected ? 1 : 0.85, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            drawBlankLabel(in: rect)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// The default label for a cart with no cover art: a two-initial monogram embossed into the dark
    /// ground, inside an inset label frame with corner ticks, plus a small system tag at the bottom.
    /// Minimalist and on-brand for the Analogue-OS look. Caller has already clipped to the label shape.
    private func drawBlankLabel(in rect: CGRect) {
        groundColor.setFill()
        NSBezierPath(rect: rect).fill()

        let dim: CGFloat = isSelected ? 0.36 : 0.24

        // Inset label frame — reads as a blank printed label rather than a void.
        let frame = rect.insetBy(dx: rect.width * 0.055, dy: rect.height * 0.09)
        let border = NSBezierPath(roundedRect: frame, xRadius: rect.width * 0.02, yRadius: rect.width * 0.02)
        border.lineWidth = 1
        NSColor(white: 1, alpha: dim * 0.35).setStroke()
        border.stroke()

        // Corner ticks (registration marks) at each frame corner, a touch brighter.
        let tick = min(frame.width, frame.height) * 0.11
        let ticks = NSBezierPath()
        for (x, y, sx, sy): (CGFloat, CGFloat, CGFloat, CGFloat) in
            [(frame.minX, frame.minY, 1, 1), (frame.maxX, frame.minY, -1, 1),
             (frame.minX, frame.maxY, 1, -1), (frame.maxX, frame.maxY, -1, -1)] {
            ticks.move(to: CGPoint(x: x, y: y)); ticks.line(to: CGPoint(x: x + sx * tick, y: y))
            ticks.move(to: CGPoint(x: x, y: y)); ticks.line(to: CGPoint(x: x, y: y + sy * tick))
        }
        ticks.lineWidth = 1.5
        NSColor(white: 1, alpha: dim * 0.7).setStroke()
        ticks.stroke()

        // Monogram: two initials, embossed so they read as molded into the plastic.
        let mono = Self.initials(from: game.title)
        let mfont = DS.pixel(min(rect.height * 0.42, rect.width * 0.30))
        let ms = NSAttributedString(string: mono, attributes: [.font: mfont]).size()
        drawEmbossed(mono, font: mfont, faceAlpha: dim,
                     at: CGPoint(x: rect.midX - ms.width / 2,
                                 y: rect.midY - ms.height / 2 - rect.height * 0.04))

        // System tag pinned near the bottom of the frame.
        let tag = DS.Text.label(game.system.shortName, size: max(8, rect.height * 0.09),
                                color: NSColor(white: 1, alpha: dim * 0.7), alignment: .center)
        let ts = tag.size()
        tag.draw(at: CGPoint(x: rect.midX - ts.width / 2, y: frame.maxY - ts.height - rect.height * 0.03))
    }

    /// Draw pixel text with a molded emboss: a dark shadow below and faint highlight above the face,
    /// lit from the top like the glass body. `p` is the text's top-left in the (flipped) label space.
    private func drawEmbossed(_ text: String, font: NSFont, faceAlpha: CGFloat, at p: CGPoint) {
        func stamp(_ color: NSColor, _ dy: CGFloat) {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                .draw(at: CGPoint(x: p.x, y: p.y + dy))
        }
        stamp(NSColor(white: 0, alpha: 0.55), 1.2)          // shadow (below, y grows down)
        stamp(NSColor(white: 1, alpha: 0.12), -1.0)         // highlight (above)
        stamp(NSColor(white: 1, alpha: faceAlpha), 0)       // face
    }

    /// Two-letter monogram from a title: the initials of the first two significant words, or the first
    /// two letters of a single-word title. Skips articles so "Legend of Zelda, The" → "LZ".
    private static func initials(from title: String) -> String {
        let stop: Set<String> = ["the", "of", "a", "an", "and", "or", "to", "in", "for", "de", "le", "la"]
        let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let sig = words.filter { !stop.contains($0.lowercased()) }
        let letters = sig.compactMap(\.first).map { String($0).uppercased() }
        if letters.count >= 2 { return letters[0] + letters[1] }
        let base = (sig.first ?? words.first ?? title).filter { $0.isLetter || $0.isNumber }
        if base.count >= 2 { return String(base.prefix(2)).uppercased() }
        return base.isEmpty ? "?" : base.uppercased()
    }

    /// Largest rect of the image's aspect ratio that covers `rect` (crops the overflow).
    static func aspectFill(_ size: NSSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// A GBA cartridge in its authentic case form, with every proportion measured from the reference
    /// outline: a wide body (**1.78:1**) with a **flat** top insertion edge, a subtle outward
    /// **shoulder bulge** at the top corners (the cart is a hair wider up top), the signature bold
    /// **seam arc** doming below the top edge, a large **label window** for cover art, and a **grip
    /// notch (▽)** at the bottom. Drawn in flipped coords (y grows down).
    private func drawGBACartridge(in rect: CGRect) {
        // Box = the silhouette's outer bounds. Everything below is expressed as fractions of it, taken
        // directly from a pixel analysis of the reference SVG.
        let bw = rect.width
        let bh = min(rect.height, bw / 1.78)
        let boxL = rect.midX - bw / 2, boxT = rect.midY - bh / 2
        func F(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: boxL + fx * bw, y: boxT + fy * bh)
        }

        // Outer silhouette, clockwise from the top-left of the flat top edge. The top corners bulge
        // out to the full width (the shoulders) then taper back to the straight sides.
        let tiX: CGFloat = 0.041          // flat top edge inset
        let sXL: CGFloat = 0.027, sXR: CGFloat = 0.973   // straight sides
        let bulgeY: CGFloat = 0.12        // where the shoulders reach full width
        let taperY: CGFloat = 0.30        // where the side settles straight
        let botRy: CGFloat = 0.06, bcX: CGFloat = 0.045  // bottom corner radii (y / x)

        let p = NSBezierPath()
        p.move(to: F(tiX, 0))
        p.line(to: F(1 - tiX, 0))                                                    // flat top edge
        p.curve(to: F(1, bulgeY), controlPoint1: F(1 - tiX * 0.35, 0),
                controlPoint2: F(1, bulgeY * 0.5))                                    // TR shoulder out
        p.curve(to: F(sXR, taperY), controlPoint1: F(1, bulgeY + 0.06),
                controlPoint2: F(sXR, taperY - 0.10))                                 // taper to side
        p.line(to: F(sXR, 1 - botRy))                                                // right side
        p.curve(to: F(1 - bcX, 1), controlPoint1: F(sXR, 1), controlPoint2: F(sXR, 1))   // BR corner
        p.line(to: F(bcX, 1))                                                        // bottom edge
        p.curve(to: F(sXL, 1 - botRy), controlPoint1: F(sXL, 1), controlPoint2: F(sXL, 1)) // BL corner
        p.line(to: F(sXL, taperY))                                                   // left side
        p.curve(to: F(0, bulgeY), controlPoint1: F(sXL, taperY - 0.10),
                controlPoint2: F(0, bulgeY + 0.06))                                   // taper to shoulder
        p.curve(to: F(tiX, 0), controlPoint1: F(0, bulgeY * 0.5),
                controlPoint2: F(tiX * 0.35, 0))                                      // TL shoulder in
        p.close()

        let bbox = CGRect(x: boxL, y: boxT, width: bw, height: bh)
        fillGlass(p, in: bbox)

        // Corner notch grooves: the small dark slots just inside each shoulder that set the grip tabs
        // apart from the body — a hallmark of the GBA cart's top corners.
        groundColor.setFill()
        for nx in [CGFloat(0.052), CGFloat(0.948)] {
            let slot = CGRect(x: F(nx, 0).x - bw * 0.006, y: F(nx, 0.02).y,
                              width: bw * 0.012, height: bh * 0.09)
            NSBezierPath(roundedRect: slot, xRadius: bw * 0.006, yRadius: bw * 0.006).fill()
        }

        // Shell seam: the bold dark arc that domes up toward the top edge at center — the cart's
        // signature line (the outline above stays flat). Sweeps almost corner to corner.
        let seam = NSBezierPath()
        seam.move(to: F(0.11, 0.11))
        seam.curve(to: F(0.89, 0.11), controlPoint1: F(0.33, 0.02), controlPoint2: F(0.67, 0.02))
        seam.lineWidth = max(1.5, bh * 0.024)
        seam.lineCapStyle = .round
        groundColor.setStroke()
        seam.stroke()

        // Label window — holds the game's cover art (or a blank space until it's fetched).
        let win = CGRect(x: F(0.145, 0.235).x, y: F(0.145, 0.235).y,
                         width: (0.853 - 0.145) * bw, height: (0.855 - 0.235) * bh)
        fillLabel(NSBezierPath(roundedRect: win, xRadius: bw * 0.03, yRadius: bw * 0.03), bounds: win)

        // Grip notch: a shallow ▽ just below the label's bottom edge.
        let notch = NSBezierPath()
        notch.move(to: F(0.405, 0.90))
        notch.line(to: F(0.595, 0.90))
        notch.line(to: F(0.5, 0.96))
        notch.close()
        groundColor.setFill()
        notch.fill()
    }

    /// A Game Boy / Game Boy Color cartridge: a near-square **portrait** shell with the console's
    /// hallmarks — ribbed thumb grips in the top corners, a recessed grip groove across the top, a
    /// large **square** label window for cover art, and a small ▽ insertion arrow at the foot. Same
    /// Liquid-Glass body + dark recesses as the GBA cart, so the two read as one family of carts.
    /// Drawn in flipped coords (y grows down).
    /// PS1 game as a game **disc** — the CD equivalent of the GBA cartridge. The cover art is printed
    /// on the disc face (clipped to the circle), with a clear clamping ring and a spindle hole at the
    /// center. Drawn flat in the same Liquid-Glass style as the cartridges.
    private func drawPS1Disc(in rect: CGRect) {
        let d = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let disc = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        let discPath = NSBezierPath(ovalIn: disc)

        let hubR = d * 0.165
        let hub = CGRect(x: c.x - hubR, y: c.y - hubR, width: hubR * 2, height: hubR * 2)

        // Plastic body — reads as a disc even before any cover art has loaded.
        fillGlass(discPath, in: disc)
        if let cover {
            // Printed label: the cover art wraps the disc face, clipped to the circle.
            NSGraphicsContext.current?.saveGraphicsState()
            discPath.addClip()
            cover.draw(in: CartridgeTileView.aspectFill(cover.size, in: disc), from: .zero,
                       operation: .sourceOver, fraction: isSelected ? 1 : 0.85, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.current?.restoreGraphicsState()
        } else {
            drawBlankDisc(disc: disc, center: c, hubR: hubR)
        }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(ovalIn: hub).addClip()
        fillGlass(discPath, in: disc)
        NSGraphicsContext.current?.restoreGraphicsState()

        // Etched rings that catch the light: outer rim, the hub edge, and a faint stacking ring.
        glassDetail.setStroke()
        let rim = NSBezierPath(ovalIn: disc.insetBy(dx: d * 0.015, dy: d * 0.015))
        rim.lineWidth = max(1, d * 0.006); rim.stroke()
        let hubRing = NSBezierPath(ovalIn: hub)
        hubRing.lineWidth = max(1, d * 0.006); hubRing.stroke()
        let sr = d * 0.115
        let stack = NSBezierPath(ovalIn: CGRect(x: c.x - sr, y: c.y - sr, width: sr * 2, height: sr * 2))
        stack.lineWidth = 1
        NSColor(white: 1, alpha: isSelected ? 0.12 : 0.08).setStroke(); stack.stroke()

        // Center spindle hole — a dark punch-out with a lit rim.
        let holeR = d * 0.05
        let hole = CGRect(x: c.x - holeR, y: c.y - holeR, width: holeR * 2, height: holeR * 2)
        groundColor.setFill(); NSBezierPath(ovalIn: hole).fill()
        glassDetail.setStroke()
        let hp = NSBezierPath(ovalIn: hole); hp.lineWidth = 1; hp.stroke()
    }

    /// The blank face of a disc with no cover yet: a dark disc grooved with faint concentric CD
    /// tracks, the title monogram stamped in the upper band (clear of the hub so the spindle hole
    /// never cuts it), and the system tag in the lower band. No rectangular label frame — that's a
    /// cartridge idiom that reads wrong on a circle.
    private func drawBlankDisc(disc: CGRect, center c: CGPoint, hubR: CGFloat) {
        let d = disc.width

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(ovalIn: disc).addClip()
        groundColor.setFill()
        NSBezierPath(ovalIn: disc).fill()

        // A single subtle groove near the outer rim — just enough CD character, nothing crossing the
        // monogram / tag in the inner label area.
        let groove: CGFloat = isSelected ? 0.08 : 0.05
        NSColor(white: 1, alpha: groove).setStroke()
        let gr = d * 0.45
        let ring = NSBezierPath(ovalIn: CGRect(x: c.x - gr, y: c.y - gr, width: gr * 2, height: gr * 2))
        ring.lineWidth = 1
        ring.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()

        let faceAlpha: CGFloat = isSelected ? 0.34 : 0.22

        // Monogram in the upper band, its baseline sitting just above the hub.
        let mono = Self.initials(from: game.title)
        let mfont = DS.pixel(d * 0.15)
        let ms = NSAttributedString(string: mono, attributes: [.font: mfont]).size()
        drawEmbossed(mono, font: mfont, faceAlpha: faceAlpha,
                     at: CGPoint(x: c.x - ms.width / 2, y: c.y - hubR - d * 0.03 - ms.height))

        // System tag in the lower band, mirrored below the hub.
        let tag = DS.Text.label(game.system.shortName, size: max(8, d * 0.058),
                                color: NSColor(white: 1, alpha: faceAlpha * 0.9), alignment: .center)
        let ts = tag.size()
        tag.draw(at: CGPoint(x: c.x - ts.width / 2, y: c.y + hubR + d * 0.04))
    }

    private func drawGBCCartridge(in rect: CGRect) {
        // Portrait body: a hair taller than wide, centered in the square art region.
        let aspect: CGFloat = 0.90                    // width ÷ height
        let bw = min(rect.width, rect.height * aspect)
        let bh = bw / aspect
        let boxL = rect.midX - bw / 2, boxT = rect.midY - bh / 2
        func F(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: boxL + fx * bw, y: boxT + fy * bh)
        }
        let bbox = CGRect(x: boxL, y: boxT, width: bw, height: bh)

        // Shell body — a rounded rectangle in Liquid Glass.
        let body = NSBezierPath(roundedRect: bbox, xRadius: bw * 0.06, yRadius: bw * 0.06)
        fillGlass(body, in: bbox)

        // Slot keys: the small dark notches cut into the top edge just inside each shoulder.
        groundColor.setFill()
        for nx in [CGFloat(0.05), CGFloat(0.95)] {
            let slot = CGRect(x: F(nx, 0).x - bw * 0.007, y: boxT,
                              width: bw * 0.014, height: bh * 0.05)
            NSBezierPath(roundedRect: slot, xRadius: bw * 0.006, yRadius: bw * 0.006).fill()
        }

        // Ribbed thumb grips: a few short vertical ridges tucked into each top corner.
        let ribs = NSBezierPath()
        for base in [CGFloat(0.055), CGFloat(0.85)] {          // left group, right group
            for i in 0..<4 {
                let x = boxL + (base + CGFloat(i) * 0.030) * bw
                ribs.move(to: CGPoint(x: x, y: boxT + bh * 0.055))
                ribs.line(to: CGPoint(x: x, y: boxT + bh * 0.125))
            }
        }
        ribs.lineWidth = max(1, bw * 0.010)
        ribs.lineCapStyle = .round
        groundColor.setStroke()
        ribs.stroke()

        // Thumb groove: a recessed horizontal pill across the top center, between the two grips.
        let grooveH = bh * 0.075
        let groove = CGRect(x: F(0.20, 0).x, y: boxT + bh * 0.045,
                            width: (0.80 - 0.20) * bw, height: grooveH)
        groundColor.setFill()
        NSBezierPath(roundedRect: groove, xRadius: grooveH / 2, yRadius: grooveH / 2).fill()

        // Label window — square (matches `GameSystem.gbc.coverAspect`), holds the cover art or the
        // blank default label.
        let winSide = bw * 0.68
        let win = CGRect(x: bbox.midX - winSide / 2, y: boxT + bh * 0.25,
                         width: winSide, height: winSide)
        fillLabel(NSBezierPath(roundedRect: win, xRadius: bw * 0.03, yRadius: bw * 0.03), bounds: win)

        // Insertion arrow: a shallow ▽ centered beneath the label.
        let notch = NSBezierPath()
        notch.move(to: F(0.44, 0.915))
        notch.line(to: F(0.56, 0.915))
        notch.line(to: F(0.5, 0.955))
        notch.close()
        groundColor.setFill()
        notch.fill()
    }
}
