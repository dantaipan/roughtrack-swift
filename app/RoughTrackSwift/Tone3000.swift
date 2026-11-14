import AppKit
import CxxStdlib
import RoughTrackCore
import SwiftUI

/// TONE3000 (tone3000.com) as the views see it: the shared sign-in, the tone lists
/// and tones asked for so far, and a tone chosen in TONE3000's own picker. The core
/// does the work in the background; this is read again whenever its revision moves.
@MainActor
final class Tone3000Model: ObservableObject {
    struct Account: Equatable {
        var available = false
        var signedIn = false
        var signingIn = false
        var browsing = false
        var userName = ""
        var avatarUrl = ""
        var userCode = ""
        var verificationUrl = ""
        var error = ""
    }

    struct Tone: Identifiable, Equatable {
        var id: Int
        var title: String
        var creator: String
        var gear: String
        var format: String
        var license: String
        var description: String
        var url: String
        var imageUrl: String
        var isIr: Bool

        init(_ info: rt.Tone3000Tone) {
            id = Int(info.id)
            title = String(info.title)
            creator = String(info.creator)
            gear = String(info.gear)
            format = String(info.format)
            license = String(info.license)
            description = String(info.description)
            url = String(info.url)
            imageUrl = String(info.imageUrl)
            isIr = info.isIr
        }
    }

    struct Model: Identifiable, Equatable {
        var id: Int
        var name: String
        var size: String
        var architecture: String
    }

    struct List: Equatable {
        var loading = false
        var error = ""
        var tones: [Tone] = []
        var page = 0
        var hasMore = false
    }

    struct Detail: Equatable {
        var loading = false
        var error = ""
        var tone: Tone?
        var models: [Model] = []
    }

    /// The lists TONE3000 offers, in the order they're shown.
    static let lists: [(id: String, title: String)] = [
        ("favorited", "Favorites"), ("created", "Created"), ("downloaded", "Downloaded"),
        ("trending", "Trending"), ("latest", "Latest"),
    ]

    @Published private(set) var account = Account()
    /// By list and what it's for, since a cabinet's lists ask TONE3000 for cabs only.
    struct ListKey: Hashable {
        var which: String
        var forCabinet: Bool
    }

    @Published private(set) var listsShown: [ListKey: List] = [:]
    @Published private(set) var details: [Int: Detail] = [:]

    /// A tone chosen in TONE3000's picker in the web browser, until the browser shows it.
    @Published var browsedTone: Int?

    private var app: rt.App? { rt.app() }

    /// Called whenever the core's revision moves, and when a TONE3000 view appears.
    func refresh() {
        guard let app else { return }

        let info = app.tone3000Account()
        let newAccount = Account(available: info.available, signedIn: info.signedIn, signingIn: info.signingIn,
                                 browsing: info.browsing, userName: String(info.userName), avatarUrl: String(info.avatarUrl),
                                 userCode: String(info.userCode), verificationUrl: String(info.verificationUrl),
                                 error: String(info.error))
        if newAccount != account { account = newAccount }

        var newLists = listsShown
        for key in listsShown.keys {
            let list = app.tone3000List(std.string(key.which), key.forCabinet ? .cabinet : .amp)
            newLists[key] = List(loading: list.loading, error: String(list.error),
                                   tones: list.tones.map { Tone($0) }, page: Int(list.page), hasMore: list.hasMore)
        }
        if newLists != listsShown { listsShown = newLists }

        var newDetails = details
        for id in details.keys {
            let detail = app.tone3000Tone(Int32(id))
            newDetails[id] = Detail(loading: detail.loading, error: String(detail.error),
                                    tone: detail.tone.id > 0 ? Tone(detail.tone) : nil,
                                    models: detail.models.map { Model(id: Int($0.id), name: String($0.name),
                                                                      size: String($0.size), architecture: String($0.architecture)) })
        }
        if newDetails != details { details = newDetails }

        let browsed = Int(app.tone3000TakeBrowsedTone())
        if browsed > 0 { browsedTone = browsed }
    }

    func signIn() { app?.tone3000SignIn(); refresh() }
    func cancelSignIn() { app?.tone3000CancelSignIn(); refresh() }

    func signOut() {
        app?.tone3000SignOut()
        listsShown = [:]
        details = [:]
        refresh()
    }

    func list(_ which: String, for target: rt.Tone3000Target) -> List {
        listsShown[ListKey(which: which, forCabinet: target == .cabinet)] ?? List(loading: true)
    }

    /// Page 1 starts the list again (fresh asks TONE3000 rather than using what's kept).
    func loadList(_ which: String, for target: rt.Tone3000Target, page: Int = 1, fresh: Bool = false) {
        let key = ListKey(which: which, forCabinet: target == .cabinet)
        if listsShown[key] == nil { listsShown[key] = List(loading: true) }
        app?.tone3000LoadList(std.string(which), target, Int32(page), fresh)
        refresh()
    }

    func detail(_ toneId: Int) -> Detail { details[toneId] ?? Detail(loading: true) }

    func loadTone(_ toneId: Int) {
        if details[toneId] == nil { details[toneId] = Detail(loading: true) }
        app?.tone3000LoadTone(Int32(toneId))
        refresh()
    }

    func browse(for target: rt.Tone3000Target) {
        app?.tone3000Browse(target)
        refresh()
    }

    func use(track: Int, target: rt.Tone3000Target, toneId: Int, modelId: Int) {
        app?.tone3000Use(Int32(track), target, Int32(toneId), Int32(modelId))
    }
}
