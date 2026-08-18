import SwiftUI
import PhotosUI
import LibraryKit

/// Per-game settings, edited from the library and applied next launch. Each option can defer to the
/// app-wide default (Settings) or override it for this game. Persists onto the game's override
/// fields (which LibraryKit already carries) via `LibraryModel`.
struct GameSettingsView: View {
    let game: Game

    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    // -1 == inherit the global default; 0/1/2 == DisplayFilter raw value.
    @State private var filterRaw: Int
    private enum Swap: Hashable { case standard, on, off }
    @State private var swap: Swap
    // -1 == inherit; otherwise a speed multiplier ×100 (e.g. 100 == 1×).
    @State private var speedPct: Int
    @State private var pickedPhoto: PhotosPickerItem?

    init(game: Game) {
        self.game = game
        _filterRaw = State(initialValue: game.overrideFilter ?? -1)
        switch game.overrideSwapAB {
        case true?: _swap = State(initialValue: .on)
        case false?: _swap = State(initialValue: .off)
        default: _swap = State(initialValue: .standard)
        }
        _speedPct = State(initialValue: game.overrideSpeed.map { Int(($0 * 100).rounded()) } ?? -1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    Picker("Filter", selection: $filterRaw) {
                        Text("Default (\(AppSettings.defaultFilter.title))").tag(-1)
                        ForEach(DisplayFilter.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Section("Controls") {
                    Picker("A / B Buttons", selection: $swap) {
                        Text("Default (\(AppSettings.defaultSwapAB ? "Swapped" : "Normal"))").tag(Swap.standard)
                        Text("Normal").tag(Swap.off)
                        Text("Swapped").tag(Swap.on)
                    }
                }
                Section("Speed") {
                    Picker("Default Speed", selection: $speedPct) {
                        Text("Default (1×)").tag(-1)
                        Text("0.5×").tag(50)
                        Text("1×").tag(100)
                        Text("1.5×").tag(150)
                        Text("2×").tag(200)
                    }
                }
                Section("Cover") {
                    HStack {
                        coverThumbnail
                        PhotosPicker(selection: $pickedPhoto, matching: .images) {
                            Label("Choose from Photos", systemImage: "photo")
                        }
                    }
                }
            }
            .navigationTitle(game.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { save(); dismiss() } }
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        library.setCover(fromImageData: data, for: game)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var coverThumbnail: some View {
        if let url = library.covers[game.romHash], let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(.gray.opacity(0.3))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private func save() {
        var updated = game
        updated.overrideFilter = filterRaw < 0 ? nil : filterRaw
        switch swap {
        case .standard: updated.overrideSwapAB = nil
        case .on: updated.overrideSwapAB = true
        case .off: updated.overrideSwapAB = false
        }
        updated.overrideSpeed = speedPct < 0 ? nil : Double(speedPct) / 100.0
        library.update(updated)
    }
}
