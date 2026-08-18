import AppKit

/// The little popover that hangs off the toolbar's cloud button: pick a **background sound** (Off ·
/// Rain · Storm) from a list and set its **volume**, both independent of the game's own audio. It
/// replaces the old tap-to-cycle button — the scene list makes every option reachable at a glance and
/// the slider gives fine control, mirroring the in-game volume slider up top. Changes write straight to
/// ``Settings`` (the live ``AmbientPlayer`` picks them up), and `onSceneChanged` lets the toolbar
/// button re-sync its icon.
final class AmbiencePanelView: NSView {
    private let onSceneChanged: (Settings.AmbientScene) -> Void
    private var rows: [AmbienceSceneRow] = []
    private var volumeSlider: SlimSlider?

    /// Symbol per scene — shared with the toolbar button so the two always agree.
    static func symbol(_ scene: Settings.AmbientScene) -> String {
        switch scene {
        case .off:   "cloud"
        case .rain:  "cloud.rain.fill"
        case .storm: "cloud.bolt.rain.fill"
        }
    }

    init(onSceneChanged: @escaping (Settings.AmbientScene) -> Void) {
        self.onSceneChanged = onSceneChanged

        let width: CGFloat = 236, pad: CGFloat = 12
        let titleH: CGFloat = 14, rowH: CGFloat = 34, volH: CGFloat = 28
        let scenes = Settings.AmbientScene.allCases
        let listTop = pad + titleH + 8
        let sepY = listTop + CGFloat(scenes.count) * rowH + 8
        let volTop = sepY + 1 + 8
        let height = volTop + volH + pad

        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true

        // Scene list.
        let current = Settings.shared.ambientScene
        for (i, scene) in scenes.enumerated() {
            let row = AmbienceSceneRow(scene: scene, symbol: Self.symbol(scene))
            row.frame = CGRect(x: pad - 4, y: listTop + CGFloat(i) * rowH,
                               width: width - (pad - 4) * 2, height: rowH)
            row.selected = (scene == current)
            row.onSelect = { [weak self] in self?.select(scene) }
            addSubview(row)
            rows.append(row)
        }

        // Volume: a speaker glyph and the same slim slider as the in-game volume.
        let spk = NSImageView()
        spk.imageScaling = .scaleNone
        spk.contentTintColor = NSColor(white: 1, alpha: 0.75)
        spk.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Ambience volume")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        spk.frame = CGRect(x: pad, y: volTop, width: 18, height: volH)
        addSubview(spk)

        let slider = SlimSlider(value: Settings.shared.ambientVolume, width: width - pad * 2 - 26)
        slider.frame = CGRect(x: pad + 26, y: volTop, width: width - pad * 2 - 26, height: volH)
        slider.onChange = { Settings.shared.ambientVolume = $0 }
        addSubview(slider)
        volumeSlider = slider
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { true }   // lay the list out top-to-bottom

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 12
        // Section header (drawn, not an NSTextField, so its inset clears the popover's rounded corner).
        DS.Text.label("Background Sound", size: 11, color: NSColor(white: 1, alpha: 0.55)).draw(at: CGPoint(x: pad + 8, y: pad))
        // A hairline between the scene list and the volume slider.
        let sepY = bounds.height - pad - 28 - 8
        NSColor(white: 1, alpha: 0.12).setFill()
        NSRect(x: pad, y: sepY, width: bounds.width - pad * 2, height: 1).fill()
    }

    private func select(_ scene: Settings.AmbientScene) {
        Settings.shared.ambientScene = scene
        rows.forEach { $0.selected = ($0.scene == scene) }
        onSceneChanged(scene)
    }

    // MARK: - Controller / keyboard focus (driven by the play view's guide)

    private var focusIndex = 0

    /// Start focus on the active scene — called when the popover opens.
    func beginControllerFocus() {
        focusIndex = rows.firstIndex { $0.selected } ?? 0
        updateFocus()
    }

    /// Move the focus ring through the scene list (wraps).
    func focusMove(_ forward: Bool) {
        guard !rows.isEmpty else { return }
        let n = rows.count
        focusIndex = ((focusIndex + (forward ? 1 : -1)) % n + n) % n
        updateFocus()
    }

    /// Select the focused scene.
    func activateFocused() {
        guard rows.indices.contains(focusIndex) else { return }
        select(rows[focusIndex].scene)
    }

    /// Nudge the background-sound volume (controller/keyboard left-right), reflecting it on the slider.
    func adjustVolume(_ increase: Bool) {
        let step = 0.08
        let v = max(0, min(1, Settings.shared.ambientVolume + (increase ? step : -step)))
        Settings.shared.ambientVolume = v
        volumeSlider?.setValue(v)
    }

    private func updateFocus() {
        for (i, r) in rows.enumerated() { r.focused = (i == focusIndex) }
    }
}

/// One selectable line in the ambience list: an icon, the scene name, and a checkmark when it's the
/// active scene. Lights up on hover like the toolbar's bare buttons.
private final class AmbienceSceneRow: NSView {
    let scene: Settings.AmbientScene
    var onSelect: (() -> Void)?
    var selected = false { didSet { refresh() } }
    var focused = false { didSet { refresh() } }   // controller/keyboard focus ring

    private let iconView = NSImageView()
    private let check = NSImageView()
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(scene: Settings.AmbientScene, symbol: String) {
        self.scene = scene
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.popover

        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.imageScaling = .scaleNone
        iconView.contentTintColor = .white
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.alphaValue = scene == .off ? 0.5 : 1
        addSubview(iconView)

        check.imageScaling = .scaleNone
        check.contentTintColor = .white
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        addSubview(check)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func layout() {
        iconView.frame = CGRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18)
        check.frame = CGRect(x: bounds.width - 14 - 14, y: (bounds.height - 14) / 2, width: 14, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        let str = DS.Text.plain(scene.title, size: 13, color: .white)
        let sz = str.size()
        str.draw(at: CGPoint(x: 40, y: (bounds.height - sz.height) / 2))
    }

    private func refresh() {
        check.isHidden = !selected
        let a: CGFloat = focused ? 0.18 : (hovered ? 0.12 : (selected ? 0.06 : 0))
        layer?.backgroundColor = NSColor(white: 1, alpha: a).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.borderWidth = focused ? 1.5 : 0
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh() }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() } }
}
