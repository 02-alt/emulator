import SwiftUI
import UIKit
import LibraryKit

/// A searchable list of the library's games. Picking one dismisses and brings that cart into focus
/// in the carousel (from where a tap launches it).
struct GameSearchView: View {
    let games: [Game]
    let covers: [String: URL]
    let onSelect: (Game) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Game] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return games }
        return games.filter { $0.displayTitle.range(of: q, options: .caseInsensitive) != nil }
    }

    var body: some View {
        NavigationStack {
            List(results) { game in
                Button {
                    onSelect(game)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        cover(for: game)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.displayTitle).foregroundStyle(.primary)
                            Text(game.system.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Games")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func cover(for game: Game) -> some View {
        if let url = covers[game.romHash], let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4))
                .frame(width: 40, height: 40)
                .overlay(Text(game.system.shortName).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary))
        }
    }
}
