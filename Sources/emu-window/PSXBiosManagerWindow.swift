import AppKit
import LibraryKit

/// A small standalone panel that lists each PlayStation BIOS region with its own Add / Replace
/// button, plus a link to a legal dumping guide. Opened from Settings so the per-region rows don't
/// clutter the main pane. Chrome mirrors the Settings window.
@MainActor
final class PSXBiosManagerWindow: NSObject, NSWindowDelegate {
    /// Fired when the panel closes, so Settings can refresh its summary.
    var onClose: (() -> Void)?

    private let window: NSWindow
    private let stack = NSStackView()
    private let contentWidth: CGFloat = 400

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth + DS.Space.lg * 2, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "PlayStation BIOS"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = DS.Color.background
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.md
        stack.edgeInsets = NSEdgeInsets(top: DS.Space.lg, left: DS.Space.lg,
                                        bottom: DS.Space.lg, right: DS.Space.lg)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        window.contentView = host
        rebuild()
    }

    /// Show the panel centered over `host` (the Settings/library window), or screen-centered.
    func show(over host: NSWindow?) {
        window.setContentSize(NSSize(width: contentWidth + DS.Space.lg * 2, height: fittingHeight()))
        if let host {
            let hf = host.frame, wf = window.frame
            window.setFrameOrigin(NSPoint(x: hf.midX - wf.width / 2, y: hf.midY - wf.height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    // MARK: - Content

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithAttributedString:
            DS.Text.label("PlayStation BIOS", size: 15, color: DS.Color.textPrimary))
        stack.addArrangedSubview(title)

        let blurb = NSTextField(wrappingLabelWithString: "")
        blurb.attributedStringValue = DS.Text.plain(
            "Add each region so every game runs on its intended BIOS — games still play on any one you "
            + "have. Use a 512 KB BIOS dumped from a console you own.", size: 12, color: DS.Color.textTertiary)
        blurb.preferredMaxLayoutWidth = contentWidth
        blurb.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        stack.addArrangedSubview(blurb)

        for region in PSXRegion.allCases { stack.addArrangedSubview(regionRow(region)) }

        stack.addArrangedSubview(PixelButton(title: "How to Dump Your BIOS ↗") {
            PSXBiosOnboarding.openDumpingGuide()
        })
    }

    private func regionRow(_ region: PSXRegion) -> NSView {
        let installed = PSXBios.installedRegions.contains(region)

        let name = NSTextField(labelWithAttributedString: DS.Text.label("\(region.flag) \(region.displayName)"))
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let status = NSTextField(labelWithAttributedString:
            DS.Text.value(installed ? region.biosFilename : "missing"))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let button = PixelButton(title: installed ? "Replace…" : "Add…") { [weak self] in
            guard let self else { return }
            PSXBiosOnboarding.addBIOS(for: region, in: self.window) { [weak self] in self?.rebuild() }
        }

        let r = NSStackView(views: [name, status, spacer, button])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = DS.Space.smd
        r.distribution = .fill
        r.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return r
    }

    private func fittingHeight() -> CGFloat {
        stack.layoutSubtreeIfNeeded()
        return stack.fittingSize.height
    }
}
