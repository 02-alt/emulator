import SwiftUI
import UIKit

/// One numbered save-state slot on disk: its state file, a thumbnail of the moment it was captured,
/// and cached metadata read at build time. Slots live beside the battery/quicksave in the game's save
/// folder as `slot<n>.state` (+ `slot<n>.png`).
struct SaveSlot: Identifiable {
    let index: Int
    let stateURL: URL
    let thumbURL: URL
    let exists: Bool
    let modified: Date?
    let thumbnail: UIImage?
    var id: Int { index }

    static let count = 6

    /// Build the fixed set of slots for a game's save directory, reading each slot's current state.
    static func all(in directory: URL?) -> [SaveSlot] {
        guard let directory else { return [] }
        let fm = FileManager.default
        return (1...count).map { n in
            let state = directory.appendingPathComponent("slot\(n).state")
            let thumb = directory.appendingPathComponent("slot\(n).png")
            let exists = fm.fileExists(atPath: state.path)
            let date = (try? fm.attributesOfItem(atPath: state.path))?[.modificationDate] as? Date
            return SaveSlot(index: n, stateURL: state, thumbURL: thumb,
                            exists: exists, modified: date,
                            thumbnail: UIImage(contentsOfFile: thumb.path))
        }
    }
}

/// The iOS **Save States** panel — six numbered slots shown as a horizontal *timeline* of framed
/// moments. A Save/Load mode switch at the top decides what a tap does: in **Save** you tap a frame to
/// write the live moment into it, in **Load** you tap a saved frame to jump back to it. The explicit
/// mode means a stray tap can't overwrite or clobber your progress. The port of the macOS Save States
/// panel; presented as a sheet from the play screen, which pauses emulation while it's open so the
/// captured frame + state are the moment you opened it.
struct SaveStatesSheet: View {
    let directory: URL?
    /// Save the live state into a slot; completion reports success so the strip can refresh.
    let onSave: (SaveSlot, @escaping (Bool) -> Void) -> Void
    /// Load a slot into the live game; completion reports success so the sheet can close.
    let onLoad: (SaveSlot, @escaping (Bool) -> Void) -> Void

    /// Whether a tap on a frame saves into it or loads it.
    private enum Mode: String, CaseIterable {
        case save = "Save"
        case load = "Load"
        var icon: String { self == .save ? "square.and.arrow.down" : "arrow.down.circle" }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var slots: [SaveSlot] = []
    @State private var mode: Mode = .save
    @Namespace private var modeNS

    /// Slot index of the most recently written save — accented on the strip as "where you last were".
    private var latestIndex: Int? {
        slots.filter { $0.exists }
            .max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }?
            .index
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modeSwitcher
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(slots) { slot in card(slot) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DS.background)
            .safeAreaInset(edge: .bottom) {
                Text(mode == .save
                    ? "Tap a frame to save this moment into it · long-press to delete"
                    : "Tap a saved moment to jump back to it · long-press to delete")
                    .font(DS.mono(10))
                    .foregroundStyle(DS.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).tint(.white)
                }
            }
        }
        .presentationDetents([.height(300), .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear(perform: refresh)
    }

    // MARK: - Mode switcher

    /// A slate-blue segmented pill — Save on the left, Load on the right — with a sliding highlight.
    private var modeSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { mode = m }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: m.icon).font(.system(size: 12, weight: .semibold))
                        Text(m.rawValue).font(DS.mono(13, .semibold))
                    }
                    .foregroundStyle(mode == m ? .white : DS.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if mode == m {
                            Capsule().fill(DS.accent)
                                .matchedGeometryEffect(id: "modePill", in: modeNS)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color(white: 0.11)))
    }

    // MARK: - Card

    private let cardWidth: CGFloat = 150   // thumbnail 150×100 keeps the GBA 3:2 aspect

    @ViewBuilder
    private func card(_ slot: SaveSlot) -> some View {
        let isLatest = slot.index == latestIndex
        // In Load mode an empty slot has nothing to do — dim it and swallow the tap.
        let disabled = mode == .load && !slot.exists

        Button {
            if mode == .save {
                onSave(slot) { _ in refresh() }
            } else if slot.exists {
                onLoad(slot) { ok in if ok { dismiss() } }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail(slot, isLatest: isLatest)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SLOT \(slot.index)")
                        .font(DS.mono(11, .semibold))
                        .foregroundStyle(isLatest ? DS.accent : DS.textPrimary)
                    Text(status(slot))
                        .font(DS.mono(10))
                        .foregroundStyle(DS.textSecondary)
                }
            }
            .frame(width: cardWidth, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .contextMenu {
            if slot.exists {
                Button { onLoad(slot) { ok in if ok { dismiss() } } } label: {
                    Label("Load", systemImage: "arrow.down.circle")
                }
                Button { onSave(slot) { _ in refresh() } } label: {
                    Label("Overwrite", systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive) { delete(slot) } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else {
                Button { onSave(slot) { _ in refresh() } } label: {
                    Label("Save here", systemImage: "square.and.arrow.down")
                }
            }
        }
        .accessibilityLabel(slot.exists
            ? "Slot \(slot.index), \(status(slot)). Double-tap to load."
            : "Slot \(slot.index), empty. Double-tap to save.")
    }

    @ViewBuilder
    private func thumbnail(_ slot: SaveSlot, isLatest: Bool) -> some View {
        Group {
            if let img = slot.thumbnail {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.08))
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(DS.textTertiary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(DS.textTertiary.opacity(0.6))
                    )
            }
        }
        .frame(width: cardWidth, height: cardWidth * 2 / 3)   // 3:2, the GBA screen aspect
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isLatest ? DS.accent : .white.opacity(0.12),
                        lineWidth: isLatest ? 2 : 1)
        )
        .shadow(color: isLatest ? DS.accent.opacity(0.5) : .clear, radius: 10)
    }

    private func status(_ slot: SaveSlot) -> String {
        guard slot.exists else { return "Empty" }
        if let date = slot.modified { return date.formatted(.relative(presentation: .named)) }
        return "Saved"
    }

    private func delete(_ slot: SaveSlot) {
        try? FileManager.default.removeItem(at: slot.stateURL)
        try? FileManager.default.removeItem(at: slot.thumbURL)
        refresh()
    }

    private func refresh() { slots = SaveSlot.all(in: directory) }
}
