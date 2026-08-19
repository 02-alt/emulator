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

/// The iOS **Save States** panel — six numbered slots you can Save into and Load from, each showing a
/// thumbnail of the frame it was captured on. The port of the macOS Save States panel. Presented as a
/// sheet from the play screen; the caller pauses emulation while it's open.
struct SaveStatesSheet: View {
    let directory: URL?
    /// Save the live state into a slot; completion reports success so the row can refresh.
    let onSave: (SaveSlot, @escaping (Bool) -> Void) -> Void
    /// Load a slot into the live game; completion reports success so the sheet can close.
    let onLoad: (SaveSlot, @escaping (Bool) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var slots: [SaveSlot] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(slots) { slot in row(slot) }
                } footer: {
                    Text("Each slot holds a full snapshot. Swipe a slot to delete it.")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Save States")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func row(_ slot: SaveSlot) -> some View {
        HStack(spacing: 12) {
            thumbnail(slot)

            VStack(alignment: .leading, spacing: 2) {
                Text("SLOT \(slot.index)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(status(slot))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("SAVE") { onSave(slot) { _ in refresh() } }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)

            Button("LOAD") { onLoad(slot) { ok in if ok { dismiss() } } }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.white)
                .disabled(!slot.exists)
        }
        .swipeActions(edge: .trailing) {
            if slot.exists {
                Button(role: .destructive) { delete(slot) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ slot: SaveSlot) -> some View {
        Group {
            if let img = slot.thumbnail {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12))
                    .overlay(Image(systemName: "square.dashed")
                        .font(.system(size: 14)).foregroundStyle(.tertiary))
            }
        }
        .frame(width: 58, height: 39)   // 3:2, the GBA screen aspect
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 1))
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
