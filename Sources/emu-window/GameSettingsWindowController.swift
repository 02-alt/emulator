import AppKit
import LibraryKit
import UniformTypeIdentifiers

/// Per-game settings, presented as a sheet from the library. Three sections — **Cover** (replace +
/// crop the art, non-destructively), **Details** (title override, notes, favorite/hidden), and
/// **Gameplay** (per-game filter / speed / A-B swap overrides) — laid out as a clean scrolling form
/// with a fixed title and a pinned Cancel/Save footer, in the app's pixel language. Saving renders the
/// cropped cover and hands the updated ``Game`` + image back to the host.
@MainActor
final class GameSettingsWindowController: NSObject {
    /// Fired on Save with the updated game and its freshly rendered cover image (nil if it couldn't be
    /// rendered). The host persists the game and refreshes the library.
    var onSaved: ((Game, NSImage?) -> Void)?
    /// Fired once the sheet has dismissed (Save or Cancel), so the host can drop its reference.
    var onClose: (() -> Void)?

    private let window: NSWindow
    private let view: GameSettingsView

    init(game: Game) {
        view = GameSettingsView(game: game)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Game Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = DS.Color.background
        window.titlebarAppearsTransparent = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 620)
        window.contentView = view

        view.onCancel = { [weak self] in self?.end() }
        view.onSave = { [weak self] game, image in
            self?.onSaved?(game, image)
            self?.end()
        }
    }

    /// Present as a sheet attached to the library window.
    func present(in parent: NSWindow) { parent.beginSheet(window) }

    private func end() {
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        onClose?()
    }
}

// MARK: - The settings surface

@MainActor
private final class GameSettingsView: NSView {
    var onCancel: (() -> Void)?
    var onSave: ((Game, NSImage?) -> Void)?

    private var game: Game
    private var sourcePath: String?          // the image the crop is applied to
    private let cropView: CropView

    // Working copies of the editable fields (committed to `game` on Save).
    private var wFavorite: Bool
    private var wHidden: Bool
    private var wFilter: Settings.DisplayFilter?
    private var wSpeed: Double?
    private var wSwap: Bool?

    private let titleField = GameSettingsView.makeField("Custom title (optional)")
    private let notesScroll = GameSettingsView.makeNotesField()
    private var notesText: NSTextView { notesScroll.documentView as! NSTextView }
    private let scroll = NSScrollView()
    private let form = NSStackView()
    private let chooseBtn = PixelActionButton(title: "Choose Image…")
    private let revertBtn = PixelActionButton(title: "Use Downloaded Art")
    private let autoBtn = PixelActionButton(title: "Auto Crop")
    private let resetBtn = PixelActionButton(title: "Reset Crop")
    private let cancelBtn = PixelActionButton(title: "Cancel")
    private let saveBtn = PixelActionButton(title: "Save", prominent: true)

    private let speedValues: [Double?] = [nil, 1.0, 1.5, 2.0]

    init(game: Game) {
        self.game = game
        self.sourcePath = game.coverSourcePath ?? game.coverPath
        self.cropView = CropView(targetAspect: CGFloat(game.system.coverAspect))
        self.wFavorite = game.favorite
        self.wHidden = game.hidden
        self.wFilter = game.overrideFilter.flatMap { Settings.DisplayFilter(rawValue: $0) }
        self.wSpeed = game.overrideSpeed
        self.wSwap = game.overrideSwapAB
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = DS.Color.background.cgColor

        titleField.stringValue = game.customTitle ?? ""
        notesText.string = game.notes ?? ""

        build()
        loadCurrentSource()
        refreshButtons()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Build

    private func build() {
        let titleLabel = NSTextField(labelWithAttributedString: DS.Text.title(game.displayTitle, size: 22))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Footer: Cancel · Save, pinned bottom-right, over a hairline.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.Color.hairline.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        [divider, cancelBtn, saveBtn].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0)
        }

        // Scrolling form between the title and the footer.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        addSubview(scroll)

        form.translatesAutoresizingMaskIntoConstraints = false
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = DS.Space.smd   // 12pt base row rhythm; sections break at lg (24) — a clean 2:1
        scroll.documentView = form

        buildForm()

        chooseBtn.onClick = { [weak self] in self?.chooseImage() }
        revertBtn.onClick = { [weak self] in self?.useDownloadedArt() }
        autoBtn.onClick = { [weak self] in self?.autoCrop() }
        resetBtn.onClick = { [weak self] in self?.cropView.resetCrop() }
        cancelBtn.onClick = { [weak self] in self?.onCancel?() }
        saveBtn.onClick = { [weak self] in self?.save() }

        let m = DS.Space.lg
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: m),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),

            saveBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            saveBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -m),
            cancelBtn.trailingAnchor.constraint(equalTo: saveBtn.leadingAnchor, constant: -DS.Space.sm),
            cancelBtn.centerYAnchor.constraint(equalTo: saveBtn.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: saveBtn.topAnchor, constant: -DS.Space.md),

            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DS.Space.md),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -DS.Space.md),

            form.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            form.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            form.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    private func buildForm() {
        // COVER ---------------------------------------------------------------
        addHeader("Cover")
        fullWidth(cropView, height: 240)
        let coverButtons = NSStackView(views: [chooseBtn, revertBtn, autoBtn, resetBtn])
        coverButtons.orientation = .horizontal
        coverButtons.spacing = DS.Space.sm
        form.addArrangedSubview(coverButtons)
        addHint("Drag inside the frame to reposition, drag a corner to resize. The crop is locked to the "
            + "cartridge label shape, so what you frame is what shows.")

        // DETAILS -------------------------------------------------------------
        addHeader("Details", topGap: DS.Space.lg)
        titleField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        form.addArrangedSubview(labeledRow("Title", titleField))
        labeledColumn("Notes", notesScroll, height: 60)   // adds itself to the form
        form.addArrangedSubview(labeledRow("Favorite", segmented(["Off", "On"], selected: wFavorite ? 1 : 0) {
            [weak self] in self?.wFavorite = ($0 == 1)
        }))
        form.addArrangedSubview(labeledRow("Hidden", segmented(["Off", "On"], selected: wHidden ? 1 : 0) {
            [weak self] in self?.wHidden = ($0 == 1)
        }))

        // GAMEPLAY ------------------------------------------------------------
        addHeader("Gameplay", topGap: DS.Space.lg)
        let filterSel = wFilter.map { $0.rawValue + 1 } ?? 0
        form.addArrangedSubview(labeledRow("Filter",
            segmented(["Default", "Sharp", "Smooth"], selected: filterSel) { [weak self] idx in
                self?.wFilter = idx == 0 ? nil : Settings.DisplayFilter(rawValue: idx - 1)
            }))
        let speedSel = speedValues.firstIndex(of: wSpeed) ?? 0
        form.addArrangedSubview(labeledRow("Speed",
            segmented(["Default", "1×", "1.5×", "2×"], selected: speedSel) { [weak self] idx in
                self?.wSpeed = self?.speedValues[idx] ?? nil
            }))
        let swapSel = wSwap.map { $0 ? 2 : 1 } ?? 0
        form.addArrangedSubview(labeledRow("Swap A / B",
            segmented(["Default", "Off", "On"], selected: swapSel) { [weak self] idx in
                self?.wSwap = idx == 0 ? nil : (idx == 2)
            }))
        addHint("Overrides apply only to this game. \"Default\" follows the app-wide Settings.")
    }

    // MARK: - Form builders

    private func addHeader(_ text: String, topGap: CGFloat = 0) {
        if topGap > 0, let last = form.arrangedSubviews.last { form.setCustomSpacing(topGap, after: last) }
        form.addArrangedSubview(NSTextField(labelWithAttributedString:
            DS.Text.label(text, size: 13, color: DS.Color.textPrimary)))
    }

    private func addHint(_ text: String) {
        let f = NSTextField(wrappingLabelWithString: "")
        f.attributedStringValue = DS.Text.plain(text, size: 12, color: DS.Color.textTertiary)
        f.isSelectable = false
        fullWidth(f, height: nil)
    }

    /// Pin a view to the form's full width (and optionally a fixed height).
    private func fullWidth(_ v: NSView, height: CGFloat?) {
        v.translatesAutoresizingMaskIntoConstraints = false
        form.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        if let height { v.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithAttributedString: DS.Text.label(title))
        l.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let r = NSStackView(views: [l, control])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = DS.Space.md
        return r
    }

    /// A label stacked *above* a full-width control (for multi-line fields like Notes), the label
    /// hugging its field at `xs` so the pair reads as one unit inside the form's wider row rhythm.
    private func labeledColumn(_ title: String, _ control: NSView, height: CGFloat) {
        control.translatesAutoresizingMaskIntoConstraints = false
        let l = NSTextField(labelWithAttributedString: DS.Text.label(title))
        let col = NSStackView(views: [l, control])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = DS.Space.xs
        form.addArrangedSubview(col)   // add first so width anchors resolve against the live tree
        col.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        control.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        control.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    private func segmented(_ titles: [String], selected: Int, _ onChange: @escaping (Int) -> Void) -> PixelSegmented {
        let seg = PixelSegmented(titles: titles, selected: selected)
        seg.onChange = onChange
        return seg
    }

    // MARK: - Source handling

    private func loadCurrentSource() {
        let image = sourcePath.flatMap { NSImage(contentsOfFile: $0) }
        cropView.setImage(image, initialCrop: image != nil ? game.coverCrop : nil)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let stored = CoverImaging.importSource(from: url, hash: self.game.romHash),
                      let image = NSImage(contentsOfFile: stored) else { NSSound.beep(); return }
                self.sourcePath = stored
                self.cropView.setImage(image, initialCrop: nil)   // centered default, then auto-framed
                self.refreshButtons()
                self.autoCrop()
            }
        }
    }

    private func useDownloadedArt() {
        let url = CoverImaging.downloadedURL(hash: game.romHash)
        guard let image = NSImage(contentsOf: url) else { NSSound.beep(); return }
        sourcePath = url.path
        cropView.setImage(image, initialCrop: nil)
        refreshButtons()
        autoCrop()
    }

    /// Suggest a crop from the image's salient region (Vision), off the main thread so the UI stays
    /// responsive; the result is applied back on the main thread.
    private func autoCrop() {
        guard let image = cropView.sourceImage,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let aspect = cropView.aspect
        autoBtn.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let suggestion = CoverAutoCrop.bestCrop(for: cg, targetAspect: aspect)
            DispatchQueue.main.async {
                guard let self else { return }
                if let suggestion { self.cropView.applyCrop(suggestion) }
                self.autoBtn.isEnabled = self.sourcePath != nil
            }
        }
    }

    private func refreshButtons() {
        saveBtn.isEnabled = true            // Save always commits Details/Gameplay, even with no cover
        resetBtn.isEnabled = sourcePath != nil
        autoBtn.isEnabled = sourcePath != nil
        let downloaded = CoverImaging.downloadedURL(hash: game.romHash)
        revertBtn.isHidden = !CoverImaging.hasDownloadedArt(hash: game.romHash)
            || sourcePath == downloaded.path
    }

    private func save() {
        // Cover (only when there's a source image to render from).
        if let sourcePath {
            let crop = cropView.normalizedCrop
            if let outPath = CoverImaging.renderCrop(sourcePath: sourcePath, crop: crop, hash: game.romHash) {
                game.coverSourcePath = sourcePath
                game.coverCrop = crop
                game.coverPath = outPath
            }
        }
        // Details.
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        game.customTitle = title.isEmpty ? nil : title
        let notes = notesText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        game.notes = notes.isEmpty ? nil : notes
        game.isFavorite = wFavorite ? true : nil
        game.isHidden = wHidden ? true : nil
        // Gameplay.
        game.overrideFilter = wFilter?.rawValue
        game.overrideSpeed = wSpeed
        game.overrideSwapAB = wSwap

        let image = game.coverPath.flatMap { NSImage(contentsOfFile: $0) }
        onSave?(game, image)
    }

    // MARK: - Fields

    private static func makeField(_ placeholder: String) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.font = DS.pixel(13)
        f.textColor = DS.Color.textPrimary
        f.drawsBackground = true
        f.backgroundColor = DS.Color.surface
        f.bezelStyle = .roundedBezel
        f.focusRingType = .none
        return f
    }

    /// A multi-line notes field inside a bordered scroll view (so long notes scroll rather than grow).
    private static func makeNotesField() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .lineBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = DS.Color.surface
        let tv = NSTextView()
        tv.font = DS.pixel(13)
        tv.textColor = DS.Color.textPrimary
        tv.backgroundColor = DS.Color.surface
        tv.drawsBackground = true
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        return scroll
    }
}

// MARK: - Button

/// A bordered pixel-chip button that fills on hover; `prominent` starts filled (the default action).
/// Local to this window so it can carry an enabled/disabled state without touching the shared controls.
@MainActor
private final class PixelActionButton: NSView {
    var onClick: (() -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }

    private let title: String
    private let prominent: Bool
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(title: String, prominent: Bool = false) {
        self.title = title
        self.prominent = prominent
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: DS.Text.label(title, size: 13).size().width + DS.Space.lg, height: 32)
    }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let filled = isEnabled && (prominent || hovered)
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                               xRadius: DS.Radius.control, yRadius: DS.Radius.control)
        if filled { DS.Color.tileSelected.setFill(); box.fill() }
        (isEnabled ? DS.Color.hairlineStrong : DS.Color.hairline).setStroke()
        box.lineWidth = 1.5; box.stroke()
        let textColor = filled ? DS.Color.background : (isEnabled ? DS.Color.textPrimary : DS.Color.textTertiary)
        let str = DS.Text.label(title, size: 13, color: textColor)
        let size = str.size()
        str.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { if isEnabled { onClick?() } }
}
