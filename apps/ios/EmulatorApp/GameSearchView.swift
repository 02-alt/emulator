import SwiftUI
import UIKit
import LibraryKit

/// A searchable view of the library's games. Picking one dismisses and brings that cart into focus
/// in the carousel (from where a tap launches it). A toolbar toggle switches between a fast text
/// **list** (best for hunting by name) and a **cartridge** grid (on-brand browsing that fills the
/// width in landscape). The choice persists so the view opens the way you last left it.
struct GameSearchView: View {
    let games: [Game]
    let covers: [String: URL]
    let onSelect: (Game) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @AppStorage("search.layout") private var layout = Layout.list

    private enum Layout: String { case list, carts }

    private var results: [Game] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return games }
        return games.filter { $0.displayTitle.range(of: q, options: .caseInsensitive) != nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch layout {
                case .list:  listView
                case .carts: cartsView
                }
            }
            .overlay {
                if results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Games")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            layout = layout == .list ? .carts : .list
                        }
                    } label: {
                        // A toggle shows the mode it switches *to*, not the current one: grid → list icon.
                        Image(systemName: layout == .carts ? "list.bullet" : "square.grid.2x2.fill")
                    }
                    .accessibilityLabel(layout == .carts ? "Show as list" : "Show as cartridges")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - List

    private var listView: some View {
        List(results) { game in
            Button {
                onSelect(game)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    thumbnail(for: game)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.displayTitle).foregroundStyle(.primary)
                        Text(game.system.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func thumbnail(for game: Game) -> some View {
        if let url = covers[game.romHash], let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4))
                .frame(width: 40, height: 40)
                .overlay(Text(game.system.shortName).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary))
        }
    }

    // MARK: - Cartridges

    private var cartsView: some View {
        // Adaptive columns fill the width in both orientations (more carts per row in landscape).
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 20)]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(results) { game in
                    Button {
                        onSelect(game)
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            CartridgeView(
                                system: game.system,
                                cover: CoverStore.image(at: covers[game.romHash]),
                                title: game.displayTitle,
                                systemTag: game.system.shortName,
                                crop: game.coverCrop)
                                .aspectRatio(CartridgeView.cartAspect(for: game.system), contentMode: .fit)
                            Text(game.displayTitle)
                                .font(.caption).lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }
}
