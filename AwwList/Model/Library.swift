import Foundation

/// Holds every analyzed photo, saves them to disk, and builds the ranked moments.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var photos: [String: PhotoScore] = [:]
    @Published private(set) var moments: [Moment] = []
    @Published private(set) var hidden: Set<String> = []   // photos the user removed from the list
    /// The children's birthdays, which sort photos into Baby / Toddler / Kid.
    @Published private(set) var birthdays: [Date] = []
    /// People named in Who's Who.
    @Published private(set) var people: [Person] = []
    /// Who's Who grouping: 0 stricter, 1 normal, 2 looser.
    @Published private(set) var strictness = 1

    private static let saveQueue = DispatchQueue(label: "aww.save", qos: .utility)
    private var lastRebuild = Date.distantPast
    private var unsaved = 0

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scores.json")
    }()
    private struct Saved: Codable {
        var photos: [PhotoScore]; var hidden: [String]; var birthdays: [Date]?
        var people: [Person]?; var strictness: Int?
    }

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

    func setBirthdays(_ dates: [Date]) { birthdays = dates.sorted(); rebuild(); save() }

    // MARK: Who's Who

    var threshold: Float { People.threshold(strictness: strictness) }
    func setStrictness(_ v: Int) { strictness = v; rebuild(); save() }

    /// Names a group of faces. Using a name that already exists adds the faces to that person.
    func name(_ faces: [(photo: String, face: FaceRecord)], as rawName: String, birthday: Date?) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let first = faces.first else { return }
        let vecs = faces.map { People.floats($0.face.vec) }
        if let i = people.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            people[i].centroid = People.merged(people[i].centroid, count: people[i].count, adding: vecs)
            people[i].count += vecs.count
            if let birthday { people[i].birthday = birthday }
        } else {
            people.append(Person(name: name, birthday: birthday, centroid: People.merged([], count: 0, adding: vecs),
                                 count: vecs.count, samplePhoto: first.photo, sampleBox: first.face.box))
        }
        rebuild(); save()
    }

    func update(_ person: Person) {
        guard let i = people.firstIndex(where: { $0.id == person.id }) else { return }
        people[i] = person; rebuild(); save()
    }

    func forget(_ person: Person) { people.removeAll { $0.id == person.id }; rebuild(); save() }

    /// Faces in ranked photos that don't match anyone named yet (largest faces of the best moments first).
    func unnamedFaces(limit: Int = 2500) -> [(photo: String, face: FaceRecord)] {
        var out: [(photo: String, face: FaceRecord)] = []
        let t = threshold
        for m in moments {
            for f in m.best.faceRecords ?? [] where People.match(People.floats(f.vec), people: people, threshold: t) == nil {
                out.append((m.best.id, f))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Drops scores for photos that were deleted from the library (ids found by the scanner).
    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        ids.forEach { photos[$0] = nil }
        rebuild(); save()
    }

    func rebuild() {
        lastRebuild = Date()
        // Results from an older scorer never went through today's filters, so they stay off the list until re-scored,
        // but their bath/swim exclusions still quarantine the shots around them.
        let groups = Scorer.moments(from: Array(photos.values), hidden: hidden, version: Scorer.version)
        let cal = Calendar.current
        let scores = Scorer.calibrate(groups.map { $0.best.raw ?? 0 },
                                      years: groups.map { cal.component(.year, from: $0.best.date) })
        let named = people, t = threshold
        let bdays = Array(Set(birthdays + named.compactMap(\.birthday)))
        moments = zip(groups, scores).map { g, s in
            let who = Set((g.best.faceRecords ?? []).compactMap { People.match(People.floats($0.vec), people: named, threshold: t) })
            // Named people with birthdays give exact ages; otherwise ages come from the birthdays and the photo.
            let known = named.filter { who.contains($0.id) }.compactMap(\.birthday).filter { $0 <= g.best.date }
            let ages: Set<AgeGroup> = known.isEmpty
                ? AgeGroup.tags(date: g.best.date, birthdays: bdays, looksLikeBaby: g.best.age == .baby, faces: g.best.faces ?? 1)
                : Set(known.map { AgeGroup.of(birth: $0, at: g.best.date) })
            return Moment(best: g.best, shots: g.shots, memberIDs: g.ids, score: s, ages: ages, people: who)
        }
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
        let s = Saved(photos: Array(photos.values), hidden: Array(hidden), birthdays: birthdays,
                      people: people, strictness: strictness)
        let u = url
        // One save at a time, in order, so an older snapshot can never land after a newer one.
        Library.saveQueue.async {
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: u, options: .atomic) }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        photos = Dictionary(s.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        hidden = Set(s.hidden)
        birthdays = s.birthdays ?? []
        people = s.people ?? []
        strictness = s.strictness ?? 1
        rebuild()
    }
}
