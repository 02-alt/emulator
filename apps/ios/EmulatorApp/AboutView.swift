import SwiftUI

/// The About screen — mirrors the macOS app's About tab: the product name and a one-line pitch,
/// the build/core info, a plain-language note on privacy, attribution for the third-party work the
/// app is built on (legally required, and deserved), and a personal note of thanks.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.primary)
                    Text(appName)
                        .font(.title2.bold())
                    Text("An iOS Game Boy Advance emulator — a cartridge shelf, faithful emulation, and your saves kept safe.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Core", value: ContinuityService.coreVersion)
                LabeledContent("System", value: "Game Boy Advance")
                NavigationLink {
                    ReleaseNotesView()
                } label: {
                    Label("Release Notes", systemImage: "sparkles")
                }
            }

            Section {
                Text("No accounts, no analytics, no tracking. Your games, saves, and screenshots stay on your device, and crash reports are written locally — never uploaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Box art is fetched from the public Libretro thumbnail archive. If you turn on cross-device resume it syncs through your own private iCloud, and RetroAchievements sign-in (if you use it) talks only to retroachievements.org.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }

            // Attribution for the third-party work the app is built on (legally required, and deserved).
            Section {
                creditRow("mGBA",
                          "The Game Boy Advance emulation core. © endrift, MPL-2.0.",
                          link: "https://mgba.io")
                creditRow("Libretro Database",
                          "Game titles, developers, and box-art matching. CC BY-SA 4.0.",
                          link: "https://github.com/libretro/libretro-database")
            } header: {
                Text("Built On")
            } footer: {
                Text("This app stands on the work of others, with thanks.")
            }

            Section {
                Text("Thanks to all my friends for their help and support — and especially Rayane, who helped me with the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("— buildtoberemembered")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Thanks")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
        }
    }

    /// One dependency credit: its name, a one-line description, and a link that opens its homepage.
    /// The full license ships bundled; this is the visible attribution.
    private func creditRow(_ name: String, _ desc: String, link: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = URL(string: link) {
                Link(name, destination: url)
                    .font(.headline)
            } else {
                Text(name).font(.headline)
            }
            Text(desc)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Encore"
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
