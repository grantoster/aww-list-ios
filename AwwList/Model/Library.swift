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
    /// Claude scoring settings and batches waiting for results.
    @Published private(set) var claudeModel = "claude-haiku-5-5"
    @Published private(set) var claudeScope = 300
    @Published private(set) var claudeBatches: [ClaudeBatch] = []
    /// Which score orders the lists once Claude has scored something: "claude" or "apple".
    @Published private(set) var rankBy = "claude"
    /// Off unless the user turns it on: also offer Claude photos Apple flagged as possible swimwear or shirtless.
    @Published private(set) var claudeSensitive = false
    func setClaudeSensitive(_ v: Bool) { claudeSensitive = v; rebuild(); save() }

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
        var claudeModel: String?; var claudeScope: Int?; var claudeBatches: [ClaudeBatch]?; var rankBy: String?
        var claudeFailures: [String: Int]?; var claudeSensitive: Bool?
    }

    init() { load() }

    /// New results from the scanner. The list is rebuilt at most every 2 seconds while scanning.
    func add(_ new: [PhotoScore]) {
        guard !new.isEmpty else { return }
        for var p in new {
            if p.claude == nil { p.claude = photos[p.id]?.claude }   // a rescan never throws away Claude's verdict
            photos[p.id] = p
        }
        unsaved += new.count
        if Date().timeIntervalSince(lastRebuild) > 15 { rebuild() }   // re-ranking everything is costly; keep it occasional while scanning
        if unsaved >= 200 { save() }
    }

    func finishScan() { rebuild(); save() }

    /// Removes a whole moment (every shot in its burst) from the list.
    func hide(_ m: Moment) { hidden.formUnion(m.memberIDs); rebuild(); save() }
    func restoreHidden() { hidden.removeAll(); rebuild(); save() }

    func setBirthdays(_ dates: [Date]) { birthdays = dates.sorted(); rebuild(); save() }

    // MARK: Claude

    func setClaude(model: String? = nil, scope: Int? = nil) {
        if let model { claudeModel = model }
        if let scope { claudeScope = scope }
        save()
    }
    func setRankBy(_ v: String) { rankBy = v; rebuild(); save() }
    func addClaudeBatch(_ b: ClaudeBatch) { claudeBatches.append(b); flush() }
    func removeClaudeBatch(_ id: String) { claudeBatches.removeAll { $0.id == id }; save() }
    func applyClaude(_ verdicts: [String: ClaudeVerdict]) {
        guard !verdicts.isEmpty else { return }
        for (id, v) in verdicts { photos[id]?.claude = v }
        rebuild(); flush()
    }
    func clearClaude() {
        for id in photos.keys where photos[id]?.claude != nil { photos[id]?.claude = nil }
        claudeBatches = []
        rebuild(); save()
    }
    var claudeScored: Int { moments.filter { $0.claudeScore != nil }.count }
    /// The moments in Apple's on-device order (used to choose what to send to Claude).
    /// (Sorted once per rebuild, so Settings can show counts without re-sorting the library on every redraw.)
    /// What can be offered to Claude: Apple's list plus the photos Apple set aside for a soft reason, ranked
    /// each year by on-device score (cached at each rebuild).
    private(set) var claudePool: [Moment] = []
    /// Photos Claude couldn't score, and how many times; after two tries they aren't re-sent (or re-billed).
    @Published private(set) var claudeFailures: [String: Int] = [:]
    func noteClaudeFailures(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { claudeFailures[id, default: 0] += 1 }
        save()
    }

    // MARK: Who's Who

    var threshold: Float { People.threshold(strictness: strictness) }
    func setStrictness(_ v: Int) { strictness = v; rebuild(); save() }

    /// Names a group of faces. Using a name that already exists adds the faces to that person.
    func name(_ faces: [(photo: String, face: FaceRecord)], as rawName: String, birthday: Date?) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let first = faces.first else { return }
        let faces = faces.filter { $0.face.vec.count == People.dim }
        guard !faces.isEmpty else { return }
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
            for f in m.best.faceRecords ?? [] where f.vec.count == People.dim && People.match(People.floats(f.vec), people: people, threshold: t) == nil {
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
        let gregorian = Calendar(identifier: .gregorian)
        // A named person's birthday only sorts photos while they're a child (grown-ups named in Who's Who don't count).
        func childAt(_ birth: Date, _ date: Date) -> Bool {
            birth <= date && (gregorian.dateComponents([.year], from: birth, to: date).year ?? 0) < 13
        }
        func makeMoment(_ g: (best: PhotoScore, shots: Int, ids: [String]), _ s: Int) -> Moment {
            let who = Set((g.best.faceRecords ?? []).compactMap { People.match(People.floats($0.vec), people: named, threshold: t) })
            // Named people with birthdays give exact ages; otherwise ages come from the birthdays and the photo.
            let date = g.best.date
            let known = named.filter { who.contains($0.id) }.compactMap(\.birthday).filter { childAt($0, date) }
            let bdays = Array(Set(birthdays + named.compactMap(\.birthday).filter { childAt($0, date) || $0 > date }))
            let ages: Set<AgeGroup> = known.isEmpty
                ? AgeGroup.tags(date: date, birthdays: bdays, looksLikeBaby: g.best.age == .baby, faces: g.best.faces ?? 1)
                : Set(known.map { AgeGroup.of(birth: $0, at: g.best.date) })
            return Moment(best: g.best, shots: g.shots, memberIDs: g.ids, score: s, ages: ages, people: who)
        }
        moments = zip(groups, scores).map { makeMoment($0, $1) }
        // Every moment keeps its Apple score; moments sent to Claude also get Claude's. Claude's safety checks
        // (bath, swimwear, shirtless, AI or edited, no child) take a photo off the list in both rankings.
        // Ranking by Claude: Claude's score leads, and moments it hasn't seen are capped at 6 so they can't
        // outrank the ones it looked at (the same rule as the Aww List website).
        let anyClaude = photos.values.contains { $0.claude != nil && $0.claude?.exclude == nil && $0.version == Scorer.version }
        let useClaude = anyClaude && rankBy == "claude"
        moments = moments.compactMap { m in
            var m = m
            m.apple = m.score
            if let c = m.best.claude {
                if c.exclude != nil { return nil }
                m.claudeScore = c.score
            }
            if useClaude { m.score = m.claudeScore.map(Claude.displayScore) ?? min(m.apple, 6) }
            return m
        }
        // The wider pool for Claude: Apple's moments plus set-aside ones (no child seen, water, etc.).
        let listed = Set(moments.flatMap(\.memberIDs))
        let softGroups = Scorer.moments(from: Array(photos.values), hidden: hidden, version: Scorer.version, soft: true)
            .filter { $0.best.raw == nil && listed.isDisjoint(with: $0.ids)
                && (claudeSensitive || !Scorer.sensitiveSoft.contains($0.best.excluded ?? "")) }
        let softMoments = softGroups.map { g -> Moment in var m = makeMoment(g, 0); m.claudeScore = g.best.claude?.score; return m }
        claudePool = (moments + softMoments).sorted { a, b in
            let va = a.best.raw ?? a.best.soft ?? 0, vb = b.best.raw ?? b.best.soft ?? 0
            return va != vb ? va > vb : a.best.date < b.best.date
        }
        // Set-aside photos Claude looked at and cleared join the list when ranking by Claude.
        if useClaude {
            for var m in softMoments {
                guard let c = m.best.claude, c.exclude == nil else { continue }
                m.claudeScore = c.score
                m.score = Claude.displayScore(c.score)
                moments.append(m)
            }
        }
        moments.sort(by: Library.ranked)
    }

    /// Higher score first; then higher raw score; then the earlier photo.
    nonisolated static func ranked(_ a: Moment, _ b: Moment) -> Bool {
        if a.score != b.score { return a.score > b.score }
        let ca = a.claudeScore ?? 0, cb = b.claudeScore ?? 0
        if ca != cb { return ca > cb }
        if a.apple != b.apple { return a.apple > b.apple }
        let ra = a.best.raw ?? 0, rb = b.best.raw ?? 0
        if ra != rb { return ra > rb }
        return a.best.date < b.best.date
    }

    var years: [Int] { Array(Set(moments.map(\.year))).sorted(by: >) }

    /// Saves now and waits for the write, so nothing is lost when iOS suspends or ends the app.
    func flush() {
        save()
        Library.saveQueue.sync {}
    }

    /// Writes to disk off the main thread.
    func save(then done: (@Sendable () -> Void)? = nil) {
        unsaved = 0
        let s = Saved(photos: Array(photos.values), hidden: Array(hidden), birthdays: birthdays,
                      people: people, strictness: strictness,
                      claudeModel: claudeModel, claudeScope: claudeScope, claudeBatches: claudeBatches, rankBy: rankBy, claudeFailures: claudeFailures, claudeSensitive: claudeSensitive)
        let u = url
        // One save at a time, in order, so an older snapshot can never land after a newer one.
        Library.saveQueue.async {
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: u, options: .atomic) }
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        photos = Dictionary(s.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        hidden = Set(s.hidden)
        birthdays = s.birthdays ?? []
        // Names saved with an older fingerprint size can't be compared; keep the names, ask for faces again.
        people = (s.people ?? []).map { p in
            var p = p
            if p.centroid.count != People.dim { p.centroid = []; p.count = 0 }
            return p
        }
        strictness = s.strictness ?? 1
        claudeModel = s.claudeModel ?? claudeModel
        // Haiku is the default; switch earlier saves that were on the old default and never sent anything.
        if claudeModel == "claude-sonnet-5-5" && !s.photos.contains(where: { $0.claude != nil }) && (s.claudeBatches ?? []).isEmpty {
            claudeModel = "claude-haiku-5-5"
        }
        claudeSensitive = s.claudeSensitive ?? false
        claudeScope = s.claudeScope ?? claudeScope
        claudeBatches = s.claudeBatches ?? []
        rankBy = s.rankBy ?? "claude"
        claudeFailures = s.claudeFailures ?? [:]
        rebuild()
    }
}
