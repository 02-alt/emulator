import AppKit

/// A transient, non-blocking notice — the app's answer to feedback that doesn't warrant a modal
/// alert (Apple: don't use alerts for minor or informational messages). A themed pill slides up from
/// the bottom of a window's content, holds briefly, then fades away. It never intercepts the mouse,
/// so it can't block whatever's beneath it (a running game, the shelf). Use ``AppAlert`` instead when
/// the user must acknowledge something or make a choice.
@MainActor
final class Toast: NSView {
    enum Style { case info, success, error }

    /// Show a toast over `window`'s content. A new toast replaces any already on screen.
    static func show(in window: NSWindow?, _ message: String, symbol: String? = nil,
                     style: Style = .info, duration: TimeInterval = 2.8) {
        guard let host = window?.contentView else { return }
        host.subviews.compactMap { $0 as? Toast }.forEach { $0.removeFromSuperview() }
        let toast = Toast(message: message, symbol: symbol ?? style.defaultSymbol, style: style)
        host.addSubview(toast)
        toast.place(in: host)
        toast.run(for: duration)
    }

    private let message: String
    private let symbol: String?
    private let style: Style

    private init(message: String, symbol: String?, style: Style) {
        self.message = message; self.symbol = symbol; self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = DS.Color.surfaceRaised.cgColor
        layer?.cornerRadius = DS.Radius.panel
        layer?.borderColor = DS.Color.hairline.cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        build()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func build() {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Space.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: DS.Space.sm, left: DS.Space.md,
                                      bottom: DS.Space.sm, right: DS.Space.md)
        addSubview(row)

        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: img)
            icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            icon.contentTintColor = style.tint
            row.addArrangedSubview(icon)
        }
        let label = NSTextField(labelWithAttributedString:
            DS.Text.plain(message, size: 13, color: DS.Color.textPrimary))
        row.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func place(in host: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: host.centerXAnchor),
            // Sit clear of the shelf's footer capsule band (which occupies the bottom ~86pt) so a "sent"
            // notice never overlaps the Play/Settings/Send buttons.
            bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -(DS.Space.xxl + DS.Space.ml)),
        ])
    }

    // Never eat mouse events — a toast is decoration over whatever the user is doing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func run(for duration: TimeInterval) {
        alphaValue = 0
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -12; rise.toValue = 0
        rise.duration = Motion.quick
        rise.timingFunction = Motion.timing
        layer?.add(rise, forKey: "rise")
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

private extension Toast.Style {
    var tint: NSColor {
        switch self {
        case .info:    return DS.Color.textSecondary
        case .success: return .systemGreen
        case .error:   return .systemRed
        }
    }
    var defaultSymbol: String? {
        switch self {
        case .info:    return nil
        case .success: return "checkmark.circle"
        case .error:   return "exclamationmark.triangle"
        }
    }
}
