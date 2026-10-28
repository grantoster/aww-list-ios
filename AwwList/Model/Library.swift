import Foundation
import Photos

/// Holds every analyzed photo, saves them to disk, and builds the ranked moments.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var photos: [String: PhotoScore] = [:]
    @Published private(set) var moments: [Moment] = []
    @Published var hidden: Set<String> = []   // photos the user removed from the list

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scores.json")
    }()
    private struct Saved: Codable { var photos: [PhotoScore]; var hidden: [String] }

    init() { load() }

    func add(_ new: [PhotoScore]) {
        guard !new.isEmpty else { return }
        for p in new { photos[p.id] = p }
        rebuild()
        if photos.count % 400 < new.count { save() }
    }

    func hide(_ m: Moment) { hidden.insert(m.best.id); rebuild(); save() }
    func restoreHidden() { hidden.removeAll(); rebuild(); save() }

    /// Removes scores for photos that were deleted from the library.
    func prune() {
        let ids = Array(photos.keys)
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var alive = Set<String>()
        found.enumerateObjects { a, _, _ in alive.insert(a.localIdentifier) }
        let gone = ids.filter { !alive.contains($0) }
        guard !gone.isEmpty else { return }
        gone.forEach { photos[$0] = nil }
        rebuild(); save()
    }

    func rebuild() {
        let groups = Scorer.moments(from: photos.values.filter { !hidden.contains($0.id) })
        let scores = Scorer.calibrate(groups.map { $0.best.raw ?? 0 })
        moments = zip(groups, scores).map { Moment(best: $0.0.best, shots: $0.0.shots, score: $0.1) }
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

    func save() {
        let s = Saved(photos: Array(photos.values), hidden: Array(hidden))
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        photos = Dictionary(uniqueKeysWithValues: s.photos.map { ($0.id, $0) })
        hidden = Set(s.hidden)
        rebuild()
    }
}
