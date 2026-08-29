import AppKit

/// A "trophy unlocked" pop shown inside the app window: a small card that eases down from the top,
/// holds briefly, then fades away, paired with a gentle synthesized chime (see ``SoundFX/playTrophy()``).
/// It wears the same chrome as the "What's New" card (``AppAlert``): a pure-black card with a bright
/// hairline border, laid out as one feature row — a soft-gold trophy glyph beside a pixel title and a
/// dim one-line detail. Decoration only; never intercepts the mouse.
@MainActor
final class TrophyPop: NSView {
    static func show(in window: NSWindow?, title: String, points: Int) {
        guard let host = window?.contentView else { return }
        host.subviews.compactMap { $0 as? TrophyPop }.forEach { $0.removeFromSuperview() }
        let pop = TrophyPop(title: title, points: points)
        host.addSubview(pop)
        pop.place(in: host)
        pop.run()
    }

    private init(title: String, points: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        // Same card chrome as the What's New card (AppAlert): pure black, bright hairline, soft shadow.
        layer?.backgroundColor = DS.Color.background.cgColor
        layer?.cornerRadius = DS.Radius.card
        layer?.borderColor = DS.Color.hairlineStrong.cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        build(title: title, points: points)
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func build(title: String, points: Int) {
        // A single AppAlert-style feature row: SF Symbol on the left, pixel title above a dim detail.
        let icon = NSImageView(image: NSImage(systemSymbolName: "trophy.fill", accessibilityDescription: "Trophy") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = NSColor(calibratedRed: 0.97, green: 0.82, blue: 0.38, alpha: 1)   // soft gold
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithAttributedString:
            DS.Text.plain(title, size: 14, color: DS.Color.textPrimary))
        let detail = NSTextField(labelWithAttributedString:
            DS.Text.plain(points > 0 ? "Trophy unlocked · \(points) pts" : "Trophy unlocked",
                          size: 12, color: DS.Color.textSecondary))
        let textColumn = NSStackView(views: [name, detail])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = DS.Space.xs

        let row = NSStackView(views: [icon, textColumn])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Space.md
        row.edgeInsets = NSEdgeInsets(top: DS.Space.md, left: DS.Space.lg, bottom: DS.Space.md, right: DS.Space.lg)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func place(in host: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: host.centerXAnchor),
            topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: DS.Space.md),
        ])
    }

    // Decoration only — never eat clicks meant for the game/shelf beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func run(duration: TimeInterval = 2.8) {
        alphaValue = 0
        let descend = CABasicAnimation(keyPath: "transform.translation.y")
        descend.fromValue = 10        // eases down into place (non-flipped: +y is up)
        descend.toValue = 0
        descend.duration = Motion.quick
        descend.timingFunction = Motion.timing
        layer?.add(descend, forKey: "in")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.quick
            ctx.timingFunction = Motion.timing
            animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.quick
                ctx.timingFunction = Motion.timing
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.removeFromSuperview() }
            })
        }
    }
}
