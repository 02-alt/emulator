import AppKit

/// A subtle, console-style "trophy unlocked" pop shown inside the app window: a small dark capsule
/// that eases down from the top, holds briefly, then fades away, paired with a gentle synthesized
/// chime (see ``SoundFX/playTrophy()``). Minimalist on purpose — a soft-gold trophy glyph, the
/// achievement name, and its points, in the pixel face. Never intercepts the mouse.
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
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.92).cgColor
        layer?.cornerRadius = 12
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        build(title: title, points: points)
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func build(title: String, points: Int) {
        let icon = NSImageView(image: NSImage(systemSymbolName: "trophy.fill", accessibilityDescription: "Trophy") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = NSColor(calibratedRed: 0.97, green: 0.82, blue: 0.38, alpha: 1)   // soft gold
        icon.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithAttributedString:
            DS.Text.label("Trophy Unlocked", size: 9, color: DS.Color.textTertiary))
        let name = NSTextField(labelWithAttributedString:
            DS.Text.plain(points > 0 ? "\(title) · \(points) pts" : title, size: 13, color: DS.Color.textPrimary))
        let textColumn = NSStackView(views: [caption, name])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 3

        let row = NSStackView(views: [icon, textColumn])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Space.md - 4                                  // 12pt icon → text gap
        row.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 22)   // roomy HIG margins
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
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
