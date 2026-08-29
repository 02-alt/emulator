import SwiftUI
import UIKit
import LibraryKit

/// The long-press preview for a game — a clean, Apple TV-style card holding the game's **cartridge**
/// (with the tilt-driven holographic sheen from `HolographicCartridge`), the console name and title
/// beneath, on a dark rounded surface. Replaces the old `PressMenuBox` "Apple Intelligence" bubble so
/// there's no pink iridescent rim — just a tidy card, with the holo living on the cartridge itself.
struct GamePreviewCard: View {
    let system: GameSystem
    let cover: UIImage?
    let title: String
    let systemTag: String
    var crop: CoverCrop? = nil

    private let cartWidth: CGFloat = 240

    var body: some View {
        let cartHeight = cartWidth / CartridgeView.cartAspect(for: system)
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        VStack(alignment: .leading, spacing: 16) {
            HolographicCartridge(
                system: system,
                cover: cover,
                title: title,
                systemTag: systemTag,
                crop: crop)
                .frame(width: cartWidth, height: cartHeight)

            VStack(alignment: .leading, spacing: 3) {
                Text(system.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: cartWidth, alignment: .leading)
        }
        .padding(20)
        .background(shape.fill(Color(white: 0.11)))
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
    }
}
