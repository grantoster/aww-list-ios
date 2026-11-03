import Foundation

/// Awwbum ranks the cutest photos of the kids; AwwSnap (a hidden second app, reached by tapping the logo) ranks
/// the best photos of the grown-ups. Each has its own photo list, scores, Claude settings and key, learning,
/// thumbs and settings; only Who's Who (people, tags and face learning) is shared.
enum AppMode: String, CaseIterable {
    case aww, snap

    static let key = "appMode"
    /// The app showing now (set when you switch; the screens are rebuilt for it).
    static var current: AppMode {
        get { AppMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .aww }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var name: String { self == .aww ? "awwbum" : "awwsnap" }
    var title: String { self == .aww ? "Awwbum" : "AwwSnap" }
    var other: AppMode { self == .aww ? .snap : .aww }

    /// A per-app settings key: Awwbum keeps its existing names; AwwSnap's are prefixed.
    func key(_ name: String) -> String { self == .aww ? name : "snap." + name }
}
