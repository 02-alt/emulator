import AppKit
import LibraryKit

/// The PlayStation BIOS manager, presented as an **in-window overlay** (dimmed backdrop + centered
/// card) over the Settings pane — so the settings stay visible behind it rather than being hidden by
/// a separate window. Lists each region with its own Add / Replace button, plus a legal dumping-guide
/// link. Dismisses on Done, Esc, or a click on the backdrop. Mirrors `AppAlert`'s presentation.
@MainActor
final class PSXBiosPanel: NSView {
    private let dim = CALayer()
    private let card = NSView()
    private let rows = NSStackView()
    private var onClose: (() -> Void)?

    private let cardWidth: CGFloat = 420
    private var contentWidth: CGFloat { cardWidth - DS.Space.lg * 2 }

    /// Present over `window`'s content view. `onClose` fires after dismissal (Settings refreshes its
    /// summary). No-op without a window.
    static func present(in window: NSWindow?, onClose: (() -> Void)? = nil) {
        guard let host = window?.contentView else { return }
        let panel = PSXBiosPanel(onClose: onClose)
        panel.frame = host.bounds
        panel.autoresizingMask = [.width, .height]
        host.addSubview(panel)
        panel.layer?.zPosition = 1000
        panel.animateIn()
        window?.makeFirstResponder(panel)
    }

    private init(onClose: (() -> Void)?) {
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.addSublayer(dim)
        buildCard()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func layout() { super.layout(); dim.frame = bounds }

    // MARK: - Card

    private func buildCard() {
        card.wantsLayer = true
        card.layer?.backgroundColor = DS.Color.background.cgColor
        card.layer?.cornerRadius = DS.Radius.card
        card.layer?.borderColor = DS.Color.hairlineStrong.cgColor
        card.layer?.borderWidth = 1
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 30
        card.layer?.shadowOffset = CGSize(width: 0, height: -8)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DS.Space.md
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        let title = NSTextField(labelWithAttributedString:
            DS.Text.label("PlayStation BIOS", size: 20, color: DS.Color.textPrimary))
        column.addArrangedSubview(title)

        let blurb = NSTextField(wrappingLabelWithString: "")
        blurb.attributedStringValue = DS.Text.plain(
            "Add each region so every game runs on its intended BIOS — games still play on any one you "
            + "have. Use a 512 KB BIOS dumped from a console you own.", size: 12, color: DS.Color.textTertiary)
        blurb.isSelectable = false
        blurb.preferredMaxLayoutWidth = contentWidth
        blurb.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        column.addArrangedSubview(blurb)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = DS.Space.md
        rows.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(rows)
        rebuildRows()

        column.setCustomSpacing(DS.Space.lg, after: rows)
        column.addArrangedSubview(PixelButton(title: "How to Dump Your BIOS ↗") {
            PSXBiosOnboarding.openDumpingGuide()
        })

        // Done, trailing.
        let done = PixelButton(title: "Done") { [weak self] in self?.dismiss() }
        done.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(done)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: cardWidth),

            column.topAnchor.constraint(equalTo: card.topAnchor, constant: DS.Space.lg),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: DS.Space.lg),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -DS.Space.lg),

            done.topAnchor.constraint(equalTo: column.bottomAnchor, constant: DS.Space.lg),
            done.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -DS.Space.lg),
            done.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -DS.Space.lg),
        ])
    }

    private func rebuildRows() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for region in PSXRegion.allCases { rows.addArrangedSubview(regionRow(region)) }
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
            PSXBiosOnboarding.addBIOS(for: region, in: self.window) { [weak self] in self?.rebuildRows() }
        }

        let r = NSStackView(views: [name, status, spacer, button])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = DS.Space.smd
        r.distribution = .fill
        r.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return r
    }

    // MARK: - Dismissal

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // A click on the dimmed backdrop (outside the card) closes; clicks inside are handled by the
        // card's controls, or ignored.
        let p = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(p) { dismiss() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 { dismiss() }  // Esc / Return
        else { super.keyDown(with: event) }
    }

    private func animateIn() {
        alphaValue = 0
        card.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.quick
            ctx.timingFunction = Motion.timing
            animator().alphaValue = 1
        }
        let pop = Motion.springAnimation("transform",
                                         from: NSValue(caTransform3D: CATransform3DMakeScale(0.96, 0.96, 1)),
                                         to: NSValue(caTransform3D: CATransform3DIdentity),
                                         response: 0.4, dampingRatio: 0.82)
        card.layer?.add(pop, forKey: "transform")
        card.layer?.transform = CATransform3DIdentity
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.quick
            ctx.timingFunction = Motion.timing
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeFromSuperview()
                self.onClose?()
            }
        })
    }
}
