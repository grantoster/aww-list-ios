import Foundation
import UIKit

/// Holds every analyzed photo, saves them to disk, and builds the ranked moments.
@MainActor
final class Library: ObservableObject {
    /// Not published: it changes every few seconds while scanning, and redrawing every screen each time made the
    /// app sluggish. Screens update when the ranked list (`moments`) changes.
    private(set) var photos: [String: PhotoScore] = [:]
    @Published private(set) var moments: [Moment] = []
    /// Every ranked moment, before Consolidated keeps only the top 100s (for counts and Who's Who).
    private(set) var everyMoment: [Moment] = []
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
    /// Which score orders the lists: "learned" (the main one), "claude", "apple" or "consolidated".
    @Published private(set) var rankBy = "learned"
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
    /// A group of photos and why they're in it (newest first).
    struct LeftOut: Hashable { let reason: String; let count: Int; var ids: [String] = [] }
    @Published private(set) var leftOut: [LeftOut] = []
    /// Photos still on the list that Apple's check flagged (swimwear, shirtless, water, AI or edited, ...), by flag.
    @Published private(set) var flagged: [LeftOut] = []
    @Published private(set) var listedPhotos = 0

    /// Possible bath or undressed photos are listed and scored on the phone, unless the user keeps one out.
    /// They (and every shot within 10 minutes of one) are never sent to Claude either way.
    @Published private(set) var keptOut: Set<String> = []
    /// Photos you added back to the list yourself from a "What's left out" group (faces but no child label, removed
    /// by Claude, hidden by the learned filter, ...). They're listed whatever the checks said.
    @Published private(set) var addedBack: Set<String> = []
    /// Everything you put back on the list yourself.
    var manualAdds: Set<String> { addedBack }
    func addBack(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        hidden.subtract(ids)        // ones you'd removed from the list
        keptOut.subtract(ids)       // possible bath photos you'd kept out (still never sent to Claude)
        addedBack.formUnion(ids)
        rebuild(); save()
    }
    /// Photos that can't be added back: screenshots, documents and photos with no date.
    func canAddBack(_ p: PhotoScore) -> Bool {
        !["Screenshot", "Document", "No date"].contains(p.excluded ?? "") && p.date > Date.distantPast
    }
    func takeBack(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        addedBack.subtract(ids)
        rebuild(); save()
    }

    /// What a thumbs moves a photo's score, in points: up a quarter, down a half (it's mostly for pushing photos down).
    nonisolated static func thumbNudge(_ r: Int) -> Double { r > 0 ? 0.25 : r < 0 ? -0.5 : 0 }
    /// Your thumbs up (1) or down (-1) by photo id: up a quarter point, down a half, on Claude's or the learned score when ranking
    /// (it settles ties in Apple's and Consolidated); for photos Claude scored, the learning learns from it; and
    /// Learn my Likes learns your taste from all of them.
    @Published private(set) var reactions: [String: Int] = [:]
    func setReaction(_ m: Moment, _ value: Int, learnSoon: Bool = true) {
        for id in m.memberIDs { reactions[id] = nil }
        if value != 0 { reactions[m.best.id] = value }
        rebuildSoon(); saveSoon()
        guard learnSoon else { return }   // Learn my Likes learns once, when you finish
        // Learning waits until you've stopped tapping for a few seconds (it re-learns from everything).
        reactionRetrain?.cancel()
        reactionRetrain = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self.retrain()
        }
    }
    private var reactionRetrain: Task<Void, Never>?
    func reaction(_ m: Moment) -> Int {
        reactions[m.best.id] ?? m.memberIDs.lazy.compactMap { self.reactions[$0] }.first ?? 0
    }
    /// The moment with your thumbs applied to its score.
    private func reacted(_ m: Moment) -> Moment {
        let r = reaction(m)
        guard r != 0 else { return m }
        var m = m
        m.reaction = r
        // The nudge itself goes into the score behind the list (see rebuild); here it only breaks ties.
        return m
    }

    func setPutBack(_ id: String, _ on: Bool) {
        if on { keptOut.remove(id) } else { keptOut.insert(id) }
        rebuild(); save()
    }
    /// The possible bath or undressed photos currently on the list (all of them except those kept out).
    var putBack: Set<String> {
        Set(photos.values.filter { Scorer.heldBack.contains($0.excluded ?? "") && $0.raw == nil }.map(\.id)).subtracting(keptOut)
    }
    /// Photos Apple held back as possible bath or undressed (newest first), for review in Settings.
    /// Worked out once per re-rank (Settings reads it on every redraw).
    private(set) var heldBackPhotos: [PhotoScore] = []
    private(set) var learnableCount = 0

    /// With Limited photo access, photos outside the selection can't be seen right now. Their records (and
    /// Claude's paid-for scores) are kept, just left out of the list, instead of being deleted.
    private(set) var notVisible: Set<String> = []
    func setNotVisible(_ ids: Set<String>) {
        guard ids != notVisible else { return }
        notVisible = ids
        rebuild()
        learnPeople()   // faces in photos that just became visible (or hidden) are counted and recognized again
    }

    private static let saveQueue = DispatchQueue(label: "aww.save", qos: .utility)
    private var lastRebuild = Date.distantPast
    private var unsaved = 0
    private var lastSave = Date()

    /// The library is saved as a compact binary file (much smaller and lighter on memory than the JSON it
    /// replaces, which a large library could push past iOS's memory limit while saving). The old JSON file is
    /// read once if that's all there is, and removed after the first binary save.
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scores.plist")
    }()
    private var legacyURL: URL { url.deletingLastPathComponent().appendingPathComponent("scores.json") }
    private struct Saved: Codable {
        var photos: [PhotoScore]; var hidden: [String]; var birthdays: [Date]?
        var people: [Person]?; var strictness: Int?
        var claudeModel: String?; var claudeScope: Int?; var claudeBatches: [ClaudeBatch]?; var rankBy: String?
        var claudeFailures: [String: Int]?; var learned: LearnedModel?; var claudeSensitive: Bool?
        var putBack: [String]?; var keptOut: [String]?; var learnedFilter: LearnedFilter?; var trainedSignature: UInt64?
        var useBuiltInLearning: Bool?
        /// The same signature stored as a signed number (every save format handles those).
        var trainedSignatureBits: Int64? = nil
        var claudeRemoved: [String: String]?; var claudeSent: [String: [String]]?; var claudeSentYear: [String: Int]?
        var reactions: [String: Int]? = nil
        var notThem: [String: [String]]? = nil; var ignoredFaces: [String]? = nil
        var addedBack: [String]? = nil
        var confirmedFaces: [String: String]? = nil
        var skippedFaces: [String]? = nil
        var taste: TasteModel? = nil
        var tasteSignatureBits: Int64? = nil
    }

    /// False until the saved library has been read (off the main thread, so a large library can't make iOS end
    /// the app for taking too long to open). Nothing is saved or scanned before then.
    @Published private(set) var ready = false
    /// Whether this iPhone already had saved Awwbum data when the app opened (an existing install).
    private(set) var hadSavedData = false
    private var readyHandlers: [() -> Void] = []
    func whenReady(_ handler: @escaping () -> Void) { if ready { handler() } else { readyHandlers.append(handler) } }

    init() {
        let u = url, legacy = legacyURL
        Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = Date()
            let saved = Library.readNewest([(u, true), (legacy, false),
                                            (legacy.appendingPathExtension("bak"), false)])
            let readTime = Date().timeIntervalSince(t0)
            await MainActor.run { self?.note("Read saved library", seconds: readTime); self?.finishLoading(saved) }
        }
    }

    private enum ReadResult { case none, loaded(Saved, from: URL), failed(blockSaves: Bool) }

    /// Reads the most recently written of the saved copies that decodes; older ones are tried if it doesn't.
    nonisolated private static func readNewest(_ files: [(URL, Bool)]) -> ReadResult {
        func modified(_ u: URL) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast
        }
        let present = files.filter { FileManager.default.fileExists(atPath: $0.0.path) }
            .sorted { modified($0.0) > modified($1.0) }
        guard !present.isEmpty else { return .none }
        for f in present {
            switch readSaved(f.0, binary: f.1) {
            case .loaded(let s, let u): return .loaded(s, from: u)
            // Couldn't open the newest copy just now: don't fall back to an older one (it would be saved over it).
            case .failed(blockSaves: true): return .failed(blockSaves: true)
            // Damaged (moved aside, kept): try the next newest.
            case .failed(blockSaves: false), .none: continue
            }
        }
        return .failed(blockSaves: false)
    }
    nonisolated private static func readSaved(_ u: URL, binary: Bool) -> ReadResult {
        guard FileManager.default.fileExists(atPath: u.path) else { return .none }
        // Couldn't read the file this time (it may be briefly unavailable): leave it, and don't save over it.
        guard let data = try? Data(contentsOf: u, options: .mappedIfSafe) else { return .failed(blockSaves: true) }
        let decoded: Saved? = autoreleasepool {
            if binary { return try? PropertyListDecoder().decode(Saved.self, from: data) }
            return try? JSONDecoder().decode(Saved.self, from: data)
        }
        guard let s = decoded else {
            // Damaged: keep it aside rather than letting the next save overwrite it with an empty library.
            let aside = u.deletingLastPathComponent().appendingPathComponent("scores-unreadable-\(Int(Date().timeIntervalSince1970)).\(binary ? "plist" : "json")")
            let moved = (try? FileManager.default.moveItem(at: u, to: aside)) != nil
            return .failed(blockSaves: !moved)
        }
        return .loaded(s, from: u)
    }
    /// Set when the saved library couldn't be read this time: nothing is saved over it until the app opens again.
    private var savesBlocked = false

    private func finishLoading(_ result: ReadResult) {
        let t0 = Date()
        var hadSaved = false, failedBlock: Bool? = nil
        switch result {
        case .loaded(let s, let from):
            load(s); hadSaved = true
            note("Opened from", from.lastPathComponent)
            // The binary file read back fine, so the JSON backup kept from the switch-over isn't needed any more.
            if from == url { try? FileManager.default.removeItem(at: legacyURL.appendingPathExtension("bak")) }
        case .failed(let block): applyLearning(); failedBlock = block   // an unreadable save, kept aside
        case .none: applyLearning()                                     // a fresh install
        }
        note("Apply saved library", seconds: Date().timeIntervalSince(t0))
        // The ranking chosen last time (remembered on its own); Learned by default.
        if let r = UserDefaults.standard.string(forKey: "rankBy") { rankBy = r }
        // Learned is the main ranking: switched to once on this update (you can still pick another in the menu).
        if !UserDefaults.standard.bool(forKey: "learnedPrimary") {
            UserDefaults.standard.set(true, forKey: "learnedPrimary")
            rankBy = "learned"
            UserDefaults.standard.set("learned", forKey: "rankBy")
        }
        // Work out every photo's scores off the main thread first, so the first ranking is quick.
        prewarmDerived { [weak self] in self?.finishLoadingRanked(hadSaved: hadSaved, failedBlock: failedBlock) }
    }

    private func finishLoadingRanked(hadSaved: Bool, failedBlock: Bool?) {
        let t1 = Date()
        rebuild()
        note("First ranking", seconds: Date().timeIntervalSince(t1))
        if let block = failedBlock { hadSavedData = true; savesBlocked = block }
        if hadSaved { hadSavedData = true }
        // Before Who's Who asked for consent: anyone who already named people keeps it on; otherwise no face
        // prints are kept until it's turned on.
        var deletePending = false
        if UserDefaults.standard.object(forKey: "faceConsent") == nil {
            if !people.isEmpty {
                // People were named before consent was asked: Who's Who stays on.
                UserDefaults.standard.set(true, forKey: "faceConsent")
                whoCache = [:]; rebuild()
            } else {
                if photos.values.contains(where: { $0.faceRecords != nil }) { deleteFacePrints() }
                deletePending = true
            }
        }
        ready = true
        // "Off" is written only once the deletion is saved (if the app is ended first, it's done again next time).
        if deletePending {
            save { if UserDefaults.standard.object(forKey: "faceConsent") == nil { UserDefaults.standard.set(false, forKey: "faceConsent") } }
        }
        let handlers = readyHandlers; readyHandlers = []
        handlers.forEach { $0() }
        noteMemory()
        // The rest waits a moment and runs one thing at a time, each after the last finishes, so opening the
        // app never piles up work (or memory).
        staggered([{ lib in
            lib.retrain {
                lib.learnPeople()
                if !lib.claudeBatches.isEmpty { Task { await Shared.claude.collect(lib) } }
            }
        }])
    }

    // MARK: Diagnostics (shown in Settings, so a slow or closing app can be looked into without a crash log)

    struct Diagnostic: Identifiable { var label: String; var value: String; var id: String { label } }
    private(set) var diagnostics: [Diagnostic] = []   // not published: updating it mustn't redraw the app
    func note(_ label: String, seconds: Double) { note(label, String(format: "%.1f s", seconds)) }
    func note(_ label: String, _ value: String) {
        if let i = diagnostics.firstIndex(where: { $0.label == label }) { diagnostics[i].value = value }
        else { diagnostics.append(Diagnostic(label: label, value: value)) }
    }
    /// The app's current memory use, as iOS counts it toward its limit.
    func noteMemory() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard r == KERN_SUCCESS else { return }
        let used = ByteCountFormatter.string(fromByteCount: Int64(info.phys_footprint), countStyle: .memory)
        note("Memory in use", used)
        if info.limit_bytes_remaining > 0 {
            note("Memory left before iOS's limit", ByteCountFormatter.string(fromByteCount: Int64(info.limit_bytes_remaining), countStyle: .memory))
        }
    }

    /// Runs each step a couple of seconds after the last, on the main thread.
    private func staggered(_ steps: [(Library) -> Void], gap: Double = 2) {
        Task { @MainActor [weak self] in
            for step in steps {
                try? await Task.sleep(for: .seconds(gap))
                guard let self else { return }
                step(self)
            }
        }
    }

    /// Fills the per-photo cache (decoded measurements, learned score, removal check, balanced score) off the
    /// main thread, then calls `then` on the main thread.
    private func prewarmDerived(then: @escaping () -> Void) {
        let snapshot = Array(photos.values), model = learned, filter = learnedFilter, epoch = learningEpoch, likes = taste
        let t0 = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            var out: [String: Derived] = [:]
            out.reserveCapacity(snapshot.count)
            for p in snapshot {
                guard let f = p.feat, let x = Learner.decode(f) else { continue }
                out[p.id] = Library.derive(p, f, x, model: model, filter: filter, taste: likes, epoch: epoch)
            }
            let took = Date().timeIntervalSince(t0)
            let result = out
            await MainActor.run {
                guard let self else { return }
                if self.learningEpoch == epoch { self.derived.merge(result) { _, new in new } }
                self.note("Scores worked out (\(result.count.formatted()) photos)", seconds: took)
                then()
            }
        }
    }

    /// New results from the scanner. The list is re-ranked at most every 30 seconds while scanning.
    func add(_ new: [PhotoScore]) {
        guard !new.isEmpty else { return }
        // A photo whose faces couldn't be read this time keeps its earlier face prints (and is read again later).
        let new = new.map { p -> PhotoScore in
            var p = p
            if Library.faceConsent, p.faceRecords == nil, p.facePrintsOff != true,
               let old = photos[p.id]?.faceRecords { p.faceRecords = old }
            return p
        }
        for p in new {
            whoCache[p.id] = nil
            // Only when the faces themselves changed; otherwise who's in the photo stays put during a rescan.
            guard let old = photos[p.id], old.faceRecords != p.faceRecords else { continue }
            carryOverFaces(p.id, from: old.faceRecords ?? [], to: p.faceRecords ?? [])
            facesChangedDuringPass.insert(p.id)
            for j in 0..<(old.faceRecords?.count ?? 0) { learnedFaces.remove(p.id + "#\(j)") }
            learnedWho[p.id] = nil
            learnedPhotos.remove(p.id)   // its faces changed: worked out again on the next learning pass
        }
        for var p in new {
            // A scan that started before Who's Who was turned off can still hand over face prints: drop them.
            if !Library.faceConsent, p.faceRecords != nil { p.faceRecords = nil; p.facePrintsOff = true }
            if p.claude == nil { p.claude = photos[p.id]?.claude }   // a rescan never throws away Claude's verdict
            // Keep the old fingerprint only if it's still the current size (an old-size one would be re-read forever).
            if p.feat == nil, let old = photos[p.id]?.feat, old.count == Learner.featureCount { p.feat = old }
            if photos[p.id]?.privacyHold == true || Scorer.heldBack.contains(photos[p.id]?.excluded ?? "") && p.excluded != photos[p.id]?.excluded {
                p.privacyHold = true                                  // a never-send hold is never lifted by a re-read
            }
            photos[p.id] = p
        }
        unsaved += new.count
        // Re-ranking everything is costly, so it's occasional while scanning (but right away for the very first
        // results, so a new install doesn't sit empty).
        let since = Date().timeIntervalSince(lastRebuild)
        if (moments.isEmpty && since > 3) || since > 30 { rebuild() }
        // The whole library is rewritten on each save, so while scanning save at most every 2 minutes (iOS limits
        // how much an app writes); the end of a scan, closing the app and background time always save.
        if unsaved >= 200 && Date().timeIntervalSince(lastSave) > 120 { save() }
    }

    /// A photo's faces were read again (for example with the new face recognizer): what you said about each face —
    /// your tags, "not them", set aside, skipped — moves to the same face in the new reading (matched by where it is).
    private func carryOverFaces(_ photo: String, from old: [FaceRecord], to new: [FaceRecord]) {
        guard !old.isEmpty, !new.isEmpty else { return }
        func rect(_ b: [Float]) -> CGRect { b.count == 4 ? CGRect(x: CGFloat(b[0]), y: CGFloat(b[1]), width: CGFloat(b[2]), height: CGFloat(b[3])) : .null }
        var taken = Set<Int>()
        for o in old {
            let ok = Library.faceKey(photo, o)
            guard confirmedFaces[ok] != nil || notThem[ok] != nil || ignoredFaces.contains(ok) || skippedFaces.contains(ok) else { continue }
            let scored = new.indices.filter { !taken.contains($0) }.map { ($0, FaceID.overlap(rect(o.box), rect(new[$0].box))) }
            guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.4 else { continue }
            taken.insert(best.0)
            let nk = Library.faceKey(photo, new[best.0])
            guard nk != ok else { continue }
            if let id = confirmedFaces.removeValue(forKey: ok) { confirmedFaces[nk] = id }
            if let r = notThem.removeValue(forKey: ok) { notThem[nk, default: []].formUnion(r) }
            if ignoredFaces.remove(ok) != nil { ignoredFaces.insert(nk) }
            if skippedFaces.remove(ok) != nil { skippedFaces.insert(nk) }
            if let id = faceOwner.removeValue(forKey: ok) { faceOwner[nk] = id }
        }
    }

    /// After a scan: re-rank now, then save, re-check the learning and update Who's Who a few seconds apart
    /// (all at once could push a large library past iOS's memory limit).
    func finishScan() {
        rebuild()
        // Each step starts only after the one before has finished (a save is written off the main thread).
        staggered([{ lib in
            lib.save {
                Task { @MainActor in
                    Shared.library.retrain { Shared.library.learnPeople(); Shared.library.noteMemory() }
                }
            }
        }], gap: 1)
    }

    /// Removes a whole moment (every shot in its burst) from the list.
    func hide(_ m: Moment) {
        hidden.formUnion(m.memberIDs); lastHidden = m.memberIDs; addedBack.subtract(m.memberIDs); rebuild(); saveSoon()
        UIAccessibility.post(notification: .announcement, argument: "Removed from list. Undo is available.")
    }
    /// Undo for "Remove from list".
    func unhide(_ ids: [String]) { hidden.subtract(ids); lastHidden = []; rebuild(); saveSoon() }
    /// The moment just removed (Home offers to undo it for a few seconds).
    @Published private(set) var lastHidden: [String] = []
    func forgetLastHidden() { lastHidden = [] }

    /// Saves a moment later, once things settle (several quick changes become one save).
    private var saveTask: Task<Void, Never>?
    func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
    func restoreHidden() { hidden.removeAll(); rebuild(); save() }

    func setBirthdays(_ dates: [Date]) { birthdays = dates.sorted(); rebuild(); save() }

    // MARK: Claude

    func setClaude(model: String? = nil, scope: Int? = nil) {
        if let model { claudeModel = model }
        if let scope { claudeScope = scope }
        recountClaude()
        save()
    }
    /// How many photos would go to Claude now, and how many can be re-checked (Settings shows these; worked out
    /// when they can change, not on every redraw).
    @Published private(set) var claudeToSend = 0
    @Published private(set) var claudeRecheckable = 0
    func recountClaude() {
        let n = Shared.claude.candidates(self).count, r = Shared.claude.recheckCandidates(self).count
        if n != claudeToSend { claudeToSend = n }
        if r != claudeRecheckable { claudeRecheckable = r }
    }
    /// How many of each ranking's best moments per year go into Consolidated.
    nonisolated static let consolidatedTop = 100
    /// Switching the ranking only re-ranks: the choice is remembered on its own, without rewriting the whole
    /// library (a full save on every switch, on top of a scan, could push a large library past iOS's memory limit).
    func setRankBy(_ v: String) {
        guard v != rankBy else { return }
        rankBy = v
        UserDefaults.standard.set(v, forKey: "rankBy")
        rebuild()
    }
    /// Photos Claude never returned a score for (batch lost, expired or errored): they can be sent again.
    func unsend(model: String, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        claudeSent[model]?.subtract(ids)
        recountClaude()
        save()
    }
    func addClaudeBatch(_ b: ClaudeBatch) {
        claudeBatches.append(b)
        claudeSent[b.model, default: []].formUnion(b.photos.values)
        for id in b.photos.values where claudeSentYear[id] == nil {
            if let d = photos[id]?.date { claudeSentYear[id] = Calendar.current.component(.year, from: d) }
        }
        recountClaude()
        flush()
    }
    /// Fast mode: photos Claude answered (scored or failed), recorded like a batch so they aren't sent again.
    func markClaudeSent(model: String, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        claudeSent[model, default: []].formUnion(ids)
        for id in ids where claudeSentYear[id] == nil {
            if let d = photos[id]?.date { claudeSentYear[id] = Calendar.current.component(.year, from: d) }
        }
    }
    func removeClaudeBatch(_ id: String) { claudeBatches.removeAll { $0.id == id }; recountClaude(); save() }
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
        rebuild(); saveNowIfAway()
        retrain()
    }
    /// Saves in the background while the app is open (waiting for the write made the screen stall); if the app is
    /// already in the background, waits for the write, so iOS can't pause the app before Claude's scores are kept.
    func saveNowIfAway() {
        if UIApplication.shared.applicationState == .background { flush() } else { save() }
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
        recordClaude(verdicts)
        refreshAfterClaude()
    }
    /// Stores Claude's scores right away (so those photos are never offered or billed again, and a save soon
    /// keeps them), without re-ranking yet: fast scoring calls this for every group and re-ranks every ~100.
    func recordClaude(_ verdicts: [String: ClaudeVerdict]) {
        guard !verdicts.isEmpty else { return }
        for (id, v) in verdicts {
            photos[id]?.claude = v
            if let e = v.exclude { claudeRemoved[id] = e }
        }
        if UIApplication.shared.applicationState == .background { flush() } else { saveSoon() }
    }
    /// Re-ranks with the scores recorded so far, saves, and learns from them.
    func refreshAfterClaude() {
        rebuild(); saveNowIfAway()
        retrain()
    }

    // MARK: Learned score

    /// The app's model of Claude's scoring, learned from the photos Claude has scored.
    @Published private(set) var learned: LearnedModel?
    @Published private(set) var training = false
    /// The app's model of Claude's removals, and how many unseen photos it's keeping off the list right now.
    @Published private(set) var learnedFilter: LearnedFilter?
    /// What "Learn my Likes" learned from your thumbs up and down (nudges every learned score; see Learner.trainTaste).
    @Published private(set) var taste: TasteModel?
    /// Photos you've given a thumbs up or down that can be learned from.
    var votesCount: Int { reactions.keys.filter { photos[$0]?.feat != nil }.count }
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
    func setUseBuiltInLearning(_ v: Bool) {
        useBuiltInLearning = v; applyLearning()
        prewarmDerived { [weak self] in self?.rebuild(); self?.save() }
    }

    /// This phone's own learning as text (for building into the app); nil until it has learned something.
    var learningText: String? {
        ownModel == nil && ownFilter == nil ? nil : LearningPack(model: ownModel, filter: ownFilter).text()
    }
    /// Photos whose Claude result could be shared as learning data. Bath and undressed photos are never shared.
    private static func shareable(_ p: PhotoScore) -> Bool {
        guard let c = p.claude, let f = p.feat, f.count == Learner.featureCount else { return false }
        return c.exclude != "bath" && c.exclude != "undressed"
    }
    /// How many Claude results this phone could share as learning data.
    var shareableLearningCount: Int { photos.values.filter(Library.shareable).count }

    /// Writes this phone's learning data to a file to send to the app's owner, so the learning built into the app
    /// can be trained on many families' results. For each photo Claude judged: the phone's numeric fingerprint of it
    /// with the face picture and face-shape measurements blanked (they could match a child's face), Claude's score,
    /// whether Claude removed it, and which day group it's in (random numbers, so dates and their order can't be
    /// read back). No photos, photo ids, captions, names, face prints, places or dates. Bath and undressed photos
    /// are left out. Built off the main thread; nil if there's nothing to share or the file can't be written.
    func writeLearningData() async -> URL? {
        let scored = photos.values.filter(Library.shareable)
        guard !scored.isEmpty else { return nil }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            // Training only needs to know which photos share a day (so it checks itself on days it didn't learn
            // from); each day becomes a random number.
            var dayToken: [UInt64: Int] = [:]
            var used = Set<Int>()
            func token(_ d: Date) -> Int {
                let g = Learner.group(d)
                if let t = dayToken[g] { return t }
                var t = Int.random(in: 1...Int(Int32.max))
                while used.contains(t) { t = Int.random(in: 1...Int(Int32.max)) }
                used.insert(t); dayToken[g] = t
                return t
            }
            let faceStart = Learner.signalCount + Learner.sceneDims
            let blank = Array(15..<21) + Array(faceStart..<(faceStart + Learner.faceDims))   // face shape, face picture
            var rows: [[String: Any]] = []
            for p in scored.shuffled() {                      // shuffled: the order says nothing about the library
                guard let c = p.claude, var f = p.feat else { continue }
                for i in blank { f[f.startIndex + i] = 0 }    // zero = "no face", the same as a photo without one
                var r: [String: Any] = ["f": f.base64EncodedString(), "g": token(p.date), "m": c.model, "rubric": c.rubric, "r": c.exclude != nil]
                if c.exclude == nil {
                    r["s"] = c.score2.map { (c.score + $0) / 2 } ?? c.score
                    if c.score2 != nil { r["two"] = true }
                }
                rows.append(r)
            }
            guard !rows.isEmpty else { return nil }
            let obj: [String: Any] = ["kind": "awwbum-learning-data", "version": 1, "featureCount": Learner.featureCount,
                                      "faceBlanked": true, "build": build, "count": rows.count, "examples": rows]
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Awwbum learning data.json")
            do { try data.write(to: url, options: [.atomic, .completeFileProtection]); return url } catch { return nil }
        }.value
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
        learningEpoch += 1   // cached predictions are stale
    }
    /// Throws away this phone's own learning and learns again from every Claude verdict on hand.
    func relearn() {
        ownModel = nil; ownFilter = nil; trainedSignature = nil; generation += 1
        applyLearning(); rebuild(); save()
        retrain()
    }

    /// Claude scores that have a fingerprint to learn from.


    /// Per-photo results worked out from its saved measurements, kept between rebuilds (a rebuild every few seconds
    /// while scanning used to decode and score every photo again). Valid while the photo's measurements and the
    /// learning in use are unchanged.
    private struct Derived { var feat: Data; var epoch: Int; var special: Double; var learned: Double?; var removes: Bool; var balanced: Double }
    private var derived: [String: Derived] = [:]
    private var learningEpoch = 0

    private func derivedFor(_ p: PhotoScore) -> Derived? {
        guard let f = p.feat else { return nil }
        let sp = p.special ?? Scorer.specialFromCaption(p.caption)   // a new caption can change this without new measurements
        if let d = derived[p.id], d.epoch == learningEpoch, d.special == sp, d.feat == f { return d }
        guard let x = Learner.decode(f) else { return nil }
        let d = Library.derive(p, f, x, model: learned, filter: learnedFilter, taste: taste, epoch: learningEpoch)
        derived[p.id] = d
        return d
    }

    nonisolated private static func derive(_ p: PhotoScore, _ f: Data, _ x: [Double], model: LearnedModel?,
                                           filter: LearnedFilter?, taste: TasteModel?, epoch: Int) -> Derived {
        let sp = p.special ?? Scorer.specialFromCaption(p.caption)
        // Learn my Likes moves it up to half a point toward what you like.
        let learnedV = model.map { m -> Double in
            let v = max(1, min(10, Learner.predict(m, x) + Learner.tasteNudge(taste, x)))
            return (v * 10).rounded(.toNearestOrAwayFromZero) / 10
        }
        let removes = filter.map { $0.useful && Learner.removalChance($0, x) >= Learner.removeAt } ?? false
        return Derived(feat: f, epoch: epoch, special: sp, learned: learnedV, removes: removes,
                       balanced: Scorer.balanced(x, special: sp))
    }

    /// True when the learned filter expects Claude would take this photo off the list.
    func learnedRemoves(_ p: PhotoScore) -> Bool { derivedFor(p)?.removes ?? false }

    func learnedScore(for p: PhotoScore) -> Double? { derivedFor(p)?.learned }

    /// The balanced on-device score (see Scorer.balanced), for a listed photo with current measurements.
    private func balancedValue(_ p: PhotoScore, putBack: Set<String>, includePoolOnly: Bool = false, manual: Set<String> = []) -> Double? {
        guard Scorer.listedValue(p, putBack: putBack, includePoolOnly: includePoolOnly, manual: manual) != nil else { return nil }
        return derivedFor(p)?.balanced
    }

    /// Re-learns from every Claude verdict (off the main thread; up to about half a minute for thousands of scores). Runs after new verdicts
    /// arrive and after a scan adds fingerprints; skipped when nothing changed since the last run (even across launches).
    private var pendingRetrain = false
    private var trainedSignature: UInt64?
    /// The votes Learn my Likes last learned from (worked out again once per launch; it's quick).
    private var tasteSignature: UInt64?
    /// Bumped by "Go back to on-device scores only", so a training run that started before it is ignored.
    private var generation = 0

    func retrain() {
        guard !retrainBusy else { pendingRetrain = true; return }   // run again once the current one finishes
        retrainBusy = true
        let gen = generation
        let known = trainedSignature, knownLikes = tasteSignature, hadTaste = taste != nil
        let reacts = reactions
        let scored = photos.values.filter { $0.claude != nil && $0.feat != nil }   // only these are needed
        let voted = photos.values.filter { reacts[$0.id] != nil && $0.feat != nil }   // for Learn my Likes
        // Gathering the examples (decoding thousands of fingerprints) happens off the main thread too.
        Task.detached(priority: .utility) {
            var parts: [String] = []
            var examples: [(date: Date, x: [Double], y: Double)] = []
            var verdicts: [(date: Date, x: [Double], removed: Bool)] = []
            var averaged = 0
            for p in scored.sorted(by: { $0.id < $1.id }) {
                guard let f = p.feat, let x = Learner.decode(f) else { continue }
                guard let c = p.claude else { continue }
                // Your thumbs nudge what it learns: a quarter point above Claude's score (up), half a point below (down).
                if let r = reacts[p.id], c.exclude == nil {
                    let base = c.score2.map { (c.score + $0) / 2 } ?? c.score
                    parts.append("\(p.id)|r\(r)v5|\(c.score)|\(c.score2 ?? -1)")
                    verdicts.append((p.date, x, false))
                    examples.append((p.date, x, min(10, max(1, base + Library.thumbNudge(r)))))
                    if c.score2 != nil { averaged += 1 }
                    continue
                }
                parts.append("\(p.id)|\(c.score)|\(c.score2 ?? -1)|\(c.exclude ?? "")")
                verdicts.append((p.date, x, c.exclude != nil))
                // Where Claude scored a photo twice, learn from the average (closer to its real opinion).
                if c.exclude == nil { examples.append((p.date, x, c.score2.map { (c.score + $0) / 2 } ?? c.score)) }
                if c.exclude == nil && c.score2 != nil { averaged += 1 }
            }
            // Learn my Likes: every photo you voted on, Claude-scored or not.
            var votes: [(date: Date, x: [Double], vote: Int)] = [], likeParts: [String] = []
            for p in voted.sorted(by: { $0.id < $1.id }) {
                guard let f = p.feat, let x = Learner.decode(f), let r = reacts[p.id], r != 0 else { continue }
                likeParts.append("\(p.id)|\(r)")
                votes.append((p.date, x, r > 0 ? 1 : -1))
            }
            let signature = Learner.stableHash(parts), likeSignature = Learner.stableHash(likeParts)
            let claudeChanged = signature != known
            // Too few votes to learn from, and nothing learned before: just note them (no "Learning…", no re-rank).
            let tooFew = votes.count < Learner.minimumVotes
            let likesChanged = likeSignature != knownLikes && !(tooFew && !hadTaste)
            if !claudeChanged && !likesChanged {                // nothing new to learn from (also across launches)
                await MainActor.run {
                    if likeSignature != knownLikes { self.tasteSignature = likeSignature }
                    self.retrainBusy = false
                    if self.pendingRetrain { self.pendingRetrain = false; self.retrain() } else { self.retrainFinished() }
                }
                return
            }
            await MainActor.run { self.training = true }      // shown in Settings only while really learning
            // Only what changed is learned again (votes alone don't re-learn Claude's scoring).
            let model = claudeChanged ? Learner.train(examples, averaged: averaged) : nil
            let filter = claudeChanged ? Learner.trainFilter(verdicts) : nil
            let likes = likesChanged ? Learner.trainTaste(votes) : nil
            await MainActor.run {
                self.training = false
                guard gen == self.generation else {          // cleared while this was running: start over
                    self.retrainBusy = false
                    self.pendingRetrain = false; self.retrain(); return
                }
                // This phone's own learning is always kept (and can be copied out); it's used once it has learned
                // from at least as many verdicts as the built-in one, or right away if the built-in one is turned off.
                if claudeChanged { self.trainedSignature = signature; self.ownModel = model; self.ownFilter = filter }
                if likesChanged { self.tasteSignature = likeSignature; self.taste = likes }
                self.applyLearning()
                // New learning changes every photo's learned score: work those out off the main thread first, so
                // the re-rank that follows doesn't stall the screen.
                self.prewarmDerived {
                    self.retrainBusy = false   // busy until here, so a second training can't start mid-way
                    self.rebuild()
                    if self.pendingRetrain { self.pendingRetrain = false; self.save(); self.retrain() }
                    else { self.save { Task { @MainActor in Shared.library.retrainFinished() } } }   // next step after the save
                }
            }
        }
    }
    private var retrainBusy = false
    private var afterRetrain: [() -> Void] = []
    /// Runs `then` once the learning check (and any training it starts) has finished.
    func retrain(then: @escaping () -> Void) { afterRetrain.append(then); retrain() }
    private func retrainFinished() { let h = afterRetrain; afterRetrain = []; h.forEach { $0() } }
    func clearClaude() {
        for id in photos.keys where photos[id]?.claude != nil { photos[id]?.claude = nil }
        claudeBatches = []
        claudeSent = [:]   // starting over: each year's budget is available again (removals are kept, never re-sent)
        ownModel = nil; ownFilter = nil; trainedSignature = nil; generation += 1
        applyLearning()
        if rankBy != "learned" { rankBy = "learned"; UserDefaults.standard.set("learned", forKey: "rankBy") }   // falls back to Apple without learning
        rebuild(); save()
    }
    /// Worked out once per re-rank (screens read these on every redraw; counting thousands of moments each time
    /// made scrolling the full list stutter).
    private(set) var claudeScored = 0
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
        strictness = v; learnedFaces = []; whoCache = [:]; rebuild(); save(); learnPeople()
    }

    /// Who's in each photo (photo id → people), worked out off the main thread from the faces you named:
    /// ordinary matches plus the faces the app learned (see People.learn). Not saved; worked out again at launch.
    private(set) var learnedWho: [String: Set<UUID>] = [:]
    /// Who's in each photo, cached between rebuilds (cleared whenever names or learning change).
    private var whoCache: [String: Set<UUID>] = [:]
    /// True once Who's Who has worked out every face since launch (then only its answers say who is in a photo).
    private var peopleLearned = false
    /// The photos the last learning pass worked out (new or rescanned photos aren't in it until the next pass).
    private var learnedPhotos = Set<String>()
    /// Photos whose faces were read again while a learning pass was running (its answer for them is out of date).
    private var facesChangedDuringPass = Set<String>()
    /// Faces (photo id # face number) already known to be someone, so Who's Who doesn't ask about them.
    private var learnedFaces = Set<String>()
    @Published private(set) var learningPeople = false
    /// Faces that might be each named person but weren't sure enough to count (Who's Who → Review faces).
    @Published private(set) var reviewFaces: [UUID: [(photo: String, face: FaceRecord)]] = [:]

    /// Applies a round of Review faces at once: the yeses are named as the person, the nos never count as them.
    func applyReview(person: Person, yes: [(photo: String, face: FaceRecord)], no: [(photo: String, face: FaceRecord)]) {
        guard let p = people.first(where: { $0.id == person.id }) else { return }
        let decided = Set((yes + no).map { Library.faceKey($0.photo, $0.face) })
        reviewFaces[p.id]?.removeAll { decided.contains(Library.faceKey($0.photo, $0.face)) }
        if !no.isEmpty { rejectFaces(no, for: p) }
        if !yes.isEmpty { name(yes, as: p.name, birthday: nil) }
    }

    /// Faces found in the photos you can see: how many have a name, how many you set aside, and how many don't yet.
    struct FaceTally: Equatable { var total = 0, named = 0, setAside = 0; var unidentified: Int { total - named - setAside } }
    @Published private(set) var faceTally = FaceTally()
    func updateFaceTally() {
        var t = FaceTally()
        guard Library.faceConsent else { faceTally = t; return }
        for p in photos.values where !notVisible.contains(p.id) {
            for f in p.faceRecords ?? [] where f.vec.count == People.dim {
                t.total += 1
                let k = Library.faceKey(p.id, f)
                if faceOwner[k] != nil { t.named += 1 } else if ignoredFaces.contains(k) { t.setAside += 1 }
            }
        }
        faceTally = t
    }

    /// Which named person each face is (face key → person), from the last learning pass and your naming.
    @Published private(set) var faceOwner: [String: UUID] = [:]
    /// Faces you skipped in Review faces (not asked about again; they can still be named in Who is this?).
    private(set) var skippedFaces = Set<String>()
    func skipFace(_ photo: String, _ face: FaceRecord) {
        skippedFaces.insert(Library.faceKey(photo, face)); saveSoon()
    }
    /// Faces you named or confirmed yourself (face key → person): always that person, never asked about again.
    private(set) var confirmedFaces: [String: UUID] = [:]
    /// Faces you said aren't someone (face key → people), so they're never counted as them again.
    private(set) var notThem: [String: Set<UUID>] = [:]
    /// Faces you removed from "Who is this?" (strangers and the like), so they aren't asked about again.
    private(set) var ignoredFaces = Set<String>()

    /// A face's lasting key: its photo and where it sits in it (stays the same when the photo is read again).
    nonisolated static func faceKey(_ photo: String, _ f: FaceRecord) -> String {
        var h: UInt64 = 14695981039346656037   // FNV-1a over the face print, so the key survives small box changes
        for b in f.vec { h = (h ^ UInt64(b)) &* 1099511628211 }
        return photo + "|" + String(h, radix: 36)
    }

    /// The faces counted as this person, newest photo first.
    func faces(of person: Person) -> [(photo: String, face: FaceRecord)] {
        var out: [(photo: String, face: FaceRecord, date: Date)] = []
        for (key, owner) in faceOwner where owner == person.id {
            guard let photo = key.split(separator: "|").first.map(String.init), let p = photos[photo],
                  let f = p.faceRecords?.first(where: { Library.faceKey(photo, $0) == key }) else { continue }
            out.append((photo, f, p.date))
        }
        return out.sorted { $0.date > $1.date }.map { ($0.photo, $0.face) }
    }

    /// "That's not them": this face is never counted as this person again, and it's taken out of what the app
    /// learned about them.
    func removeFace(_ photo: String, _ face: FaceRecord, from person: Person) {
        let key = Library.faceKey(photo, face)
        notThem[key, default: []].insert(person.id)
        if faceOwner[key] == person.id { faceOwner[key] = nil }
        if let i = people.firstIndex(where: { $0.id == person.id }) {
            lastFaceRemoval = (key, people[i], confirmedFaces[key] == person.id)   // so Undo puts everything back as it was
            if confirmedFaces[key] == person.id { confirmedFaces[key] = nil }
            if var ex = people[i].examples, let j = ex.firstIndex(of: face.vec) {
                ex.remove(at: j)
                if let n = people[i].namedExamples, j < n { people[i].namedExamples = n - 1 }
                people[i].examples = ex
                if !ex.isEmpty {
                    people[i].centroid = People.merged([], count: 0, adding: ex.map { People.floats($0) })
                    people[i].count = max(1, people[i].count - 1)
                }
            }
            // Its picture: another of their faces, if this was the one shown.
            if people[i].samplePhoto == photo,
               let other = faceOwner.first(where: { $0.value == person.id }),
               let ph = other.key.split(separator: "|").first.map(String.init),
               let f = photos[ph]?.faceRecords?.first(where: { Library.faceKey(ph, $0) == other.key }) {
                people[i].samplePhoto = ph; people[i].sampleBox = f.box
            }
        }
        // Still them if another face in the photo is.
        if !faceOwner.contains(where: { $0.value == person.id && $0.key.hasPrefix(photo + "|") }) {
            learnedWho[photo]?.remove(person.id)
        }
        whoCache = [:]; rebuildSoon(); saveSoon(); learnPeople()
    }
    /// "These aren't them": faces taken out of a quick check, never counted (or suggested) as this person.
    func rejectFaces(_ faces: [(photo: String, face: FaceRecord)], for person: Person) {
        guard !faces.isEmpty else { return }
        for f in faces {
            let k = Library.faceKey(f.photo, f.face)
            notThem[k, default: []].insert(person.id)
            if confirmedFaces[k] == person.id { confirmedFaces[k] = nil }
        }
        whoCache = [:]; saveSoon(); learnPeople()
    }
    /// Undoes a tag: the face is no longer counted as them, and it isn't marked "not them" either (just untagged).
    func untagFace(_ photo: String, _ face: FaceRecord, from person: Person) {
        removeFace(photo, face, from: person)
        let key = Library.faceKey(photo, face)
        notThem[key]?.remove(person.id)
        if notThem[key]?.isEmpty == true { notThem[key] = nil }
        lastFaceRemoval = nil
        learnPeople()   // again, now without the "not them"
    }
    /// Undoes "that's not them" for one face (it can be counted as them again).
    func restoreFace(_ photo: String, _ face: FaceRecord, to person: Person) {
        let key = Library.faceKey(photo, face)
        notThem[key]?.remove(person.id)
        if notThem[key]?.isEmpty == true { notThem[key] = nil }
        // Undoing the latest removal also brings back what it took out of their learned faces and picture.
        if let last = lastFaceRemoval, last.key == key, last.person.id == person.id,
           let i = people.firstIndex(where: { $0.id == person.id }) {
            people[i].examples = last.person.examples; people[i].namedExamples = last.person.namedExamples
            people[i].centroid = last.person.centroid; people[i].count = last.person.count
            people[i].samplePhoto = last.person.samplePhoto; people[i].sampleBox = last.person.sampleBox
            if last.confirmed { confirmedFaces[key] = person.id }
            lastFaceRemoval = nil
        }
        faceOwner[key] = person.id
        learnedWho[photo, default: []].insert(person.id)
        whoCache = [:]; rebuildSoon(); saveSoon(); learnPeople()
    }
    /// Faces you said aren't someone (a copy for work off the main thread).
    var notThemKeys: [String: Set<UUID>] { notThem }
    /// True if you said this face isn't this person.
    func isRejected(_ photo: String, _ face: FaceRecord, for id: UUID) -> Bool {
        notThem[Library.faceKey(photo, face)]?.contains(id) == true
    }

    private var lastFaceRemoval: (key: String, person: Person, confirmed: Bool)?

    /// Takes faces out of "Who is this?" for good (people you don't need to name).
    func ignoreFaces(_ faces: [(photo: String, face: FaceRecord)]) {
        guard !faces.isEmpty else { return }
        for f in faces {
            let k = Library.faceKey(f.photo, f.face)
            if ignoredFaces.insert(k).inserted, faceOwner[k] == nil, faceTally.total > 0 { faceTally.setAside += 1 }
            whoCache[f.photo] = nil
        }
        rebuildSoon(); saveSoon()
    }

    /// "Is this X?" checks answered No this session (person id : group key), so they aren't asked again.
    var declinedChecks = Set<String>()
    private var peopleGeneration = 0
    private var peopleTask: Task<Void, Never>?

    /// Works out who the rest of the faces are from the ones you named (off the main thread), then updates the list.
    /// Who's Who only recognizes people after you agree to it (asked the first time you open Who's Who).
    static var faceConsent: Bool { UserDefaults.standard.bool(forKey: "faceConsent") }

    /// Turns face recognition on or off (Who's Who's consent) and re-sorts who is in each photo.
    func setFaceConsent(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "faceConsent")
        if on {
            // Makes the face prints Who's Who needs (listed photos only), after any scan already running.
            Shared.scanner.whenFinished { [weak self] in if let self { Shared.scanner.start(library: self) } }
        } else {
            learnedWho = [:]; learnedFaces = []   // before the rebuild, so no one stays tagged
            deleteFacePrints()
        }
        whoCache = [:]; rebuild(); save(); learnPeople()
    }

    /// Deletes Who's Who's face prints: from every photo, and each named person's (names and birthdays stay;
    /// naming them again after turning Who's Who back on picks up the same person).
    private func deleteFacePrints() {
        for (id, p) in photos where p.faceRecords != nil || (p.raw != nil && p.facePrintsOff != true) {
            photos[id]?.faceRecords = nil
            photos[id]?.facePrintsOff = true
        }
        for i in people.indices {
            people[i].centroid = []; people[i].count = 0; people[i].examples = nil; people[i].namedExamples = nil
        }
    }

    /// People named before the current recognizer get their average face back from the faces you tagged as them,
    /// and again on each pass while some of those photos are still waiting to be read again (so it doesn't stay
    /// built from the first few).
    private func refreshPersonPrints() {
        var vecs: [UUID: [Data]] = [:], waiting = Set<UUID>()
        for (key, id) in confirmedFaces.sorted(by: { $0.key < $1.key }) {   // same order every time: same result
            guard let photo = key.split(separator: "|").first.map(String.init),
                  let f = photos[photo]?.faceRecords?.first(where: { Library.faceKey(photo, $0) == key }) else { continue }
            if f.vec.count == People.dim { vecs[id, default: []].append(f.vec) } else { waiting.insert(id) }
        }
        for i in people.indices where people[i].centroid.count != People.dim || waiting.contains(people[i].id) {
            guard let v = vecs[people[i].id], !v.isEmpty else { continue }
            let ex = People.spread(v, to: 80)
            if people[i].examples == ex && people[i].centroid.count == People.dim { continue }   // nothing new
            people[i].centroid = People.merged([], count: 0, adding: v.map(People.floats))
            people[i].count = v.count
            people[i].examples = People.spread(v, to: 80); people[i].namedExamples = people[i].examples?.count
        }
    }

    func learnPeople() {
        refreshPersonPrints()
        peopleGeneration += 1
        peopleTask?.cancel()
        guard !people.isEmpty, Library.faceConsent else {
            learnedWho = [:]; learnedFaces = []; whoCache = [:]; reviewFaces = [:]; learningPeople = false
            peopleLearned = true   // no one named (or Who's Who off): no one is in any photo
            updateFaceTally(); return
        }
        let gen = peopleGeneration
        facesChangedDuringPass = []
        let snapshot = photos.values.filter { !notVisible.contains($0.id) }   // not photos that can't be seen now
        let named = people, t = threshold, rejected = notThem, ignoredKeys = ignoredFaces, confirmedKeys = confirmedFaces
        let namedIDs = Set(people.map(\.id))
        learningPeople = true
        peopleTask = Task.detached(priority: .utility) {
            var faces: [[Float]] = [], owners: [String] = [], keys: [String] = [], faceKeys: [String] = []
            var records: [FaceRecord] = [], dates: [Date] = []
            // Faces you tagged whose photo hasn't been read again by the current recognizer yet: still that person.
            var legacy: [(photo: String, key: String, id: UUID)] = []
            for p in snapshot {
                for f in p.faceRecords ?? [] where f.vec.count != People.dim {
                    let k = Library.faceKey(p.id, f)
                    if let id = confirmedKeys[k], namedIDs.contains(id) { legacy.append((p.id, k, id)) }
                }
                for (j, f) in (p.faceRecords ?? []).enumerated() where f.vec.count == People.dim {
                    faces.append(People.floats(f.vec)); owners.append(p.id); keys.append(p.id + "#\(j)"); dates.append(p.date)
                    faceKeys.append(Library.faceKey(p.id, f)); records.append(f)
                }
            }
            var rej: [Int: Set<UUID>] = [:], ign = Set<Int>(), conf: [Int: UUID] = [:]
            for (i, k) in faceKeys.enumerated() {
                if let r = rejected[k] { rej[i] = r }
                if ignoredKeys.contains(k) { ign.insert(i) }
                if let id = confirmedKeys[k], namedIDs.contains(id) { conf[i] = id }
            }
            // Faces named before confirmations were remembered: a face whose print is one you named counts too.
            var namedPrint: [Data: UUID] = [:]
            for p in named { for e in (p.examples ?? []).prefix(p.namedExamples ?? 0) { namedPrint[e] = p.id } }
            var backfill: [String: UUID] = [:]
            if !namedPrint.isEmpty {
                for (i, f) in records.enumerated() where conf[i] == nil && rej[i] == nil {
                    if let id = namedPrint[f.vec] { conf[i] = id; backfill[faceKeys[i]] = id }
                }
            }
            let remembered = backfill
            let (matched, learned, review) = People.learn(faces, people: named, threshold: t, rejected: rej, owners: owners,
                                                          ignored: ign, confirmed: conf, dates: dates)
            if Task.isCancelled { return }
            // Faces to ask about in Review faces: most likely first, at most 100 per person.
            var toReview: [UUID: [(photo: String, face: FaceRecord, chance: Float)]] = [:]
            for (i, r) in review { toReview[r.id, default: []].append((owners[i], records[i], r.chance)) }
            let reviewList = toReview.mapValues { list in
                Array(list.sorted { $0.chance > $1.chance }.prefix(100)).map { (photo: $0.photo, face: $0.face) }
            }
            var who: [String: Set<UUID>] = [:], done = Set<String>(), counts: [UUID: Int] = [:], owner: [String: UUID] = [:]
            // A face you said isn't someone is never counted as them.
            for (i, id) in matched where rejected[faceKeys[i]]?.contains(id) != true {
                who[owners[i], default: []].insert(id); done.insert(keys[i]); owner[faceKeys[i]] = id
            }
            for (i, id) in learned where rejected[faceKeys[i]]?.contains(id) != true {
                who[owners[i], default: []].insert(id); done.insert(keys[i]); counts[id, default: 0] += 1; owner[faceKeys[i]] = id
            }
            for l in legacy { who[l.photo, default: []].insert(l.id); owner[l.key] = l.id }
            let result = who, known = done, learnedCounts = counts, owners2 = owner, worked = Set(snapshot.map(\.id))
            await MainActor.run {
                guard gen == self.peopleGeneration else { return }   // names changed meanwhile: a newer run is coming
                for k in self.people.indices { self.people[k].learnedCount = learnedCounts[self.people[k].id] ?? 0 }
                self.learnedWho = result
                self.learnedFaces = known
                self.faceOwner = owners2
                self.reviewFaces = reviewList
                    .mapValues { list in list.filter { !self.skippedFaces.contains(Library.faceKey($0.photo, $0.face)) } }
                // Faces named before confirmations were saved are remembered for good from now on.
                for (k, id) in remembered where self.confirmedFaces[k] == nil { self.confirmedFaces[k] = id }
                self.whoCache = [:]
                self.learnedPhotos = worked.subtracting(self.facesChangedDuringPass)
                self.peopleLearned = true
                self.learningPeople = false
                self.updateFaceTally()
                self.rebuild(); self.save()
            }
        }
    }

    /// Names a group of faces. Using a name that already exists adds the faces to that person.
    func name(_ faces: [(photo: String, face: FaceRecord)], as rawName: String, birthday: Date?) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Library.faceConsent, !name.isEmpty, let first = faces.first else { return }
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
            for f in faces {   // naming a face as someone overrides an earlier "not them", and is remembered for good
                let k = Library.faceKey(f.photo, f.face)
                notThem[k]?.remove(id); faceOwner[k] = id; confirmedFaces[k] = id
            }
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
        confirmedFaces = confirmedFaces.filter { $0.value != person.id }
        whoCache = [:]; rebuild(); save(); learnPeople()
    }

    /// Faces in ranked photos that don't match anyone named yet (largest faces of the best moments first).
    func unnamedFaces(limit: Int = 2500) -> [(photo: String, face: FaceRecord)] {
        guard Library.faceConsent else { return [] }
        var out: [(photo: String, face: FaceRecord)] = []
        let t = threshold
        let centroids = People.Matcher(people.map { p -> Person in var p = p; p.examples = nil; return p })
        for m in everyMoment {
            for (j, f) in (m.best.faceRecords ?? []).enumerated() where f.vec.count == People.dim
                && !learnedFaces.contains(m.best.id + "#\(j)") {
                let key = Library.faceKey(m.best.id, f)
                guard !ignoredFaces.contains(key), confirmedFaces[key] == nil,
                      centroids.match(People.floats(f.vec), threshold: t).map({ notThem[key]?.contains($0) == true }) ?? true else { continue }
                out.append((m.best.id, f))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Drops scores for photos that were deleted from the library (ids found by the scanner).
    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        ids.forEach { photos[$0] = nil; derived[$0] = nil }
        addedBack.subtract(ids)
        rebuild(); save()
    }

    /// One re-rank shortly, however many changes ask for it in the meantime (quick taps don't each re-rank).
    private var rebuildPending = false
    func rebuildSoon() {
        guard !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.rebuildPending else { return }
            self.rebuild()
        }
    }

    func rebuild() {
        rebuildPending = false
        lastRebuild = Date()
        let started = Date()
        defer { note("Last ranking", seconds: Date().timeIntervalSince(started)) }
        // Results from an older scorer never went through today's filters, so they stay off the list until re-scored,
        // but their bath/swim exclusions still quarantine the shots around them.
        // Apple's flags (no child spotted, water, swimwear, shirtless, AI or edited file) no longer take a photo
        // off the list: it's listed with the score it would have had, and Claude decides. Only possible bath or
        // undressed photos (and the shots around them) are held back, unless the user puts them back.
        let pb = putBack
        // Photos outside a Limited Access selection are kept but left out of the list (see notVisible).
        let seen = notVisible.isEmpty ? Array(photos.values) : photos.values.filter { !notVisible.contains($0.id) }
        let manual = manualAdds
        let groups = Scorer.moments(from: seen, hidden: hidden, version: Scorer.version, putBack: pb, manual: manual)
        let cal = Calendar.current
        // Photos with a current set of saved measurements are ranked by the balanced score; the rest (until they're
        // re-read) by the old one, against each other only, since the two scales don't line up.
        let balancedVals = groups.map { balancedValue($0.best, putBack: pb, manual: manual) }
        let fallbackVals = groups.map { Scorer.rankValue($0.best, putBack: pb, manual: manual) ?? 0 }
        let years = groups.map { cal.component(.year, from: $0.best.date) }
        var scores = Array(repeating: 1, count: groups.count)
        let bIdx = groups.indices.filter { balancedVals[$0] != nil }, fIdx = groups.indices.filter { balancedVals[$0] == nil }
        for (k, v) in zip(bIdx, Scorer.calibrate(bIdx.map { balancedVals[$0]! }, years: bIdx.map { years[$0] },
                                                ceiling: Scorer.balancedCeiling)) { scores[k] = v }
        // Not yet re-read: at most 6, like Apple-only moments in the Claude view (a small group's best isn't a 10).
        for (k, v) in zip(fIdx, Scorer.calibrate(fIdx.map { fallbackVals[$0] }, years: fIdx.map { years[$0] })) { scores[k] = min(v, 6) }
        let rankRaws = groups.indices.map { balancedVals[$0] ?? fallbackVals[$0] }
        let named = people, t = threshold, rejected = notThem
        // Centroids only here (fast, on the main thread); the thorough matching comes from learnPeople.
        let matcher = People.Matcher((Library.faceConsent ? named : []).map { p -> Person in var p = p; p.examples = nil; return p })
        let gregorian = Calendar(identifier: .gregorian)
        // A named person's birthday only sorts photos while they're a child (grown-ups named in Who's Who don't count).
        func childAt(_ birth: Date, _ date: Date) -> Bool {
            birth <= date && (gregorian.dateComponents([.year], from: birth, to: date).year ?? 0) < 13
        }
        func makeMoment(_ g: (best: PhotoScore, shots: Int, ids: [String]), _ s: Int, _ rr: Double = 0) -> Moment {
            let who: Set<UUID>
            if let cached = whoCache[g.best.id] { who = cached }
            else if peopleLearned && learnedPhotos.contains(g.best.id) {
                // Who's Who has worked out every face (your tags first, one person per face and per photo): only
                // those people count, so a look-alike sibling's face isn't pulled in as them.
                who = learnedWho[g.best.id] ?? []
                whoCache[g.best.id] = who
            } else {
                // Until learning finishes after launch: your tags, then a quick look at each person's average face.
                who = Set((g.best.faceRecords ?? []).compactMap { f -> UUID? in
                    let key = Library.faceKey(g.best.id, f)
                    if let id = confirmedFaces[key] { return id }
                    guard !ignoredFaces.contains(key), let id = matcher.match(People.floats(f.vec), threshold: t) else { return nil }
                    // Not someone you said it isn't, nor someone born after the photo was taken.
                    if let b = named.first(where: { $0.id == id })?.birthday, g.best.date < b.addingTimeInterval(-86_400) { return nil }
                    return rejected[key]?.contains(id) == true ? nil : id
                })
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
            m.rankRaw = rr
            return m
        }
        let all = groups.indices.map { makeMoment(groups[$0], scores[$0], rankRaws[$0]) }
        // What can be sent to Claude: every listed moment except any that contains a photo that must never be sent
        // (possible bath/undressed and their sessions, even after a put back; swimwear/shirtless unless allowed).
        // Once the app has learned, it picks what to send Claude by its prediction of Claude's score.
        func poolValue(_ m: Moment) -> Double { m.learnedScore ?? 10 * m.rankRaw }   // once per moment; not-yet-re-read photos (old scale) sort a bit lower
        let forbidden = Scorer.neverSend(Array(photos.values), allowSwimShirtless: claudeSensitive, removed: claudeRemoved)
        neverSend = forbidden
        // Photos with faces but no child label: not listed, but offered to Claude too (Apple's labels miss kids).
        let listedIDs = Set(groups.flatMap(\.ids))
        let poolOnly = Scorer.moments(from: seen, hidden: hidden, version: Scorer.version,
                                      putBack: pb, includePoolOnly: true)
            .filter { g in Scorer.poolOnly.contains(g.best.excluded ?? "") && !g.ids.contains(where: listedIDs.contains) }
            .map { makeMoment($0, 0, balancedValue($0.best, putBack: pb, includePoolOnly: true) ?? Scorer.rankValue($0.best, putBack: pb, includePoolOnly: true) ?? 0) }
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
        let useConsolidated = rankBy == "consolidated"
        let useClaude = anyClaude && rankBy == "claude"
        let useLearned = learned != nil && rankBy == "learned"
        // Consolidated is led by Claude's verdicts like the Claude view: same removals and same learned filter.
        let claudeLed = useClaude || useLearned || (useConsolidated && (anyClaude || learned != nil))
        var filtered = 0
        var filteredIDs = Set<String>()
        // Built up locally and published once at the end: changing the published list item by item made every
        // screen watching it re-filter thousands of moments thousands of times (the app froze and closed).
        var ms: [Moment] = all.compactMap { m in
            var m = m
            // Claude's removal sticks to the whole burst, even if a different shot becomes its best later (unless you
            // added it back yourself).
            // (only when the shot leading the burst is one you added back, so a shot Claude removed never leads it).
            if m.memberIDs.contains(where: { photos[$0]?.claude?.exclude != nil }) && !manual.contains(m.best.id) { return nil }
            if claudeLed && m.best.claude == nil
                && !m.memberIDs.contains(where: manual.contains)   // you added it yourself: never filtered
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
        // Ones Claude kept from the no-child-label group join the list when ranking by Claude, the learned score or Consolidated.
        if claudeLed {
            for var m in poolOnly where m.best.claude?.exclude == nil && !m.memberIDs.contains(where: { photos[$0]?.claude?.exclude != nil }) {
                guard let c = m.best.claude else { continue }
                m.claudeScore = c.score
                m.score = Claude.displayScore(c.score)
                ms.append(m)
            }
        }
        // Same 1–10 spread in every view (about 1 in 20 moments a 9 or 10): when ranking by Claude or by the learned
        // score, the list's score is that score's rank, bucketed like Apple's. The viewer still shows the actual
        // Claude and learned numbers. Moments Claude hasn't seen still top out at 8 (learned) or 6 (Apple only).
        if useClaude || useLearned {
            let vals = ms.map { m -> Double in
                // A sliver of Apple's raw score breaks ties between equal (rounded) values, so a big tie at a bucket
                // edge can't all land in the higher bucket; Apple-only moments sit at 6 or below in both views.
                let appleOnly: Double = Double(min(m.apple, 6))
                var v: Double = appleOnly
                if useClaude {
                    if let c = m.claudeScore { v = c } else if let l = m.learnedScore { v = min(l, 8) }
                } else if let l = m.learnedScore {
                    v = l
                }
                return v + Library.thumbNudge(reaction(m)) + m.rankRaw * 0.001   // your thumbs: +0.25 up, −0.5 down
            }
            let cal = Scorer.calibrate(vals.map { $0 / 10 }, years: ms.map(\.year))
            for i in ms.indices {
                let m = ms[i]
                let cap: Int
                if useClaude { cap = m.claudeScore != nil ? 10 : (m.learnedScore != nil ? 8 : 6) }
                else { cap = m.learnedScore != nil ? 10 : 6 }
                ms[i].score = min(cal[i], cap)
            }
        }
        // Consolidated: each year's top 100 by Claude, by the learned score and by Apple, combined into one list.
        // A moment's place is the sum of 1 / (60 + its rank) over the rankings it's in the top 100 of (reciprocal
        // rank fusion), so moments near the top of all three lead, and one that's only in one list sits lower.
        if !reactions.isEmpty { ms = ms.map { reacted($0) } }
        everyMoment = ms.sorted(by: Library.ranked)
        var outsideTop = Set<String>()
        if useConsolidated {
            // Each ranking covers only the moments it actually scored (no filling in from the others, which would
            // count the same opinion twice).
            let rankers: [(Moment) -> Double?] = [{ $0.apple > 0 ? Double($0.apple) : nil }, { $0.claudeScore }, { $0.learnedScore }]
            var fused = Array(repeating: 0.0, count: ms.count)
            var inTop = Array(repeating: false, count: ms.count)
            for (_, idx) in Dictionary(grouping: ms.indices, by: { ms[$0].year }) {
                for f in rankers {
                    var vals: [Int: Double] = [:]
                    for i in idx { if let v = f(ms[i]) { vals[i] = v } }
                    let order = vals.keys.sorted { a, b in
                        let va = vals[a]!, vb = vals[b]!
                        if va != vb { return va > vb }
                        if ms[a].rankRaw != ms[b].rankRaw { return ms[a].rankRaw > ms[b].rankRaw }
                        return ms[a].best.date < ms[b].best.date
                    }
                    for (r, i) in order.prefix(Library.consolidatedTop).enumerated() {
                        inTop[i] = true
                        fused[i] += 1 / Double(61 + r)
                    }
                }
            }
            // A thumbs up, or a hidden photo you added yourself, always stays.
            let kept = ms.indices.filter { inTop[$0] || reaction(ms[$0]) > 0 || ms[$0].memberIDs.contains(where: manual.contains) }
            for i in ms.indices where !inTop[i] { outsideTop.formUnion(ms[i].memberIDs) }
            let best = Double(rankers.count) / 61   // first in every ranking (only a scale; calibration uses the order)
            // Scored against every moment of the year (the ones left out count as last), so a top-100 moment
            // isn't shown with a low score just because the list is short.
            let cal = Scorer.calibrate(fused.map { $0 / best }, years: ms.map(\.year), ceiling: { _ in 10 })
            ms = kept.map { i in
                var m = ms[i]; m.score = cal[i]; m.consolidated = fused[i]; return m
            }
            if !reactions.isEmpty { ms = ms.map { reacted($0) } }
        }
        // What's left off and why (current photos only; hidden ones are counted separately).
        var counts: [String: [PhotoScore]] = [:]
        var flags: [String: [PhotoScore]] = [:]
        let shown = Set(ms.flatMap(\.memberIDs))
        for p in photos.values where shown.contains(p.id) {
            if let f = p.appleFlag { flags[f, default: []].append(p) }
        }
        for p in photos.values where !shown.contains(p.id) {
            let why: String
            if notVisible.contains(p.id) { why = "Not in your Limited Access selection" }
            else if hidden.contains(p.id) { why = "Removed by you" }
            else if p.version != Scorer.version
                        || (p.excluded == "No child" && p.soft == nil && (p.faces ?? 0) > 0 && (p.flagVersion ?? 0) < 3)
                        || Scorer.needsShirtlessRecheck(p) {
                why = "Waiting to be checked again"
            }
            else if filteredIDs.contains(p.id) { why = "Hidden by the learned filter" }
            else if outsideTop.contains(p.id) { why = "Not in any ranking's top \(Library.consolidatedTop) for its year" }
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
            counts[why, default: []].append(p)
        }
        func photoGroups(_ g: [String: [PhotoScore]]) -> [LeftOut] {
            g.map { LeftOut(reason: $0.key, count: $0.value.count, ids: $0.value.sorted { $0.date > $1.date }.map(\.id)) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.reason < $1.reason }
        }
        leftOut = photoGroups(counts)
        flagged = photoGroups(flags)
        listedPhotos = shown.count
        ms.sort(by: Library.ranked)
        claudeScored = everyMoment.reduce(0) { $0 + ($1.claudeScore != nil ? 1 : 0) }
        heldBackPhotos = seen.filter { $0.raw == nil && Scorer.heldBack.contains($0.excluded ?? "") && $0.version == Scorer.version }
            .sorted { $0.date > $1.date }
        learnableCount = photos.values.reduce(0) { n, p in
            n + (p.claude != nil && p.claude?.exclude == nil && p.feat?.count == Learner.featureCount ? 1 : 0)
        }
        self.years = Array(Set(ms.map(\.year))).sorted(by: >)
        moments = ms
        recountClaude()
    }

    /// Higher score first; then higher raw score; then the earlier photo.
    nonisolated static func ranked(_ a: Moment, _ b: Moment) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if let fa = a.consolidated, let fb = b.consolidated, fa != fb { return fa > fb }
        // Your thumbs count (+0.25 up, −0.5 down) on Claude's and the learned score, and settle remaining ties.
        let ca = a.claudeScore.map { $0 + Library.thumbNudge(a.reaction) } ?? 0, cb = b.claudeScore.map { $0 + Library.thumbNudge(b.reaction) } ?? 0
        if ca != cb { return ca > cb }
        let la = a.learnedScore.map { $0 + Library.thumbNudge(a.reaction) } ?? 0, lb = b.learnedScore.map { $0 + Library.thumbNudge(b.reaction) } ?? 0
        if la != lb { return la > lb }
        if a.apple != b.apple { return a.apple > b.apple }
        if a.reaction != b.reaction { return a.reaction > b.reaction }
        let ra = a.rankRaw, rb = b.rankRaw
        if ra != rb { return ra > rb }
        return a.best.date < b.best.date
    }

    private(set) var years: [Int] = []

    /// Saves now and waits for the write, so nothing is lost when iOS suspends or ends the app.
    func flush() {
        save()
        Library.saveQueue.sync {}
    }

    /// Writes to disk off the main thread.
    func save(then done: (@Sendable () -> Void)? = nil) {
        // Never before the saved library is read: an empty save would overwrite it.
        guard ready, !savesBlocked else { if let done { DispatchQueue.main.async(execute: done) }; return }
        saveTask?.cancel()   // this save covers any pending "save soon"
        unsaved = 0; lastSave = Date()
        let s = Saved(photos: Array(photos.values), hidden: Array(hidden), birthdays: birthdays,
                      people: people, strictness: strictness,
                      claudeModel: claudeModel, claudeScope: claudeScope, claudeBatches: claudeBatches, rankBy: rankBy, claudeFailures: claudeFailures, learned: ownModel, claudeSensitive: claudeSensitive,
                      putBack: nil, keptOut: Array(keptOut), learnedFilter: ownFilter,
                      trainedSignature: nil, useBuiltInLearning: useBuiltInLearning,
                      trainedSignatureBits: trainedSignature.map { Int64(bitPattern: $0) },
                      claudeRemoved: claudeRemoved, claudeSent: claudeSent.mapValues { Array($0) },
                      claudeSentYear: claudeSentYear, reactions: reactions,
                      notThem: notThem.mapValues { $0.map(\.uuidString) }, ignoredFaces: Array(ignoredFaces),
                      addedBack: Array(addedBack), confirmedFaces: confirmedFaces.mapValues(\.uuidString),
                      skippedFaces: Array(skippedFaces), taste: taste,
                      tasteSignatureBits: tasteSignature.map { Int64(bitPattern: $0) })
        let u = url, legacy = legacyURL
        // One save at a time, in order, so an older snapshot can never land after a newer one.
        Library.saveQueue.async {
            let t0 = Date()
            var bytes = 0
            autoreleasepool {
                let enc = PropertyListEncoder(); enc.outputFormat = .binary
                if let data = try? enc.encode(s), (try? data.write(to: u, options: .atomic)) != nil {
                    bytes = data.count
                    // The old JSON copy is kept as a backup until a later launch has read the binary file fine.
                    let bak = legacy.appendingPathExtension("bak")
                    if FileManager.default.fileExists(atPath: legacy.path) {
                        try? FileManager.default.removeItem(at: bak)
                        try? FileManager.default.moveItem(at: legacy, to: bak)
                    }
                } else if let data = try? JSONEncoder().encode(s), (try? data.write(to: legacy, options: .atomic)) != nil {
                    bytes = data.count
                    // Fall back to JSON; the newest readable copy is the one read next time.
                }
            }
            let took = Date().timeIntervalSince(t0), size = bytes
            DispatchQueue.main.async {
                Shared.library.note("Last save", String(format: "%.1f s, ", took) + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                Shared.library.noteMemory()
            }
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    private func load(_ s: Saved) {
        photos = Dictionary(s.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Swimsuits are no longer a reason to leave a photo out: Claude's earlier "swimwear" calls become plain
        // scores, so beach and pool photos come back (and the learned filter stops hiding ones like them).
        for (id, p) in photos where p.claude?.exclude == "swimwear" { photos[id]?.claude?.exclude = nil }
        hidden = Set(s.hidden)
        birthdays = s.birthdays ?? []
        // Names saved with an older fingerprint size can't be compared; keep the names, ask for faces again.
        people = (s.people ?? []).map { p in
            var p = p
            if p.centroid.count != People.dim { p.centroid = []; p.count = 0 }
            // Example faces from an older recognizer can't be compared either (their faces carry over as your tags).
            if let ex = p.examples, ex.contains(where: { $0.count != People.dim }) {
                p.examples = ex.filter { $0.count == People.dim }; p.namedExamples = 0
            }
            return p
        }
        strictness = s.strictness ?? 1
        claudeModel = s.claudeModel ?? claudeModel
        // Haiku is the default; switch earlier saves that were on the old default and never sent anything.
        if claudeModel == "claude-sonnet-5-5" && !s.photos.contains(where: { $0.claude != nil }) && (s.claudeBatches ?? []).isEmpty {
            claudeModel = "claude-haiku-5-5"
        }
        keptOut = Set(s.keptOut ?? [])
        reactions = s.reactions ?? [:]
        notThem = (s.notThem ?? [:]).mapValues { Set($0.compactMap(UUID.init(uuidString:))) }
        ignoredFaces = Set(s.ignoredFaces ?? [])
        addedBack = Set(s.addedBack ?? [])
        confirmedFaces = (s.confirmedFaces ?? [:]).compactMapValues(UUID.init(uuidString:))
        skippedFaces = Set(s.skippedFaces ?? [])
        claudeSensitive = s.claudeSensitive ?? false
        ownFilter = s.learnedFilter.flatMap { $0.weights.count == Learner.featureCount ? $0 : nil }
        useBuiltInLearning = s.useBuiltInLearning ?? true
        // Saves from before this phone's own learning was kept alongside the built-in one: learn once more at
        // launch, so it comes back (and can be copied) without waiting for new Claude scores.
        trainedSignature = s.trainedSignatureBits.map { UInt64(bitPattern: $0) } ?? s.trainedSignature
        if s.useBuiltInLearning == nil { trainedSignature = nil }
        claudeRemoved = (s.claudeRemoved ?? [:]).filter { $0.value != "swimwear" }
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
        taste = s.taste.flatMap { $0.weights.count == Learner.featureCount ? $0 : nil }
        tasteSignature = s.tasteSignatureBits.map { UInt64(bitPattern: $0) }
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
        if let r = s.rankBy { rankBy = r }
        claudeFailures = s.claudeFailures ?? [:]
    }
}
