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
    /// What's left off the list and why, with counts (worked out at each rebuild), for Settings.
    struct LeftOut: Hashable { let reason: String; let count: Int }
    @Published private(set) var leftOut: [LeftOut] = []
    @Published private(set) var listedPhotos = 0

    /// Possible bath or undressed photos the user put back on the list. They're listed, but never sent to Claude.
    @Published private(set) var putBack: Set<String> = []
    func setPutBack(_ id: String, _ on: Bool) {
        if on { putBack.insert(id) } else { putBack.remove(id) }
        rebuild(); save()
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
        var putBack: [String]?; var learnedFilter: LearnedFilter?; var trainedSignature: UInt64?
        var claudeRemoved: [String: String]?; var claudeSent: [String: [String]]?
    }

    init() {
        load()
        if learned == nil || learnedFilter == nil { useBuiltInWhereMissing(); rebuild() }
    }

    /// New results from the scanner. The list is rebuilt at most every 2 seconds while scanning.
    func add(_ new: [PhotoScore]) {
        guard !new.isEmpty else { return }
        for var p in new {
            if p.claude == nil { p.claude = photos[p.id]?.claude }   // a rescan never throws away Claude's verdict
            if p.feat == nil { p.feat = photos[p.id]?.feat }         // nor a good fingerprint when this read's scene print failed
            photos[p.id] = p
        }
        unsaved += new.count
        if Date().timeIntervalSince(lastRebuild) > 15 { rebuild() }   // re-ranking everything is costly; keep it occasional while scanning
        if unsaved >= 200 { save() }
    }

    func finishScan() { rebuild(); save(); retrain() }

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
    func addClaudeBatch(_ b: ClaudeBatch) {
        claudeBatches.append(b)
        claudeSent[b.model, default: []].formUnion(b.photos.values)
        flush()
    }
    func removeClaudeBatch(_ id: String) { claudeBatches.removeAll { $0.id == id }; save() }
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
    @Published private(set) var learnedIsBuiltIn = false
    @Published private(set) var filterIsBuiltIn = false
    /// This phone's own learning (not the built-in one) as text, for building into the app.
    var learningText: String? {
        let m = learnedIsBuiltIn ? nil : learned, f = filterIsBuiltIn ? nil : learnedFilter
        return m == nil && f == nil ? nil : LearningPack(model: m, filter: f).text()
    }
    private func useBuiltInWhereMissing() {
        if learned == nil, let m = builtIn.model { learned = m; learnedIsBuiltIn = true }
        if learnedFilter == nil, let f = builtIn.filter { learnedFilter = f; filterIsBuiltIn = true }
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

    /// Re-learns from every Claude verdict (off the main thread; a few seconds at most). Runs after new verdicts
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
        for p in photos.values.sorted(by: { $0.id < $1.id }) {
            guard let c = p.claude, let f = p.feat, let x = Learner.decode(f) else { continue }
            parts.append("\(p.id)|\(c.score)|\(c.exclude ?? "")")
            verdicts.append((p.date, x, c.exclude != nil))
            if c.exclude == nil { examples.append((p.date, x, c.score)) }
        }
        let signature = Learner.stableHash(parts)
        guard signature != trainedSignature else { return }      // nothing new to learn from (also across launches)
        training = true
        let gen = generation
        Task.detached(priority: .utility) {
            let model = Learner.train(examples)
            let filter = Learner.trainFilter(verdicts)
            await MainActor.run {
                self.training = false
                guard gen == self.generation else {          // cleared while this was running: start over
                    self.pendingRetrain = false; self.retrain(); return
                }
                self.trainedSignature = signature
                // Too few scores (for example after clearing) means no learning of this phone's own: fall back to the
                // built-in learning, or none. This phone's own learning takes over from the built-in one only once it
                // has learned from at least as many Claude verdicts, so a fresh install doesn't trade 1,600 scores for 60.
                let keepModel = model.map { m in self.builtIn.model.map { m.trainedOn >= $0.trainedOn } ?? true } ?? false
                let keepFilter = filter.map { f in self.builtIn.filter.map { f.trainedOn >= $0.trainedOn } ?? true } ?? false
                self.learned = keepModel ? model : nil; self.learnedIsBuiltIn = false
                self.learnedFilter = keepFilter ? filter : nil; self.filterIsBuiltIn = false
                self.useBuiltInWhereMissing()
                self.rebuild(); self.save()
                if self.pendingRetrain { self.pendingRetrain = false; self.retrain() }
            }
        }
    }
    func clearClaude() {
        for id in photos.keys where photos[id]?.claude != nil { photos[id]?.claude = nil }
        claudeBatches = []
        claudeSent = [:]   // starting over: each year's budget is available again (removals are kept, never re-sent)
        learned = nil; learnedFilter = nil; trainedSignature = nil; generation += 1
        learnedIsBuiltIn = false; filterIsBuiltIn = false
        useBuiltInWhereMissing()
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
        // Apple's flags (no child spotted, water, swimwear, shirtless, AI or edited file) no longer take a photo
        // off the list: it's listed with the score it would have had, and Claude decides. Only possible bath or
        // undressed photos (and the shots around them) are held back, unless the user puts them back.
        let groups = Scorer.moments(from: Array(photos.values), hidden: hidden, version: Scorer.version, putBack: putBack)
        let cal = Calendar.current
        let pb = putBack
        let scores = Scorer.calibrate(groups.map { Scorer.listedValue($0.best, putBack: pb) ?? 0 },
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
            if (useClaude || useLearned) && m.best.claude == nil && learnedRemoves(m.best) {
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
        // What's left off and why (current photos only; hidden ones are counted separately).
        var counts: [String: Int] = [:]
        let shown = Set(moments.flatMap(\.memberIDs))
        for p in photos.values where !shown.contains(p.id) {
            let why: String
            if hidden.contains(p.id) { why = "Removed by you" }
            else if p.version != Scorer.version { why = "Waiting to be checked again" }
            else if filteredIDs.contains(p.id) { why = "Hidden by the learned filter" }
            else if p.claude?.exclude != nil || claudeRemoved[p.id] != nil || listedIDs.contains(p.id) { why = "Removed by Claude" }
            else if Scorer.listedValue(p, putBack: pb) != nil { why = "Within 10 minutes of a possible bath photo" }
            else if let e = p.excluded {
                switch e {
                case "No child seen": why = "Faces but no child label (Claude can still check these)"
                case "No child": why = "No child and no face"
                case "Bath", "Undressed": why = "Possible bath or undressed"
                case Scorer.unavailable: why = "Couldn't be loaded (iCloud)"
                default: why = e
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
                      claudeModel: claudeModel, claudeScope: claudeScope, claudeBatches: claudeBatches, rankBy: rankBy, claudeFailures: claudeFailures, learned: learnedIsBuiltIn ? nil : learned, claudeSensitive: claudeSensitive,
                      putBack: Array(putBack), learnedFilter: filterIsBuiltIn ? nil : learnedFilter,
                      trainedSignature: trainedSignature,
                      claudeRemoved: claudeRemoved, claudeSent: claudeSent.mapValues { Array($0) })
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
        putBack = Set(s.putBack ?? [])
        claudeSensitive = s.claudeSensitive ?? false
        learnedFilter = s.learnedFilter.flatMap { $0.weights.count == Learner.featureCount ? $0 : nil }
        trainedSignature = s.trainedSignature
        claudeRemoved = s.claudeRemoved ?? [:]
        claudeSent = (s.claudeSent ?? [:]).mapValues(Set.init)
        // Saves from before these ledgers: fill them from the verdicts and pending batches on hand.
        for p in photos.values {
            if let c = p.claude {
                claudeSent[c.model, default: []].insert(p.id)
                if let e = c.exclude { claudeRemoved[p.id] = e }
            }
        }
        for b in claudeBatches { claudeSent[b.model, default: []].formUnion(b.photos.values) }
        // A filter saved before its check counted removals would stay switched off: learn again once.
        if let f = learnedFilter, f.testRemovals == nil { trainedSignature = nil }
        learned = s.learned.flatMap { $0.weights.count == Learner.featureCount ? $0 : nil }
        claudeScope = s.claudeScope ?? claudeScope
        claudeBatches = s.claudeBatches ?? []
        rankBy = s.rankBy ?? "claude"
        claudeFailures = s.claudeFailures ?? [:]
        rebuild()
        retrain()
    }
}
