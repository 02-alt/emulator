import AppKit
import GameController
import LibraryKit

/// The Settings window — a thin `NSWindow` wrapper around the shared ``SettingsView``. Used by the
/// **Library** (where a standalone window is appropriate); the **play window** embeds the same
/// ``SettingsView`` inline via ``SettingsOverlayView`` instead of spawning a window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Fired when the window closes — the library uses it to refresh RetroAchievements after a login.
    var onClose: (() -> Void)?
    /// Forwarded from ``SettingsView`` — the library wipes downloaded art and re-fetches it.
    var onResetImageCache: (() -> Void)? {
        didSet { settings.onResetImageCache = onResetImageCache }
    }

    private let window: NSWindow
    private let settings = SettingsView()

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = DS.Color.background
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.level = .floating   // stays above the app's main window while open
        window.delegate = self
        settings.onCredentialsSaved = { [weak self] in self?.onClose?() }
        window.contentView = settings
    }

    func show() {
        settings.refresh()   // this window is reused, so re-read Settings (values may have changed
                             // elsewhere while it was closed — e.g. the in-game ambience popover)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        settings.commit()   // persist any edited-but-unsaved RA fields
        onClose?()
    }

    /// Close as soon as the window loses focus — i.e. the moment the user clicks the app's main
    /// window (or another app), like a popover. `commit()` runs via `windowWillClose`.
    func windowDidResignKey(_ notification: Notification) {
        window.close()
    }
}

// MARK: - Settings view

/// The Analogue-OS-styled settings surface (pure black, Departure Mono pixel type, uppercase hairline
/// labels): a left rail of tabs (Video · Audio · Emulation · Achievements · Storage) driving a content
/// pane; each control writes straight through to ``Settings`` (live) or ``RACredentials``. Reused by
/// both the standalone Settings window and the in-game ``SettingsOverlayView``.
@MainActor
final class SettingsView: NSView {
    /// Fired when RA credentials are saved via the Save button (a login), so the library can refresh.
    var onCredentialsSaved: (() -> Void)?
    /// Fired by "Reset Image Cache" — the library wipes downloaded art and re-fetches it. When unset
    /// (e.g. the in-game overlay, which has no library), the button falls back to a plain cache wipe.
    var onResetImageCache: (() -> Void)?

    private let rail = NSStackView()
    private let content = NSView()
    private let scroll = NSScrollView()
    private var railItems: [SidebarItem] = []
    private var selected = 0

    // RetroAchievements fields are held so they can be persisted on Save / dismissal.
    private let raUser = SettingsView.makeField(placeholder: "Username")
    private let raKey = SettingsView.makeField(placeholder: "Web API key")

    /// The download link for a found update (About tab), opened by the Download button.
    private var pendingUpdateURL: URL?

    private enum Tab: Int, CaseIterable {
        case video, audio, controls, emulation, achievements, storage, about
        var title: String {
            switch self {
            case .video: "Video"
            case .audio: "Audio"
            case .controls: "Controls"
            case .emulation: "Emulation"
            case .achievements: "Achievements"
            case .storage: "Storage"
            case .about: "About"
            }
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = DS.Color.background.cgColor
        build()
        select(0)
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Rebuild the visible pane so its controls re-read the latest ``Settings``. The window is reused,
    /// so a value changed elsewhere (e.g. the in-game ambience popover) while it was closed would
    /// otherwise leave the pane showing a stale snapshot.
    func refresh() { select(selected) }

    /// Persist any edited-but-unsaved RA fields. Call before the view is dismissed/closed.
    func commit() {
        if RACredentials.stored?.username != raUser.stringValue
            || RACredentials.stored?.apiKey != raKey.stringValue {
            RACredentials.store(username: raUser.stringValue.trimmingCharacters(in: .whitespaces),
                                apiKey: raKey.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Chrome

    private func build() {
        // Left rail of tabs.
        rail.orientation = .vertical
        rail.alignment = .leading
        rail.spacing = DS.Space.xs
        rail.translatesAutoresizingMaskIntoConstraints = false
        railItems = Tab.allCases.map { tab in
            let item = SidebarItem(title: tab.title) { [weak self] in self?.select(tab.rawValue) }
            rail.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: rail.widthAnchor).isActive = true
            return item
        }
        addSubview(rail)

        // Hairline divider between rail and content.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.Color.hairline.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: topAnchor, constant: DS.Space.md),
            rail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.md),
            rail.widthAnchor.constraint(equalToConstant: 150),

            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: DS.Space.md),
            divider.widthAnchor.constraint(equalToConstant: 1),

            content.topAnchor.constraint(equalTo: topAnchor, constant: DS.Space.lg),
            content.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: DS.Space.xl),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.xl),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Space.lg),
        ])

        // A scroll view fills the content area so tall panes (e.g. Controls) can scroll.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    // MARK: - Tab switching

    private func select(_ index: Int) {
        selected = index
        for (i, item) in railItems.enumerated() { item.setSelected(i == index) }

        let pane = makePane(for: Tab(rawValue: index) ?? .video)
        // A flipped document view so the pane grows top-down and scrolls when it's taller than the pane.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        pane.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: doc.topAnchor),
            pane.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scroll.contentView.scroll(to: .zero)   // start each tab at the top
    }

    /// Build the vertical stack of controls for one tab.
    private func makePane(for tab: Tab) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.md

        switch tab {
        case .video:
            stack.addArrangedSubview(header("Display"))
            let filter = PixelSegmented(titles: Settings.DisplayFilter.allCases.map(\.title),
                                        selected: Settings.shared.displayFilter.rawValue)
            filter.onChange = { Settings.shared.displayFilter = Settings.DisplayFilter(rawValue: $0) ?? .sharp }
            stack.addArrangedSubview(row("Filter", filter))
            stack.addArrangedSubview(hint("Sharp keeps every pixel crisp. Smooth softens the image as it scales. "
                + "LCD replicates a real Game Boy Advance panel — corrected colors and a subpixel grid."))

            let backlit = onOff(Settings.shared.lcdBacklit) { Settings.shared.lcdBacklit = $0 }
            stack.addArrangedSubview(row("Backlit Panel", backlit))
            let ghosting = onOff(Settings.shared.lcdGhosting) { Settings.shared.lcdGhosting = $0 }
            stack.addArrangedSubview(row("LCD Ghosting", ghosting))
            stack.addArrangedSubview(hint("For the LCD filter only. Backlit gives the bright SP (AGS-101) look; "
                + "off is the dim original GBA. Ghosting reproduces the panel's slow pixel response."))

            stack.addArrangedSubview(header("Preview"))
            stack.addArrangedSubview(LCDPreviewView())
            stack.addArrangedSubview(hint("A live sample rendered through the current settings. "
                + "The sweeping sun shows the ghosting trail; the checker patch shows the LCD grid."))

        case .audio:
            // Two independent levels the player balances against each other: the game's own audio and
            // the looping background ambience. Each writes straight through to ``Settings`` (live).
            stack.addArrangedSubview(header("Volume"))
            stack.addArrangedSubview(volumeRow("Game", value: Settings.shared.volume) {
                Settings.shared.volume = $0
            })
            stack.addArrangedSubview(volumeRow("Background", value: Settings.shared.ambientVolume) {
                Settings.shared.ambientVolume = $0
            })
            stack.addArrangedSubview(hint("Balance the game's own audio against the background ambience. "
                + "Game audio is muted automatically while fast-forwarding."))

            stack.addArrangedSubview(header("Ambience"))
            let scene = PixelSegmented(titles: Settings.AmbientScene.allCases.map(\.title),
                                       selected: Settings.shared.ambientScene.rawValue)
            scene.onChange = { Settings.shared.ambientScene = Settings.AmbientScene(rawValue: $0) ?? .off }
            stack.addArrangedSubview(row("Sound", scene))
            stack.addArrangedSubview(hint("A looping background ambience — plays in the Library and in-game. "
                + "Set its level with the Background slider above."))

        case .controls:
            stack.addArrangedSubview(header("Keyboard"))
            // Two columns (D-pad · Start on the left, face + shoulders + Select on the right) so all
            // ten bindings fit without scrolling.
            func bindField(_ input: Settings.PadInput) -> KeyBindField {
                let f = KeyBindField(code: Settings.shared.keyCode(for: input))
                f.onBind = { [weak f] code in
                    Settings.shared.setKeyCode(code, for: input)
                    f?.setCode(code)
                }
                return f
            }
            func keyLabel(_ s: String) -> NSTextField {
                NSTextField(labelWithAttributedString: DS.Text.label(s))
            }
            let grid = NSGridView()
            grid.rowSpacing = DS.Space.sm
            grid.columnSpacing = DS.Space.md
            let pairs: [(Settings.PadInput, Settings.PadInput)] =
                [(.up, .a), (.down, .b), (.left, .l), (.right, .r), (.start, .select)]
            for (lhs, rhs) in pairs {
                grid.addRow(with: [keyLabel(lhs.title), bindField(lhs), keyLabel(rhs.title), bindField(rhs)])
            }
            stack.addArrangedSubview(grid)

            let reset = PixelButton(title: "Reset to Defaults") { [weak self] in
                Settings.shared.resetKeyBindings()
                self?.select(Tab.controls.rawValue)   // rebuild the pane to show restored keys
            }
            stack.addArrangedSubview(reset)
            stack.addArrangedSubview(hint("Click a key, then press the key you want to bind. "
                + "Changes apply immediately, even mid-game."))

            stack.addArrangedSubview(header("Controller"))
            let swap = onOff(Settings.shared.swapAB) { Settings.shared.swapAB = $0 }
            stack.addArrangedSubview(row("Swap A / B", swap))
            let stick = onOff(Settings.shared.joystickAsDpad) { Settings.shared.joystickAsDpad = $0 }
            stack.addArrangedSubview(row("Stick as D-Pad", stick))
            let pads = GCController.controllers().compactMap { $0.vendorName }
            let status = pads.isEmpty ? "No controller connected."
                : "Connected: \(pads.joined(separator: ", "))."
            stack.addArrangedSubview(hint("MFi, Xbox and DualSense controllers connect automatically and "
                + "use the standard mapping. Stick as D-Pad lets the left analog stick steer the "
                + "directional cross. \(status)"))

            stack.addArrangedSubview(header("In-Game Guide"))
            stack.addArrangedSubview(hint("Press L3 + R3 (click both thumbsticks) — or Tab on the "
                + "keyboard — to open the guide. The game pauses so you can move along the toolbar, "
                + "save/load, and change the background sound with the controller: D-pad moves, A / "
                + "Return selects, Left / Right adjusts, B / Esc goes back. (macOS reserves the "
                + "controller's Home button, so it can't be used to open the guide.)"))

        case .emulation:
            stack.addArrangedSubview(header("Gameplay"))
            let rewind = onOff(Settings.shared.rewindEnabled) { Settings.shared.rewindEnabled = $0 }
            stack.addArrangedSubview(row("Rewind", rewind))
            let resume = onOff(Settings.shared.autoResume) { Settings.shared.autoResume = $0 }
            stack.addArrangedSubview(row("Auto-Resume", resume))
            stack.addArrangedSubview(hint("Rewind lets you hold R in-game to scrub back a few seconds. "
                + "Auto-Resume reopens a game exactly where you left off."))

        case .achievements:
            stack.addArrangedSubview(header("RetroAchievements"))
            raUser.stringValue = RACredentials.stored?.username ?? ""
            raKey.stringValue = RACredentials.stored?.apiKey ?? ""
            stack.addArrangedSubview(fieldRow("Username", raUser))
            stack.addArrangedSubview(fieldRow("Web API Key", raKey))
            weak var saveButton: PixelButton?
            let save = PixelButton(title: "Save Login") { [weak self] in
                self?.saveCredentials(button: saveButton)
            }
            saveButton = save
            stack.addArrangedSubview(save)
            stack.addArrangedSubview(hint("Sign in to show each game's achievements and your progress. "
                + "Your Web API key is on your RetroAchievements account settings page."))
            stack.addArrangedSubview(PixelButton(title: "Open RetroAchievements.org") {
                if let url = URL(string: "https://retroachievements.org/settings") {
                    NSWorkspace.shared.open(url)
                }
            })

        case .storage:
            stack.addArrangedSubview(header("Files"))
            stack.addArrangedSubview(PixelButton(title: "Reveal ROMs Folder") {
                Self.reveal(AppPaths.romsDir)
            })
            stack.addArrangedSubview(PixelButton(title: "Reveal Saves Folder") {
                Self.reveal(AppPaths.appSupport.appendingPathComponent("saves", isDirectory: true))
            })
            stack.addArrangedSubview(PixelButton(title: "Reveal Screenshots Folder") {
                Self.reveal(AppPaths.screenshotsDir)
            })
            stack.addArrangedSubview(hint("This is the app's own ROMs folder. Add a game and its ROM is "
                + "copied here, or drop .gba files straight in — they show up in your library "
                + "automatically. Battery saves, save states, and screenshots live alongside it."))

            stack.addArrangedSubview(header("Cache"))
            weak var resetButton: PixelButton?
            let reset = PixelButton(title: "Reset Image Cache") { [weak self] in
                self?.confirmResetImageCache(button: resetButton)
            }
            resetButton = reset
            stack.addArrangedSubview(reset)
            stack.addArrangedSubview(hint("Deletes downloaded box art and screenshots so they re-download "
                + "fresh — handy if a game picked up the wrong cover. Your games, saves, captured "
                + "screenshots, and any covers you cropped yourself are kept."))

        case .about:
            stack.addArrangedSubview(header(AppInfo.name))
            stack.addArrangedSubview(hint("A macOS Game Boy Advance emulator — a cartridge shelf, faithful "
                + "emulation, and your saves kept safe."))

            // Updates — checks GitHub Releases and links the newer DMG if there is one.
            stack.addArrangedSubview(header("Updates"))
            let version = UpdateChecker.currentVersion ?? "dev build"
            stack.addArrangedSubview(hint("You’re on version \(version)."))
            let updateStatus = NSTextField(wrappingLabelWithString: "")
            updateStatus.attributedStringValue = DS.Text.plain(" ", size: 12, color: DS.Color.textTertiary)
            updateStatus.isSelectable = false
            updateStatus.preferredMaxLayoutWidth = 380
            let downloadButton = PixelButton(title: "Download update") { [weak self] in
                if let url = self?.pendingUpdateURL { NSWorkspace.shared.open(url) }
            }
            downloadButton.isHidden = true
            let checkButton = PixelButton(title: "Check for Updates") { [weak self, weak updateStatus, weak downloadButton] in
                self?.checkForUpdates(current: version, status: updateStatus, download: downloadButton)
            }
            stack.addArrangedSubview(checkButton)
            stack.addArrangedSubview(updateStatus)
            stack.addArrangedSubview(downloadButton)

            // Attribution for the third-party work the app is built on (legally required, and deserved).
            stack.addArrangedSubview(header("Built On"))
            stack.addArrangedSubview(hint("This app stands on the work of others, with thanks:"))
            stack.addArrangedSubview(creditRow("mGBA",
                "The Game Boy Advance emulation core. © endrift, MPL-2.0.",
                link: "https://mgba.io"))
            stack.addArrangedSubview(creditRow("Libretro Database",
                "Game titles, developers, and box-art matching. CC BY-SA 4.0.",
                link: "https://github.com/libretro/libretro-database"))
            stack.addArrangedSubview(creditRow("Departure Mono",
                "The pixel typeface used throughout. SIL Open Font License 1.1.",
                link: "https://departuremono.com"))
            stack.addArrangedSubview(hint("The full license text for each is bundled with the app."))

            // Personal acknowledgments.
            stack.addArrangedSubview(header("Thanks"))
            stack.addArrangedSubview(hint("Thanks to all my friends for their help and support — and "
                + "especially Rayane, who helped me with the app."))
            let signature = NSTextField(labelWithAttributedString:
                DS.Text.plain("— buildtoberemembered", size: 13, color: DS.Color.textSecondary))
            stack.addArrangedSubview(signature)
        }

        return stack
    }

    /// One dependency credit for the About tab: its name, a one-line description, and a button that
    /// opens its homepage. The full license ships bundled; this is the visible attribution.
    private func creditRow(_ name: String, _ desc: String, link: String) -> NSView {
        let nameField = NSTextField(labelWithAttributedString:
            DS.Text.label(name, size: 13, color: DS.Color.textPrimary))
        let visit = PixelButton(title: "Visit \(name)") {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }
        let col = NSStackView(views: [nameField, hint(desc), visit])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = DS.Space.xs
        return col
    }

    // MARK: - Row / element builders

    /// A labeled row: uppercase pixel label on the left, control on the right.
    private func row(_ label: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithAttributedString: DS.Text.label(label))
        l.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let r = NSStackView(views: [l, control])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = DS.Space.md
        return r
    }

    /// A labeled slider row with a live percentage readout on the right — the shared shape of the
    /// Game and Background volume controls.
    private func volumeRow(_ label: String, value: Double, _ apply: @escaping (Double) -> Void) -> NSStackView {
        let readout = NSTextField(labelWithAttributedString: DS.Text.value("\(Int(value * 100))%"))
        readout.widthAnchor.constraint(equalToConstant: 46).isActive = true
        readout.setContentCompressionResistancePriority(.required, for: .horizontal)
        let slider = PixelSlider(value: value)
        slider.onChange = {
            apply($0)
            readout.attributedStringValue = DS.Text.value("\(Int($0 * 100))%")
        }
        let r = row(label, slider)
        r.addArrangedSubview(readout)
        return r
    }

    /// A vertically-stacked labeled text field (used for the wider RA credential fields).
    private func fieldRow(_ label: String, _ field: NSTextField) -> NSStackView {
        let l = NSTextField(labelWithAttributedString: DS.Text.label(label))
        let r = NSStackView(views: [l, field])
        r.orientation = .vertical
        r.alignment = .leading
        r.spacing = DS.Space.xs
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return r
    }

    private func header(_ text: String) -> NSView {
        NSTextField(labelWithAttributedString: DS.Text.label(text, size: 15, color: DS.Color.textPrimary))
    }

    private func hint(_ text: String) -> NSView {
        let f = NSTextField(wrappingLabelWithString: "")
        f.attributedStringValue = DS.Text.plain(text, size: 12, color: DS.Color.textTertiary)
        f.isSelectable = false
        f.preferredMaxLayoutWidth = 380
        f.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        return f
    }

    /// A two-state (Off / On) pixel segmented control mapped to a Bool.
    private func onOff(_ on: Bool, _ apply: @escaping (Bool) -> Void) -> PixelSegmented {
        let seg = PixelSegmented(titles: ["Off", "On"], selected: on ? 1 : 0)
        seg.onChange = { apply($0 == 1) }
        return seg
    }

    private static func makeField(placeholder: String) -> NSTextField {
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

    // MARK: - Actions

    /// Check GitHub Releases for a newer version and reflect the result in the About tab.
    private func checkForUpdates(current: String, status: NSTextField?, download: NSView?) {
        status?.attributedStringValue = DS.Text.plain("Checking…", size: 12, color: DS.Color.textSecondary)
        download?.isHidden = true
        Task { @MainActor in
            switch await UpdateChecker.check(current: current) {
            case .upToDate:
                status?.attributedStringValue = DS.Text.plain("You’re up to date.", size: 12, color: DS.Color.textSecondary)
            case .available(let version, let url):
                self.pendingUpdateURL = url
                status?.attributedStringValue = DS.Text.plain("Update available: \(version).", size: 12, color: .systemGreen)
                download?.isHidden = false
            case .noReleases:
                status?.attributedStringValue = DS.Text.plain("No releases published yet.", size: 12, color: DS.Color.textTertiary)
            case .failed(let message):
                status?.attributedStringValue = DS.Text.plain(message, size: 12, color: DS.Color.textTertiary)
            }
        }
    }

    private func saveCredentials(button: PixelButton? = nil) {
        let username = raUser.stringValue.trimmingCharacters(in: .whitespaces)
        let apiKey = raKey.stringValue.trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty, !apiKey.isEmpty else {
            button?.flash("Enter username & key")
            return
        }
        RACredentials.store(username: username, apiKey: apiKey)
        onCredentialsSaved?()   // let the library re-fetch progress for the current selection right away
        button?.flash("Saved!")
    }

    private func confirmResetImageCache(button: PixelButton?) {
        let alert = NSAlert()
        alert.messageText = "Reset image cache?"
        alert.informativeText = "Deletes downloaded box art and screenshots so they re-download fresh. "
            + "Your games, saves, captured screenshots, and covers you cropped yourself are not affected."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let onResetImageCache { onResetImageCache() } else { ImageCache.clearDownloaded() }
        button?.flash("Cleared!")
    }

    private static func reveal(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

/// A top-down coordinate view, used as the scroll view's document so panes fill from the top.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

// MARK: - Sidebar item

/// One tab in the left rail: an uppercase pixel label that fills with a raised surface when selected.
private final class SidebarItem: NSView {
    private let onClick: () -> Void
    private let label = NSTextField(labelWithString: "")
    private let title: String
    private var isSelected = false
    private var tracking: NSTrackingArea?
    private var hovered = false

    init(title: String, onClick: @escaping () -> Void) {
        self.title = title
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.control
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.sm),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setSelected(_ on: Bool) { isSelected = on; refresh() }

    private func refresh() {
        let color = isSelected ? DS.Color.textPrimary : (hovered ? DS.Color.textPrimary : DS.Color.textSecondary)
        label.attributedStringValue = DS.Text.label(title, size: 14, color: color)
        layer?.backgroundColor = (isSelected ? DS.Color.surfaceRaised : NSColor.clear).cgColor
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
    override func mouseDown(with event: NSEvent) { onClick() }
}

// MARK: - Pixel segmented control

/// A pill of segments in the pixel face: hairline border, the selected segment filled white with
/// black text (matching `DS.drawChip(filled:)`). Used for both multi-choice (Sharp/Smooth) and
/// on/off settings. Shared with the per-game settings sheet.
final class PixelSegmented: NSView {
    var onChange: ((Int) -> Void)?
    private let titles: [String]
    private var selectedIndex: Int
    private let segW: CGFloat
    private let h: CGFloat = 30

    init(titles: [String], selected: Int) {
        self.titles = titles
        self.selectedIndex = selected
        // Equal-width segments sized to the widest label.
        let widest = titles.map { DS.Text.label($0, size: 13).size().width }.max() ?? 40
        self.segW = (widest + DS.Space.md).rounded()
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segW * CGFloat(titles.count), height: h)
    }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                 xRadius: DS.Radius.control, yRadius: DS.Radius.control)
        DS.Color.hairlineStrong.setStroke(); outer.lineWidth = 1.5; outer.stroke()

        for (i, title) in titles.enumerated() {
            let rect = CGRect(x: segW * CGFloat(i), y: 0, width: segW, height: bounds.height)
            if i == selectedIndex {
                let fill = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3),
                                        xRadius: DS.Radius.chip, yRadius: DS.Radius.chip)
                DS.Color.tileSelected.setFill(); fill.fill()
            } else if i > 0 {
                let sep = NSBezierPath()
                sep.move(to: CGPoint(x: rect.minX, y: 5))
                sep.line(to: CGPoint(x: rect.minX, y: bounds.height - 5))
                DS.Color.hairline.setStroke(); sep.lineWidth = 1; sep.stroke()
            }
            let color = i == selectedIndex ? DS.Color.background : DS.Color.textSecondary
            let str = DS.Text.label(title, size: 13, color: color)
            let size = str.size()
            str.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let i = max(0, min(titles.count - 1, Int(x / segW)))
        guard i != selectedIndex else { return }
        selectedIndex = i
        needsDisplay = true
        onChange?(i)
    }
}

// MARK: - Pixel slider

/// A minimal 0…1 slider drawn in the app's language: a hairline track, a white filled portion, and a
/// small white knob. Click or drag to set.
private final class PixelSlider: NSView {
    var onChange: ((Double) -> Void)?
    private var value: Double
    private let inset: CGFloat = 8
    private let w: CGFloat = 160

    init(value: Double) {
        self.value = value
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: w, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        let x0 = inset, x1 = bounds.width - inset
        let track = CGRect(x: x0, y: midY - 2, width: x1 - x0, height: 4)
        DS.Color.surfaceRaised.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        let knobX = x0 + (x1 - x0) * CGFloat(value)
        let filled = CGRect(x: x0, y: midY - 2, width: knobX - x0, height: 4)
        DS.Color.hairlineStrong.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()

        let knob = CGRect(x: knobX - 6, y: midY - 6, width: 12, height: 12)
        DS.Color.tileSelected.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { setFromEvent(event) }
    override func mouseDragged(with event: NSEvent) { setFromEvent(event) }

    private func setFromEvent(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let v = max(0, min(1, Double((x - inset) / (bounds.width - inset * 2))))
        guard v != value else { return }
        value = v
        needsDisplay = true
        onChange?(v)
    }
}

// MARK: - Pixel button

/// A bordered pixel-chip button that fills on hover — the app's flat, monochrome push button.
private final class PixelButton: NSView {
    private let onClick: () -> Void
    private var title: String
    private var hovered = false
    private var tracking: NSTrackingArea?
    private let h: CGFloat = 32

    init(title: String, onClick: @escaping () -> Void) {
        self.title = title
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: DS.Text.label(title, size: 13).size().width + DS.Space.lg, height: h)
    }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                               xRadius: DS.Radius.control, yRadius: DS.Radius.control)
        if hovered { DS.Color.tileSelected.setFill(); box.fill() }
        DS.Color.hairlineStrong.setStroke(); box.lineWidth = 1.5; box.stroke()
        let str = DS.Text.label(title, size: 13, color: hovered ? DS.Color.background : DS.Color.textPrimary)
        let size = str.size()
        str.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick() }

    /// Briefly swap the label (e.g. to "Saved!") to confirm an action, then restore the original.
    func flash(_ text: String, for seconds: TimeInterval = 1.4) {
        let original = title
        title = text
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.title = original
            self?.needsDisplay = true
        }
    }
}

// MARK: - Key-binding field

/// A bordered chip showing the key bound to one input. Click it to capture: it highlights and waits
/// for the next key press, then reports it via ``onBind`` (Esc cancels).
private final class KeyBindField: NSView {
    var onBind: ((UInt16) -> Void)?
    private var code: UInt16
    private var listening = false
    private let h: CGFloat = 30

    init(code: UInt16) {
        self.code = code
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Update the displayed key (after a bind or a reset-to-defaults).
    func setCode(_ code: UInt16) { self.code = code; listening = false; needsDisplay = true }

    override var intrinsicContentSize: NSSize { NSSize(width: 112, height: h) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                               xRadius: DS.Radius.control, yRadius: DS.Radius.control)
        if listening { DS.Color.tileSelected.setFill(); box.fill() }
        DS.Color.hairlineStrong.setStroke(); box.lineWidth = 1.5; box.stroke()

        let text = listening ? "Press a key…" : Settings.keyName(for: code)
        let color = listening ? DS.Color.background : DS.Color.textPrimary
        let str = DS.Text.value(text, size: 13, color: color)
        let size = str.size()
        str.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {
        listening = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard listening else { super.keyDown(with: event); return }
        if event.keyCode == 53 { listening = false; needsDisplay = true; return }   // Esc cancels
        code = event.keyCode
        listening = false
        needsDisplay = true
        onBind?(code)
    }

    override func resignFirstResponder() -> Bool { listening = false; needsDisplay = true; return true }
}
