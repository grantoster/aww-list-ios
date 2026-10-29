import Foundation

/// Holds every analyzed photo, saves them to disk, and builds the ranked moments.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var photos: [String: PhotoScore] = [:]
    @Published private(set) var moments: [Moment] = []
    @Published private(set) var hidden: Set<String> = []   // photos the user removed from the list

    private var lastRebuild = Date.distantPast
    private var unsaved = 0

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scores.json")
    }()
    private struct Saved: Codable { var photos: [PhotoScore]; var hidden: [String] }

    init() { load() }

    /// New results from the scanner. The list is rebuilt at most every 2 seconds while scanning.
    func add(_ new: [PhotoScore]) {
        guard !new.isEmpty else { return }
        for p in new { photos[p.id] = p }
        unsaved += new.count
        if Date().timeIntervalSince(lastRebuild) > 2 { rebuild() }
        if unsaved >= 1000 { save() }
    }

    func finishScan() { rebuild(); save() }

    /// Removes a whole moment (every shot in its burst) from the list.
    func hide(_ m: Moment) { hidden.formUnion(m.memberIDs); rebuild(); save() }
    func restoreHidden() { hidden.removeAll(); rebuild(); save() }

    /// Drops scores for photos that were deleted from the library (ids found by the scanner).
    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        ids.forEach { photos[$0] = nil }
        rebuild(); save()
    }

    func rebuild() {
        lastRebuild = Date()
        // Results from an older scorer never went through today's filters, so they stay off the list until re-scored.
        let groups = Scorer.moments(from: photos.values.filter { !hidden.contains($0.id) && $0.version == Scorer.version })
        let cal = Calendar.current
        let scores = Scorer.calibrate(groups.map { $0.best.raw ?? 0 },
                                      years: groups.map { cal.component(.year, from: $0.best.date) })
        moments = zip(groups, scores).map { g, s in Moment(best: g.best, shots: g.shots, memberIDs: g.ids, score: s) }
            .sorted(by: Library.ranked)
    }

    /// Higher score first; then higher raw score; then the earlier photo.
    nonisolated static func ranked(_ a: Moment, _ b: Moment) -> Bool {
        if a.score != b.score { return a.score > b.score }
        let ra = a.best.raw ?? 0, rb = b.best.raw ?? 0
        if ra != rb { return ra > rb }
        return a.best.date < b.best.date
    }

    var years: [Int] { Array(Set(moments.map(\.year))).sorted(by: >) }

    /// Writes to disk off the main thread.
    func save() {
        unsaved = 0
        let s = Saved(photos: Array(photos.values), hidden: Array(hidden))
        let u = url
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: u, options: .atomic) }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        photos = Dictionary(s.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        hidden = Set(s.hidden)
        rebuild()
    }
}
