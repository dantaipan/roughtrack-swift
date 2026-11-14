import AppKit
import RoughTrackCore
import SwiftUI

/// Choosing a capture or cabinet IR from TONE3000 for one track, as TONE3000's
/// integration guidelines describe:
///
///   splash (signed out) -> sign-in (a code to enter at tone3000.com)
///   -> library: Favorites / Created / Downloaded / Trending / Latest,
///      and Browse TONE3000 (its own picker, in the web browser)
///   -> a tone: its models, and Load
///
/// Loading downloads the model and puts it in the track's amp or cab, as a file
/// from disk would be.
struct Tone3000Browser: View {
    let track: Int
    let target: rt.Tone3000Target
    /// Opens on this tone (the one the track's file came from), to switch models.
    var startingTone: Int?

    @EnvironmentObject private var model: StudioModel
    @ObservedObject var tone3000: Tone3000Model
    @Environment(\.dismiss) private var dismiss

    @State private var listShown = "favorited"
    @State private var toneShown: Int?

    private var wantsIr: Bool { target == .cabinet }

    var body: some View {
        VStack(spacing: 0) {
            if !tone3000.account.signedIn {
                if tone3000.account.signingIn || !tone3000.account.userCode.isEmpty {
                    signIn
                } else {
                    splash
                }
            } else {
                header
                Rectangle().fill(Color(Theme.separator)).frame(height: 1)
                if let toneShown {
                    ToneDetail(toneId: toneShown, wantsIr: wantsIr, tone3000: tone3000,
                               back: { self.toneShown = nil }, load: load)
                } else {
                    library
                }
            }
        }
        .frame(width: 640, height: 560)
        .background(Color(Theme.window))
        .onAppear {
            tone3000.refresh()
            toneShown = startingTone
        }
        .onChange(of: tone3000.browsedTone) {
            if let tone = tone3000.browsedTone {
                toneShown = tone
                tone3000.browsedTone = nil
            }
        }
        .onChange(of: tone3000.account.signedIn) {
            if tone3000.account.signedIn { tone3000.loadList(listShown, for: target) }
        }
    }

    private func load(_ tone: Tone3000Model.Tone, _ choice: Tone3000Model.Model) {
        tone3000.use(track: track, target: target, toneId: tone.id, modelId: choice.id)
        dismiss()
    }

    // MARK: Signed out

    private var splash: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("tone3000-logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 320)
            Text("NAM captures and IRs of real gear, made by a community of musicians.")
                .font(.system(size: 13))
                .foregroundStyle(Color(Theme.secondaryText))
                .multilineTextAlignment(.center)
            if !tone3000.account.error.isEmpty {
                Text(tone3000.account.error)
                    .font(.callout)
                    .foregroundStyle(Color(Theme.monitor))
            }
            Button("Sign In to TONE3000") { tone3000.signIn() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("Signing in also signs in any other app on this Mac that uses TONE3000 Shared.")
                .font(.system(size: 11))
                .foregroundStyle(Color(Theme.secondaryText))
            Spacer()
            footer
        }
        .padding(24)
    }

    private var signIn: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("tone3000-logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 220)

            if tone3000.account.userCode.isEmpty {
                ProgressView().controlSize(.small)
                Text("Asking TONE3000 for a code…")
                    .foregroundStyle(Color(Theme.secondaryText))
            } else {
                Text("Enter this code at tone3000.com:")
                    .foregroundStyle(Color(Theme.secondaryText))
                Text(tone3000.account.userCode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Open tone3000.com") {
                        if let url = URL(string: tone3000.account.verificationUrl) { NSWorkspace.shared.open(url) }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tone3000.account.userCode, forType: .string)
                    }
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to confirm…")
                        .foregroundStyle(Color(Theme.secondaryText))
                }
            }

            Button("Cancel") { tone3000.cancelSignIn() }
            Spacer()
            footer
        }
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Text("Powered by TONE3000")
                .font(.system(size: 11))
                .foregroundStyle(Color(Theme.secondaryText))
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Signed in

    private var header: some View {
        HStack(spacing: 10) {
            Image("tone3000-logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 18)
                .help("Powered by TONE3000")

            Spacer()

            if tone3000.account.browsing {
                ProgressView().controlSize(.small)
                Text("Choose a tone in your browser…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(Theme.secondaryText))
            } else {
                Button("Browse TONE3000") { tone3000.browse(for: target) }
                    .help("Search the whole catalog in your web browser")
            }

            Menu {
                Button("Sign Out") { tone3000.signOut() }
            } label: {
                HStack(spacing: 6) {
                    AsyncImage(url: URL(string: tone3000.account.avatarUrl)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.crop.circle").foregroundStyle(Color(Theme.secondaryText))
                    }
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
                    Text(tone3000.account.userName)
                        .font(.system(size: 12))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(Theme.ruler))
    }

    private var library: some View {
        VStack(spacing: 0) {
            Picker("", selection: $listShown) {
                ForEach(Tone3000Model.lists, id: \.id) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            .onChange(of: listShown) { tone3000.loadList(listShown, for: target) }
            .onAppear { tone3000.loadList(listShown, for: target) }

            let list = tone3000.list(listShown, for: target)
            // TONE3000's lists don't filter by format, so only what this slot loads is shown.
            let tones = list.tones.filter { $0.isIr == wantsIr }
            let isShortList = listShown == "trending" || listShown == "latest"

            if !list.error.isEmpty {
                Text(list.error)
                    .foregroundStyle(Color(Theme.monitor))
                    .padding()
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(tones) { tone in
                        ToneRow(tone: tone)
                            .contentShape(Rectangle())
                            .onTapGesture { toneShown = tone.id }
                    }

                    if list.loading {
                        ProgressView().controlSize(.small).padding()
                    } else {
                        if tones.isEmpty && list.error.isEmpty {
                            Text(emptyMessage(isShortList: isShortList))
                                .foregroundStyle(Color(Theme.secondaryText))
                                .multilineTextAlignment(.center)
                                .padding(.top, 30)
                                .padding(.bottom, 8)
                        }

                        if isShortList {
                            // Trending and Latest are one short page; TONE3000's own picker
                            // has the rest, filtered to what this slot loads.
                            Button("Discover More on TONE3000") { tone3000.browse(for: target) }
                                .padding()
                        } else if list.hasMore {
                            Button("Load More") { tone3000.loadList(listShown, for: target, page: list.page + 1) }
                                .padding()
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private var whatLoads: String { wantsIr ? "cabinet IRs" : "NAM captures" }

    private func emptyMessage(isShortList: Bool) -> String {
        if isShortList {
            return "No \(whatLoads) here right now."
        }
        let name = Tone3000Model.lists.first { $0.id == listShown }?.title ?? listShown
        return "No \(whatLoads) in your \(name) yet. Find some with Browse TONE3000."
    }
}

/// A tone in a list: its picture, title, creator and gear.
private struct ToneRow: View {
    let tone: Tone3000Model.Tone

    var body: some View {
        HStack(spacing: 10) {
            ToneImage(url: tone.imageUrl, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(tone.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text([tone.creator, tone.gear].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(Theme.secondaryText))
                    .lineLimit(1)
            }
            Spacer()
            Text(tone.format)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(Theme.secondaryText))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.24)))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(Theme.header)))
    }
}

private struct ToneImage: View {
    let url: String
    let size: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: url)) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Image(systemName: "waveform")
                .foregroundStyle(Color(Theme.secondaryText))
        }
        .frame(width: size, height: size)
        .background(Color(white: 0.18))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// One tone: what it is, and the models in it, each of which can be loaded.
private struct ToneDetail: View {
    let toneId: Int
    let wantsIr: Bool
    @ObservedObject var tone3000: Tone3000Model
    let back: () -> Void
    let load: (Tone3000Model.Tone, Tone3000Model.Model) -> Void

    var body: some View {
        let detail = tone3000.detail(toneId)

        VStack(alignment: .leading, spacing: 12) {
            Button {
                back()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            if let tone = detail.tone {
                HStack(alignment: .top, spacing: 14) {
                    ToneImage(url: tone.imageUrl, size: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tone.title)
                            .font(.title3.weight(.semibold))
                        Text("by \(tone.creator)")
                            .foregroundStyle(Color(Theme.secondaryText))
                        Text([tone.gear, tone.format, tone.license].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(Color(Theme.secondaryText))
                        if let url = URL(string: tone.url), !tone.url.isEmpty {
                            Link("View on TONE3000", destination: url)
                                .font(.system(size: 11))
                        }
                    }
                }

                if !tone.description.isEmpty {
                    ScrollView {
                        Text(tone.description)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }

                if tone.isIr != wantsIr {
                    Text(wantsIr ? "This tone has captures, not cabinet IRs." : "This tone has cabinet IRs, not captures.")
                        .font(.callout)
                        .foregroundStyle(Color(Theme.monitor))
                }

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(detail.models) { choice in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.name)
                                        .font(.system(size: 12, weight: .medium))
                                    Text([choice.architecture.isEmpty ? "" : "Architecture \(choice.architecture)", choice.size]
                                            .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color(Theme.secondaryText))
                                }
                                Spacer()
                                Button("Load") { load(tone, choice) }
                                    .disabled(tone.isIr != wantsIr)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color(Theme.header)))
                        }
                    }
                }
            }

            if detail.loading {
                ProgressView().controlSize(.small)
            }

            if !detail.error.isEmpty {
                Text(detail.error)
                    .foregroundStyle(Color(Theme.monitor))
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .onAppear { tone3000.loadTone(toneId) }
        .onChange(of: toneId) { tone3000.loadTone(toneId) }
    }
}
