import SwiftUI

/// The "What's New" panel shown once after each update (and on first launch): the latest release's
/// headline and its highlights, with a single button to dismiss. Reachable again any time from
/// About ▸ Release Notes. Marks the version as seen on appear, so it won't reappear.
struct WhatsNewView: View {
    let note: ReleaseNote
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What's New")
                            .font(.largeTitle.bold())
                        Text("Version \(note.version) · \(note.date)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 28)

                    ForEach(note.highlights) { h in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: h.symbol)
                                .font(.system(size: 24))
                                .frame(width: 34, height: 30, alignment: .center)
                                .foregroundStyle(.primary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(h.title).font(.headline)
                                Text(h.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }

            Button { dismiss() } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .background(DS.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { WhatsNew.markSeen() }
    }
}

/// The full history of release notes, newest first — reached from About ▸ Release Notes.
struct ReleaseNotesView: View {
    var body: some View {
        List {
            ForEach(ReleaseNotes.all) { note in
                Section {
                    ForEach(note.highlights) { h in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: h.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.title).font(.subheadline.weight(.medium))
                                Text(h.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Version \(note.version) · \(note.date)")
                }
            }
        }
        .navigationTitle("Release Notes")
        .navigationBarTitleDisplayMode(.inline)
    }
}
