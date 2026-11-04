import Foundation

/// When photos were taken that had to be held back for privacy (a possible bath or undressed photo, a privacy hold,
/// swimwear or a bare chest), kept as times only: never which photo, never what's in it. Shared by Awwbum and
/// AwwSnap and kept after the photo itself is hidden, deleted or re-read, so the photos taken around it are still
/// never sent to Claude: hiding a bath photo can't free the photos around it.
final class PrivacyMarks: @unchecked Sendable {
    enum Kind: Int, Codable { case always = 0, swimwear = 1, shirtless = 2 }
    struct Mark: Codable, Hashable { var t: Double; var kind: Kind }

    static let shared = PrivacyMarks()

    private let lock = NSLock()
    private var marks: [Mark] = []          // sorted by time
    private var known = Set<Mark>()
    private let url: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("privacy-marks.json")

    init() {
        if let url, let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([Mark].self, from: d) {
            known = Set(m); marks = known.sorted { $0.t < $1.t }
        }
    }

    /// The mark a photo leaves, if any (the same reasons as Scorer.neverSend).
    /// A photo that couldn't be read counts only once it's gone (`unreadable`): while it's still there, it's read
    /// again later and decides for itself.
    static func kind(_ p: PhotoScore, removed: String?, unreadable: Bool = false) -> Kind? {
        let sensitive: Set<String> = ["bath", "undressed"]
        if p.privacyHold == true || Scorer.heldBack.contains(p.excluded ?? "") || (unreadable && p.excluded == Scorer.unavailable)
            || sensitive.contains(p.claude?.exclude ?? "") || sensitive.contains(removed ?? "") { return .always }
        if p.excluded == "Swimwear" { return .swimwear }
        if p.excluded == "Shirtless" { return .shirtless }
        return nil
    }

    /// Notes the photos that need a mark (only a time is kept). Saved only when something new was added.
    func add(_ photos: [PhotoScore], removed: [String: String], gone: Bool = false) {
        let new = photos.compactMap { p -> Mark? in
            guard let k = Self.kind(p, removed: removed[p.id], unreadable: gone) else { return nil }
            return Mark(t: p.date.timeIntervalSinceReferenceDate.rounded(), kind: k)
        }
        lock.lock()
        let fresh = new.filter { !known.contains($0) }
        guard !fresh.isEmpty else { lock.unlock(); return }
        known.formUnion(fresh)
        marks = known.sorted { $0.t < $1.t }
        let all = marks
        lock.unlock()
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: url, options: [.atomic, .completeFileProtection]) }
    }

    /// Whether a photo taken at `date` is near a marked one: 10 minutes for bath, undressed and holds; for swimwear
    /// (10 minutes) and bare chests (2 minutes) only while swimwear and shirtless photos aren't allowed.
    func blocks(_ date: Date, allowSwimShirtless: Bool) -> Bool {
        let t = date.timeIntervalSinceReferenceDate
        lock.lock(); defer { lock.unlock() }
        // First mark at or after t − 600 (binary search), then the few within reach.
        var lo = 0, hi = marks.count
        while lo < hi { let mid = (lo + hi) / 2; if marks[mid].t < t - 600 { lo = mid + 1 } else { hi = mid } }
        var i = lo
        while i < marks.count && marks[i].t <= t + 600 {
            let m = marks[i], d = abs(m.t - t)
            switch m.kind {
            case .always: if d <= 600 { return true }
            case .swimwear: if !allowSwimShirtless && d <= 600 { return true }
            case .shirtless: if !allowSwimShirtless && d <= 120 { return true }
            }
            i += 1
        }
        return false
    }
}
