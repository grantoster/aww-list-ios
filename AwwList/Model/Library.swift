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
    /// Off unless the user turns it on: also send Claude photos Apple flagged as possible swimwear or shirtless
    /// (and the shots right around them). Either way they stay listed; off, Claude just never sees them.
    @Published private(set) var claudeSensitive = false
    func setClaudeSensitive(_ v: Bool) { claudeSensitive = v; rebuild(); save() }
    /// Photo ids that must never be sent to Claude (Scorer.neverSend), worked out at each rebuild.
    private(set) var neverSend: Set<String> = []
    /// Every photo Claude ever removed, and why; kept even after "Go back to on-device scores only", so a
    /// removed photo (and a bath session Claude caught) is never sent again.
    @Published private(set) var claudeRemoved: [String: String] = [:]
    /// Every photo sent to each model (model id → photo ids), so switching models back and forth can't
    /// spend a year's budget twice.
    private(set) var claudeSent: [String: Set<String>] = [:]
    /// The year each sent photo counted against (fixed when sent, so deleting or re-dating it doesn't free a slot).
    private(set) var claudeSentYear: [String: Int] = [:]
    /// What's left off the list and why, with counts (worked out at each rebuild), for Settings.
    struct LeftOut: Hashable { let reason: String; let count: Int }
    @Published private(set) var leftOut: [LeftOut] = []
    @Published private(set) var listedPhotos = 0

    /// Possible bath or undressed photos are listed and scored on the phone, unless the user keeps one out.
    /// They (and every shot within 10 minutes of one) are never sent to Claude either way.
    @Published private(set) var keptOut: Set<String> = []
    func setPutBack(_ id: String, _ on: Bool) {
        if on { keptOut.remove(id) } else { keptOut.insert(id) }
        rebuild(); save()
    }
    /// The possible bath or undressed photos currently on the list (all of them except those kept out).
    var putBack: Set<String> {
        Set(photos.values.filter { Scorer.heldBack.contains($0.excluded ?? "") && $0.raw == nil }.map(\.id)).subtracting(keptOut)
    }
    /// Photos Apple held back as possible bath or undressed (newest first), for review in Settings.
    var heldBackPhotos: [PhotoScore] {
        photos.values.filter { $0.raw == nil && Scorer.heldBack.contains($0.excluded ?? "") && $0.version == Scorer.version }
            .sorted { $0.date > $1.date }
    }

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
        var claudeFailures: [String: Int]?; var learned: LearnedModel?; var claudeSensitive: Bool?
        var putBack: [String]?; var keptOut: [String]?; var learnedFilter: LearnedFilter?; var trainedSignature: UInt64?
        var useBuiltInLearning: Bool?
        var claudeRemoved: [String: String]?; var claudeSent: [String: [String]]?; var claudeSentYear: [String: Int]?
    }

    init() {
        load()
        if !loaded { applyLearning(); rebuild() }   // a fresh install (load already did this otherwise)
        learnPeople()
    }

    /// New results from the scanner. The list is rebuilt at most every 2 seconds while scanning.
    func add(_ new: [PhotoScore]) {
        guard !new.isEmpty else { return }
        for p in new {
            whoCache[p.id] = nil
            // Only when the faces themselves changed; otherwise who's in the photo stays put during a rescan.
            guard let old = photos[p.id], old.faceRecords != p.faceRecords else { continue }
            for j in 0..<(old.faceRecords?.count ?? 0) { learnedFaces.remove(p.id + "#\(j)") }
            learnedWho[p.id] = nil
        }
        for var p in new {
            if p.claude == nil { p.claude = photos[p.id]?.claude }   // a rescan never throws away Claude's verdict
            if p.feat == nil { p.feat = photos[p.id]?.feat }
            if photos[p.id]?.privacyHold == true || Scorer.heldBack.contains(photos[p.id]?.excluded ?? "") && p.excluded != photos[p.id]?.excluded {
                p.privacyHold = true                                  // a never-send hold is never lifted by a re-read
            }         // nor a good fingerprint when this read's scene print failed
            photos[p.id] = p
        }
        unsaved += new.count
        if Date().timeIntervalSince(lastRebuild) > 15 { rebuild() }   // re-ranking everything is costly; keep it occasional while scanning
        if unsaved >= 200 { save() }
    }

    func finishScan() { rebuild(); save(); retrain(); learnPeople() }

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
    /// Photos Claude never returned a score for (batch lost, expired or errored): they can be sent again.
    func unsend(model: String, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        claudeSent[model]?.subtract(ids)
        save()
    }
    func addClaudeBatch(_ b: ClaudeBatch) {
        claudeBatches.append(b)
        claudeSent[b.model, default: []].formUnion(b.photos.values)
        for id in b.photos.values where claudeSentYear[id] == nil {
            if let d = photos[id]?.date { claudeSentYear[id] = Calendar.current.component(.year, from: d) }
        }
        flush()
    }
    func removeClaudeBatch(_ id: String) { claudeBatches.removeAll { $0.id == id }; save() }
    /// Second scores from the consistency check: stored next to the first (a removal on the second pass is
    /// recorded as no second score), and the learning then uses the average.
    func applyRecheck(_ verdicts: [String: ClaudeVerdict], failed: [String] = []) {
        guard !verdicts.isEmpty || !failed.isEmpty else { return }
        for id in failed { photos[id]?.claude?.rechecked = true }   // not offered (or billed) again
        for (id, v) in verdicts {
            guard let c = photos[id]?.claude else { continue }
            photos[id]?.claude?.rechecked = true
            // Only a second score from the same model and rubric is averaged with the first.
            guard v.model == c.model && v.rubric == c.rubric else { continue }
            if let e = v.exclude {
                // Claude took it off on the second pass: that call stands (and guards its burst from now on).
                claudeRemoved[id] = e
                photos[id]?.claude?.exclude = e
                photos[id]?.claude?.score2 = nil
            } else {
                photos[id]?.claude?.score2 = v.score
            }
        }
        rebuild(); flush()
        retrain()
    }
    /// How consistent Claude is with itself: photos scored twice, average distance, share within half a point.
    var consistency: (n: Int, gap: Double, withinHalf: Double)? {
        let pairs = photos.values.compactMap { p -> Double? in
            guard let c = p.claude, let s2 = c.score2 else { return nil }
            return abs(c.score - s2)
        }
        guard !pairs.isEmpty else { return nil }
        return (pairs.count, pairs.reduce(0, +) / Double(pairs.count),
                Double(pairs.filter { $0 <= 0.5 + 1e-9 }.count) / Double(pairs.count))
    }

    func applyClaude(_ verdicts: [String: ClaudeVerdict]) {
        guard !verdicts.isEmpty else { return }
        for (id, v) in verdicts {
            photos[id]?.claude = v
            if let e = v.exclude { claudeRemoved[id] = e }
        }
        rebuild(); flush()
        retrain()
    }

    // MARK: Learned score

    /// The app's model of Claude's scoring, learned from the photos Claude has scored.
    @Published private(set) var learned: LearnedModel?
    @Published private(set) var training = false
    /// The app's model of Claude's removals, and how many unseen photos it's keeping off the list right now.
    @Published private(set) var learnedFilter: LearnedFilter?
    @Published private(set) var filteredOut = 0
    /// The learning built into the app (from Resources/BuiltInLearning.json, when present): new installs start
    /// with it, and this phone's own Claude scores replace each part once there are enough of them.
    private let builtIn: (model: LearnedModel?, filter: LearnedFilter?) = {
        guard let u = Bundle.main.url(forResource: "BuiltInLearning", withExtension: "json"),
              let t = try? String(contentsOf: u, encoding: .utf8) else { return (nil, nil) }
        return LearningPack.read(t)
    }()
    var builtInScores: Int { builtIn.model?.trainedOn ?? 0 }
    var hasBuiltIn: Bool { builtIn.model != nil || builtIn.filter != nil }
    @Published private(set) var learnedIsBuiltIn = false
    @Published private(set) var filterIsBuiltIn = false
    /// What this phone learned from its own Claude verdicts (kept even while the built-in learning is in use).
    @Published private(set) var ownModel: LearnedModel?
    @Published private(set) var ownFilter: LearnedFilter?
    /// Use the built-in learning until this phone's own has learned from at least as many verdicts (default),
    /// or only this phone's own learning.
    @Published private(set) var useBuiltInLearning = true
    func setUseBuiltInLearning(_ v: Bool) { useBuiltInLearning = v; applyLearning(); rebuild(); save() }

    /// This phone's own learning as text (for building into the app); nil until it has learned something.
    var learningText: String? {
        ownModel == nil && ownFilter == nil ? nil : LearningPack(model: ownModel, filter: ownFilter).text()
    }
    /// Picks what's in use: this phone's own learning, or the built-in one where it's bigger (unless turned off).
    private func applyLearning() {
        func preferBuiltIn(_ own: Int?, _ b: Int?) -> Bool {
            guard useBuiltInLearning, let b else { return false }
            return own.map { $0 < b } ?? true
        }
        if preferBuiltIn(ownModel?.trainedOn, builtIn.model?.trainedOn) { learned = builtIn.model; learnedIsBuiltIn = true }
        else { learned = ownModel; learnedIsBuiltIn = false }
        if preferBuiltIn(ownFilter?.trainedOn, builtIn.filter?.trainedOn) { learnedFilter = builtIn.filter; filterIsBuiltIn = true }
        else { learnedFilter = ownFilter; filterIsBuiltIn = false }
    }
    /// Throws away this phone's own learning and learns again from every Claude verdict on hand.
    func relearn() {
        ownModel = nil; ownFilter = nil; trainedSignature = nil; generation += 1
        applyLearning(); rebuild(); save()
        retrain()
    }

    /// Claude scores that have a fingerprint to learn from.
    var learnableCount: Int {
        photos.values.filter { $0.claude != nil && $0.claude?.exclude == nil && $0.feat?.count == Learner.featureCount }.count
    }

    /// True when the learned filter expects Claude would take this photo off the list.
    func learnedRemoves(_ p: PhotoScore) -> Bool {
        guard let f = learnedFilter, f.useful, let feat = p.feat, let x = Learner.decode(feat) else { return false }
        return Learner.removalChance(f, x) >= Learner.removeAt
    }

    func learnedScore(for p: PhotoScore) -> Double? {
        guard let m = learned, let f = p.feat, let x = Learner.decode(f) else { return nil }
        return (Learner.predict(m, x) * 10).rounded(.toNearestOrAwayFromZero) / 10
    }

    /// Re-learns from every Claude verdict (off the main thread; up to about half a minute for thousands of scores). Runs after new verdicts
    /// arrive and after a scan adds fingerprints; skipped when nothing changed since the last run (even across launches).
    private var pendingRetrain = false
    private var trainedSignature: UInt64?
    /// Bumped by "Go back to on-device scores only", so a training run that started before it is ignored.
    private var generation = 0

    func retrain() {
        guard !training else { pendingRetrain = true; return }   // run again once the current one finishes
        var parts: [String] = []
        var examples: [(date: Date, x: [Double], y: Double)] = []
        var verdicts: [(date: Date, x: [Double], removed: Bool)] = []
        var averagedCount = 0
        for p in photos.values.sorted(by: { $0.id < $1.id }) {
            guard let c = p.claude, let f = p.feat, let x = Learner.decode(f) else { continue }
            parts.append("\(p.id)|\(c.score)|\(c.score2 ?? -1)|\(c.exclude ?? "")")
            verdicts.append((p.date, x, c.exclude != nil))
            // Where Claude scored a photo twice, learn from the average (closer to its real opinion).
            if c.exclude == nil { examples.append((p.date, x, c.score2.map { (c.score + $0) / 2 } ?? c.score)) }
            if c.exclude == nil && c.score2 != nil { averagedCount += 1 }
        }
        let signature = Learner.stableHash(parts)
        guard signature != trainedSignature else { return }      // nothing new to learn from (also across launches)
        training = true
        let gen = generation
        let averaged = averagedCount
        Task.detached(priority: .utility) {
            let model = Learner.train(examples, averaged: averaged)
            let filter = Learner.trainFilter(verdicts)
            await MainActor.run {
                self.training = false
                guard gen == self.generation else {          // cleared while this was running: start over
                    self.pendingRetrain = false; self.retrain(); return
                }
                self.trainedSignature = signature
                // This phone's own learning is always kept (and can be copied out); it's used once it has learned
                // from at least as many verdicts as the built-in one, or right away if the built-in one is turned off.
                self.ownModel = model; self.ownFilter = filter
                self.applyLearning()
                self.rebuild(); self.save()
                if self.pendingRetrain { self.pendingRetrain = false; self.retrain() }
            }
        }
    }
    func clearClaude() {
        for id in photos.keys where photos[id]?.claude != nil { photos[id]?.claude = nil }
        claudeBatches = []
        claudeSent = [:]   // starting over: each year's budget is available again (removals are kept, never re-sent)
        ownModel = nil; ownFilter = nil; trainedSignature = nil; generation += 1
        applyLearning()
        if rankBy == "learned" { rankBy = "apple" }
        rebuild(); save()
    }
    var claudeScored: Int { moments.filter { $0.claudeScore != nil }.count }
    /// The moments in Apple's on-device order (used to choose what to send to Claude).
    /// (Sorted once per rebuild, so Settings can show counts without re-sorting the library on every redraw.)
    /// What can be offered to Claude: Apple's list plus the photos Apple set aside for a soft reason, ranked
    /// each year by the learned score once there is one, otherwise by on-device score (cached at each rebuild).
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
    func setStrictness(_ v: Int) {
        strictness = v; learnedWho = [:]; learnedFaces = []; whoCache = [:]; rebuild(); save(); learnPeople()
    }

    /// Who's in each photo (photo id → people), worked out off the main thread from the faces you named:
    /// ordinary matches plus the faces the app learned (see People.learn). Not saved; worked out again at launch.
    private(set) var learnedWho: [String: Set<UUID>] = [:]
    /// Who's in each photo, cached between rebuilds (cleared whenever names or learning change).
    private var whoCache: [String: Set<UUID>] = [:]
    /// Faces (photo id # face number) already known to be someone, so Who's Who doesn't ask about them.
    private var learnedFaces = Set<String>()
    @Published private(set) var learningPeople = false
    /// "Is this X?" checks answered No this session (person id : group key), so they aren't asked again.
    var declinedChecks = Set<String>()
    private var peopleGeneration = 0
    private var peopleTask: Task<Void, Never>?

    /// Works out who the rest of the faces are from the ones you named (off the main thread), then updates the list.
    func learnPeople() {
        peopleGeneration += 1
        peopleTask?.cancel()
        guard !people.isEmpty else { learnedWho = [:]; learnedFaces = []; whoCache = [:]; learningPeople = false; return }
        let gen = peopleGeneration
        let snapshot = Array(photos.values)
        let named = people, t = threshold
        learningPeople = true
        peopleTask = Task.detached(priority: .utility) {
            var faces: [[Float]] = [], owners: [String] = [], keys: [String] = []
            for p in snapshot {
                for (j, f) in (p.faceRecords ?? []).enumerated() where f.vec.count == People.dim {
                    faces.append(People.floats(f.vec)); owners.append(p.id); keys.append(p.id + "#\(j)")
                }
            }
            let (matched, learned) = People.learn(faces, people: named, threshold: t)
            if Task.isCancelled { return }
            var who: [String: Set<UUID>] = [:], done = Set<String>(), counts: [UUID: Int] = [:]
            for (i, id) in matched { who[owners[i], default: []].insert(id); done.insert(keys[i]) }
            for (i, id) in learned { who[owners[i], default: []].insert(id); done.insert(keys[i]); counts[id, default: 0] += 1 }
            let result = who, known = done, learnedCounts = counts
            await MainActor.run {
                guard gen == self.peopleGeneration else { return }   // names changed meanwhile: a newer run is coming
                for k in self.people.indices { self.people[k].learnedCount = learnedCounts[self.people[k].id] ?? 0 }
                self.learnedWho = result
                self.learnedFaces = known
                self.whoCache = [:]
                self.learningPeople = false
                self.rebuild(); self.save()
            }
        }
    }

    /// Names a group of faces. Using a name that already exists adds the faces to that person.
    func name(_ faces: [(photo: String, face: FaceRecord)], as rawName: String, birthday: Date?) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let first = faces.first else { return }
        let faces = faces.filter { $0.face.vec.count == People.dim }
        guard !faces.isEmpty else { return }
        let vecs = faces.map { People.floats($0.face.vec) }
        let newExamples = People.spread(faces.map(\.face.vec), to: 40)
        if let i = people.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            people[i].centroid = People.merged(people[i].centroid, count: people[i].count, adding: vecs)
            people[i].count += vecs.count
            if let birthday { people[i].birthday = birthday }
            people[i].examples = People.spread((people[i].examples ?? []) + newExamples, to: 80)
            people[i].namedExamples = people[i].examples?.count
        } else {
            var p = Person(name: name, birthday: birthday, centroid: People.merged([], count: 0, adding: vecs),
                           count: vecs.count, samplePhoto: first.photo, sampleBox: first.face.box)
            p.examples = newExamples; p.namedExamples = newExamples.count
            people.append(p)
        }
        // These faces are known now, even before learning finishes.
        let names = Set(faces.map(\.photo))
        for f in faces { if let j = photos[f.photo]?.faceRecords?.firstIndex(of: f.face) { learnedFaces.insert(f.photo + "#\(j)") } }
        if let id = people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.id {
            for ph in names { learnedWho[ph, default: []].insert(id); whoCache[ph] = nil }
        }
        rebuild(); save()
        learnPeople()
    }

    /// Saves a rename or birthday (nothing else, so learning that finished meanwhile isn't undone).
    func update(_ person: Person) {
        guard let i = people.firstIndex(where: { $0.id == person.id }) else { return }
        people[i].name = person.name; people[i].birthday = person.birthday
        whoCache = [:]; rebuild(); save()
    }

    func forget(_ person: Person) {
        people.removeAll { $0.id == person.id }
        for k in learnedWho.keys { learnedWho[k]?.remove(person.id) }
        whoCache = [:]; rebuild(); save(); learnPeople()
    }

    /// Faces in ranked photos that don't match anyone named yet (largest faces of the best moments first).
    func unnamedFaces(limit: Int = 2500) -> [(photo: String, face: FaceRecord)] {
        var out: [(photo: String, face: FaceRecord)] = []
        let t = threshold
        let centroids = People.Matcher(people.map { p -> Person in var p = p; p.examples = nil; return p })
        for m in moments {
            for (j, f) in (m.best.faceRecords ?? []).enumerated() where f.vec.count == People.dim
                && !learnedFaces.contains(m.best.id + "#\(j)") && centroids.match(People.floats(f.vec), threshold: t) == nil {
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
        // Apple's flags (no child spotted, water, swimwear, shirtless, AI or edited file) no longer take a photo
        // off the list: it's listed with the score it would have had, and Claude decides. Only possible bath or
        // undressed photos (and the shots around them) are held back, unless the user puts them back.
        let pb = putBack
        let groups = Scorer.moments(from: Array(photos.values), hidden: hidden, version: Scorer.version, putBack: pb)
        let cal = Calendar.current
        let scores = Scorer.calibrate(groups.map { Scorer.listedValue($0.best, putBack: pb) ?? 0 },
                                      years: groups.map { cal.component(.year, from: $0.best.date) })
        let named = people, t = threshold
        // Centroids only here (fast, on the main thread); the thorough matching comes from learnPeople.
        let matcher = People.Matcher(named.map { p -> Person in var p = p; p.examples = nil; return p })
        let gregorian = Calendar(identifier: .gregorian)
        // A named person's birthday only sorts photos while they're a child (grown-ups named in Who's Who don't count).
        func childAt(_ birth: Date, _ date: Date) -> Bool {
            birth <= date && (gregorian.dateComponents([.year], from: birth, to: date).year ?? 0) < 13
        }
        func makeMoment(_ g: (best: PhotoScore, shots: Int, ids: [String]), _ s: Int) -> Moment {
            let who: Set<UUID>
            if let cached = whoCache[g.best.id] { who = cached } else {
                who = Set((g.best.faceRecords ?? []).compactMap { matcher.match(People.floats($0.vec), threshold: t) })
                    .union(learnedWho[g.best.id] ?? [])
                whoCache[g.best.id] = who
            }
            // Named people with birthdays give exact ages; otherwise ages come from the birthdays and the photo.
            let date = g.best.date
            let known = named.filter { who.contains($0.id) }.compactMap(\.birthday).filter { childAt($0, date) }
            let bdays = Array(Set(birthdays + named.compactMap(\.birthday).filter { childAt($0, date) || $0 > date }))
            let ages: Set<AgeGroup> = known.isEmpty
                ? AgeGroup.tags(date: date, birthdays: bdays, looksLikeBaby: g.best.age == .baby, faces: g.best.faces ?? 1)
                : Set(known.map { AgeGroup.of(birth: $0, at: g.best.date) })
            var m = Moment(best: g.best, shots: g.shots, memberIDs: g.ids, score: s, ages: ages, people: who)
            m.apple = s
            m.claudeScore = g.best.claude.flatMap { $0.exclude == nil ? $0.score : nil }
            m.learnedScore = learnedScore(for: g.best)
            return m
        }
        let all = zip(groups, scores).map { makeMoment($0, $1) }
        // What can be sent to Claude: every listed moment except any that contains a photo that must never be sent
        // (possible bath/undressed and their sessions, even after a put back; swimwear/shirtless unless allowed).
        // Once the app has learned, it picks what to send Claude by its prediction of Claude's score.
        func poolValue(_ m: Moment) -> Double { m.learnedScore ?? 10 * (Scorer.listedValue(m.best, putBack: pb, includePoolOnly: true) ?? 0) }
        let forbidden = Scorer.neverSend(Array(photos.values), allowSwimShirtless: claudeSensitive, removed: claudeRemoved)
        neverSend = forbidden
        // Photos with faces but no child label: not listed, but offered to Claude too (Apple's labels miss kids).
        let listedIDs = Set(groups.flatMap(\.ids))
        let poolOnly = Scorer.moments(from: Array(photos.values), hidden: hidden, version: Scorer.version,
                                      putBack: pb, includePoolOnly: true)
            .filter { g in Scorer.poolOnly.contains(g.best.excluded ?? "") && !g.ids.contains(where: listedIDs.contains) }
            .map { makeMoment($0, 0) }
        claudePool = (all + poolOnly).filter { !$0.memberIDs.contains(where: forbidden.contains) }.sorted { a, b in
            let va = poolValue(a), vb = poolValue(b)
            return va != vb ? va > vb : a.best.date < b.best.date
        }
        // Claude decides removals: a photo Claude took off (bath, swimwear, shirtless, AI or edited, no child) is
        // off in every ranking. Ranking by Claude: Claude's score leads, and moments it hasn't seen are capped at 6
        // (8 with a learned score) so they can't outrank the ones it looked at. Ranking by Claude or by the learned
        // score, moments Claude hasn't seen are also left off when the learned filter (learned from Claude's own
        // removals) expects Claude would remove them. Ranking by Apple shows Apple's view, flags and all.
        let anyClaude = photos.values.contains { $0.claude != nil && $0.claude?.exclude == nil && $0.version == Scorer.version }
        let useClaude = anyClaude && rankBy == "claude"
        let useLearned = learned != nil && rankBy == "learned"
        var filtered = 0
        var filteredIDs = Set<String>()
        moments = all.compactMap { m in
            var m = m
            // Claude's removal sticks to the whole burst, even if a different shot becomes its best later.
            if m.memberIDs.contains(where: { photos[$0]?.claude?.exclude != nil }) { return nil }
            if (useClaude || useLearned) && m.best.claude == nil
                && !m.memberIDs.contains(where: { Scorer.heldBack.contains(photos[$0]?.excluded ?? "") || photos[$0]?.privacyHold == true })
                && learnedRemoves(m.best) {   // you chose to keep possible bath photos
                filtered += 1; filteredIDs.formUnion(m.memberIDs); return nil
            }
            if useClaude {
                // learned scores top out at 8 here, so Claude's own 9s and 10s stay Claude's
                m.score = m.claudeScore.map(Claude.displayScore) ?? m.learnedScore.map { min(Claude.displayScore($0), 8) } ?? min(m.apple, 6)
            } else if useLearned {
                m.score = m.learnedScore.map(Claude.displayScore) ?? m.apple
            }
            return m
        }
        filteredOut = filtered
        // Ones Claude kept from the no-child-label group join the list when ranking by Claude or the learned score.
        if useClaude || useLearned {
            for var m in poolOnly where m.best.claude?.exclude == nil && !m.memberIDs.contains(where: { photos[$0]?.claude?.exclude != nil }) {
                guard let c = m.best.claude else { continue }
                m.claudeScore = c.score
                m.score = Claude.displayScore(c.score)
                moments.append(m)
            }
        }
        // Same 1–10 spread in every view (about 1 in 20 moments a 9 or 10): when ranking by Claude or by the learned
        // score, the list's score is that score's rank, bucketed like Apple's. The viewer still shows the actual
        // Claude and learned numbers. Moments Claude hasn't seen still top out at 8 (learned) or 6 (Apple only).
        if useClaude || useLearned {
            let vals = moments.map { m -> Double in
                // A sliver of Apple's raw score breaks ties between equal (rounded) values, so a big tie at a bucket
                // edge can't all land in the higher bucket; Apple-only moments sit at 6 or below in both views.
                let appleOnly: Double = Double(min(m.apple, 6))
                var v: Double = appleOnly
                if useClaude {
                    if let c = m.claudeScore { v = c } else if let l = m.learnedScore { v = min(l, 8) }
                } else if let l = m.learnedScore {
                    v = l
                }
                let raw: Double = m.best.raw ?? 0
                return v + raw * 0.001
            }
            let cal = Scorer.calibrate(vals.map { $0 / 10 }, years: moments.map(\.year))
            for i in moments.indices {
                let m = moments[i]
                let cap: Int
                if useClaude { cap = m.claudeScore != nil ? 10 : (m.learnedScore != nil ? 8 : 6) }
                else { cap = m.learnedScore != nil ? 10 : 6 }
                moments[i].score = min(cal[i], cap)
            }
        }
        // What's left off and why (current photos only; hidden ones are counted separately).
        var counts: [String: Int] = [:]
        let shown = Set(moments.flatMap(\.memberIDs))
        for p in photos.values where !shown.contains(p.id) {
            let why: String
            if hidden.contains(p.id) { why = "Removed by you" }
            else if p.version != Scorer.version
                        || (p.excluded == "No child" && p.soft == nil && (p.faces ?? 0) > 0 && (p.flagVersion ?? 0) < 3)
                        || Scorer.needsShirtlessRecheck(p) {
                why = "Waiting to be checked again"
            }
            else if filteredIDs.contains(p.id) { why = "Hidden by the learned filter" }
            else if p.claude?.exclude != nil || claudeRemoved[p.id] != nil || listedIDs.contains(p.id) { why = "Removed by Claude" }
            else if let e = p.excluded {
                switch e {
                case "No child seen":
                    why = forbidden.contains(p.id) ? "Faces but no child label, near a photo that's never sent"
                        : p.claude != nil ? "Faces but no child label (Claude checked)"
                        : "Faces but no child label (Claude can still check these)"
                case "No child": why = (p.faces ?? 0) > 0 ? "No sign of a child" : "No child and no face"
                case "Bath", "Undressed": why = keptOut.contains(p.id) ? "Possible bath or undressed (kept out by you)" : "Possible bath or undressed, can't be scored"
                case Scorer.unavailable: why = "Couldn't be loaded (iCloud)"
                default: why = Scorer.softReasons.contains(e) ? "\(e), and no sign of a child" : e
                }
            } else { why = "Other" }
            counts[why, default: 0] += 1
        }
        leftOut = counts.map { LeftOut(reason: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.reason < $1.reason }
        listedPhotos = shown.count
        moments.sort(by: Library.ranked)
    }

    /// Higher score first; then higher raw score; then the earlier photo.
    nonisolated static func ranked(_ a: Moment, _ b: Moment) -> Bool {
        if a.score != b.score { return a.score > b.score }
        let ca = a.claudeScore ?? 0, cb = b.claudeScore ?? 0
        if ca != cb { return ca > cb }
        let la = a.learnedScore ?? 0, lb = b.learnedScore ?? 0
        if la != lb { return la > lb }
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
                      claudeModel: claudeModel, claudeScope: claudeScope, claudeBatches: claudeBatches, rankBy: rankBy, claudeFailures: claudeFailures, learned: ownModel, claudeSensitive: claudeSensitive,
                      putBack: nil, keptOut: Array(keptOut), learnedFilter: ownFilter,
                      trainedSignature: trainedSignature, useBuiltInLearning: useBuiltInLearning,
                      claudeRemoved: claudeRemoved, claudeSent: claudeSent.mapValues { Array($0) },
                      claudeSentYear: claudeSentYear)
        let u = url
        // One save at a time, in order, so an older snapshot can never land after a newer one.
        Library.saveQueue.async {
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: u, options: .atomic) }
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    private var loaded = false
    private func load() {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        loaded = true
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
        keptOut = Set(s.keptOut ?? [])
        claudeSensitive = s.claudeSensitive ?? false
        ownFilter = s.learnedFilter.flatMap { $0.weights.count == Learner.featureCount ? $0 : nil }
        useBuiltInLearning = s.useBuiltInLearning ?? true
        // Saves from before this phone's own learning was kept alongside the built-in one: learn once more at
        // launch, so it comes back (and can be copied) without waiting for new Claude scores.
        if s.useBuiltInLearning == nil { trainedSignature = nil }
        trainedSignature = s.trainedSignature
        claudeRemoved = s.claudeRemoved ?? [:]
        claudeSent = (s.claudeSent ?? [:]).mapValues(Set.init)
        claudeSentYear = s.claudeSentYear ?? [:]
        // Saves from before these ledgers: fill them from the verdicts and pending batches on hand.
        for p in photos.values {
            if let c = p.claude {
                if c.rubric == Claude.rubric { claudeSent[c.model, default: []].insert(p.id) }
                if let e = c.exclude { claudeRemoved[p.id] = e }
            }
        }
        // A filter saved before its check counted removals would stay switched off: learn again once.
        if let f = ownFilter, f.testRemovals == nil { trainedSignature = nil }
        ownModel = s.learned.flatMap { m -> LearnedModel? in
            guard m.weights.count == Learner.featureCount else { return nil }
            var m = m
            if let n = m.mlp, n.w1.count != n.h * Learner.netInputs || n.b1.count != n.h || n.w2.count != n.h { m.mlp = nil; m.blend = 0 }
            return m
        }
        applyLearning()
        claudeScope = s.claudeScope ?? claudeScope
        claudeBatches = s.claudeBatches ?? []
        if s.claudeSent == nil { for b in claudeBatches { claudeSent[b.model, default: []].formUnion(b.photos.values) } }
        // Photos sent by builds from before the year was recorded: fix it now, from the record (if still there).
        let sentIDs = claudeSent.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            .union(claudeBatches.flatMap { $0.photos.values })
        for id in sentIDs where claudeSentYear[id] == nil {
            if let d = photos[id]?.date { claudeSentYear[id] = Calendar.current.component(.year, from: d) }
        }
        rankBy = s.rankBy ?? "claude"
        claudeFailures = s.claudeFailures ?? [:]
        rebuild()
        retrain()
    }
}
