import Foundation
import Photos
import UIKit
import Security

/// Claude's read of one photo.
struct ClaudeVerdict: Codable, Hashable {
    var score: Double          // 1...10, one decimal
    var caption: String
    var exclude: String?       // "swimwear", "bath", "undressed", "no_child", "screenshot", "ai_or_edited"
    var model: String
    var rubric: Int
    /// A second score from re-sending the same photo (the consistency check); the learning uses the average.
    var score2: Double? = nil
    var rechecked: Bool? = nil
}

/// A batch sent to Claude that hasn't come back yet.
struct ClaudeBatch: Codable, Hashable {
    var id: String
    var model: String
    var photos: [String: String]   // custom_id -> photo id
    var sent: Date
    /// A consistency-check batch: photos Claude already scored, sent again for a second score.
    var recheck: Bool? = nil
}

/// Optional final scoring by Claude, with your own Anthropic API key (stored in the iPhone's Keychain).
/// Apple's on-device pass still filters and pre-ranks everything; the photos you choose (each year's top N,
/// or every counted photo) are shrunk to 768 px, sent without location or other file details, and scored by
/// Claude through the Message Batches API (half price, results usually within hours, often minutes).
enum Claude {
    static let rubric = 1
    static let models: [(id: String, name: String, inPerM: Double, outPerM: Double)] = [
        // Batch prices (USD per million tokens) from Anthropic's pricing page.
        ("claude-haiku-5-5", "Haiku (default, cheapest)", 0.05, 0.25),
        ("claude-sonnet-5-5", "Sonnet", 1, 5),
        ("claude-opus-5-5", "Opus (most careful)", 2, 10)
    ]
    /// How many photos to send: each year's top 100, 300 or 1,000 moments, or every counted moment (0).
    static let scopes: [(n: Int, name: String)] = [(100, "Top 100 a year"), (300, "Top 300 a year"),
                                                   (1000, "Top 1,000 a year"), (0, "Every photo on the list")]

    static let system = """
    You rate family photos for "The Aww List", which ranks how cute the children in a family's photo library look.
    Score 1 to 10 (one decimal allowed). Genuine emotion counts most (laughter, delight, sweetness, wonder), then \
    connection between people, then the moment itself; sharpness and framing only break ties. Closed eyes, backs \
    of heads and blur lose points; crying or tantrums score low. Use the whole scale: 5 is an ordinary nice photo, \
    8 is a favorite, 9 and 10 are rare, truly exceptional moments.
    Leave the photo out (set "exclude") if: no child is the subject ("no_child"); a child is in a bath ("bath"), in \
    swimwear ("swimwear"), or undressed beyond a diaper, including shirtless children past the baby stage \
    ("undressed"); it is a screenshot, meme, document, collage, or a photo of a screen or print ("screenshot"); or \
    it looks AI-generated or heavily edited or face-retouched ("ai_or_edited").
    Reply with JSON only: {"score": number, "caption": "specific description of the moment, at most 8 words, no names", \
    "exclude": null or one of the reasons above}
    """

    /// Rough cost of one photo: a 768 px photo (~600–784 image tokens) plus the instructions (~400) in, and up to
    /// ~300 tokens out (the reply plus any brief thinking at low effort). Shown in Settings as an estimate.
    static func estimatedCost(photos: Int, model: String) -> Double {
        guard let m = models.first(where: { $0.id == model }) else { return 0 }
        return Double(photos) * (1_200 * m.inPerM + 300 * m.outPerM) / 1_000_000
    }

    /// Exact cost in micro-dollars (whole numbers, so no floating-point rounding), for display.
    static func costMicros(photos: Int, model: String) -> Int {
        guard let m = models.first(where: { $0.id == model }) else { return 0 }
        // price per million tokens × tokens = micro-dollars; prices are whole cents per million
        let inMicro = Int((m.inPerM * 100).rounded()) * 1_200 / 100, outMicro = Int((m.outPerM * 100).rounded()) * 300 / 100
        return photos * (inMicro + outMicro)
    }

    /// Micro-dollars to "$x.yy", halves rounding up.
    static func dollars(micros: Int) -> String {
        let cents = (micros + 5_000) / 10_000
        return "$\(cents / 100)." + (cents % 100 < 10 ? "0" : "") + "\(cents % 100)"
    }
    static func dollars(_ v: Double) -> String { dollars(micros: Int((v * 1_000_000).rounded())) }

    // MARK: Key (Keychain)

    private static let account = "anthropic-api-key"
    static var apiKey: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: Parsing (pure)

    /// Reads Claude's JSON reply (tolerating a code fence or extra words around it).
    static func parse(_ text: String, model: String) -> ClaudeVerdict? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any],
              let score = (obj["score"] as? NSNumber)?.doubleValue else { return nil }
        let caption = (obj["caption"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<String> = ["swimwear", "bath", "undressed", "no_child", "screenshot", "ai_or_edited"]
        let ex = (obj["exclude"] as? String).flatMap { allowed.contains($0) ? $0 : nil }
        let oneDecimal = (max(1, min(10, score)) * 10).rounded(.toNearestOrAwayFromZero) / 10   // halves round up
        return ClaudeVerdict(score: oneDecimal, caption: caption, exclude: ex, model: model, rubric: rubric)
    }

    /// One line of a batch results file -> (custom_id, reply text) when it succeeded.
    static func parseResultLine(_ line: String) -> (id: String, text: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["custom_id"] as? String,
              let result = obj["result"] as? [String: Any], result["type"] as? String == "succeeded",
              let msg = result["message"] as? [String: Any],
              msg["stop_reason"] as? String != "max_tokens",          // cut off: treat as not scored
              let content = msg["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        return (id, text)
    }

    /// Displayed 1–10 score: half rounds up.
    static func displayScore(_ v: Double) -> Int { Int((v + 0.5).rounded(.down)) }
}

/// Sends photos to Claude and collects the results.
@MainActor
final class ClaudeService: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var sent = 0
    @Published private(set) var toSend = 0

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages/batches")!

    /// Its own connection pool: a fresh connection per app session, waits for the network instead of failing,
    /// and generous timeouts for uploads on cellular.
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false   // offline fails right away with a clear message instead of waiting
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    /// Network hiccups worth another try ("The network connection was lost" is usually a stale connection).
    private static func transient(_ e: Error) -> Bool {
        guard let u = e as? URLError else { return false }
        return [.networkConnectionLost, .timedOut, .cannotConnectToHost,
                .dnsLookupFailed, .cannotFindHost].contains(u.code)
    }

    /// One request, retried up to 3 times on network hiccups and on "busy" answers (429/529/5xx).
    private func fetch(_ r: URLRequest) async throws -> (Data, Int) {
        var wait: UInt64 = 2
        for attempt in 1...3 {
            do {
                let (data, resp) = try await session.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (code == 429 || code >= 500) && attempt < 3 { try await Task.sleep(nanoseconds: wait * 1_000_000_000); wait *= 3; continue }
                return (data, code)
            } catch where Self.transient(error) && attempt < 3 {
                try await Task.sleep(nanoseconds: wait * 1_000_000_000); wait *= 3
            }
        }
        throw URLError(.networkConnectionLost)
    }

    /// Friendly words for network failures.
    static func describe(_ e: Error) -> String {
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet: return "No internet connection. Try again when you're online."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "This network blocked the secure connection to Claude. That's usually a VPN, an ad or content blocker, or work/school Wi-Fi. Try again on cellular (Wi-Fi off) or with the VPN or blocker off, and check Settings → General → Date & Time is set automatically."
            case .networkConnectionLost, .timedOut:
                return "The connection dropped while sending to Claude (tried 3 times). Try again on Wi-Fi; photos already sent are kept."
            default: return "Couldn't reach Claude (\(u.code.rawValue)). Try again in a moment."
            }
        }
        return e.localizedDescription
    }

    /// "Test connection" in Settings: reaches Claude with a tiny request and says what happened.
    func testConnection() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        status = "Testing the connection to Claude…"
        do { try await checkKey(); status = "Connected. Your API key works." }
        catch { status = Self.describe(error) }
    }

    /// Checks the key with a tiny request before any photos are prepared.
    private func checkKey() async throws {
        let (_, code) = try await fetch(request(URL(string: "https://api.anthropic.com/v1/models?limit=1")!))
        if code == 401 || code == 403 { throw ClaudeError.http(401, "") }
        if code != 200 { throw ClaudeError.http(code, code == 429 || code >= 500 ? "Claude is busy; try again in a few minutes." : "") }
    }

    /// After a dropped upload: did Anthropic create the batch anyway? (Avoids sending and paying twice.)
    private func recentBatch(count: Int, since: Date, known: Set<String>) async -> String? {
        guard let r = try? request(URL(string: "https://api.anthropic.com/v1/messages/batches?limit=10")!),
              let (data, code) = try? await fetch(r), code == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        for b in list {
            guard let id = b["id"] as? String, let created = b["created_at"] as? String,
                  !known.contains(id),   // never one of the batches already recorded
                  let when = iso.date(from: created) ?? iso2.date(from: created), when >= since.addingTimeInterval(-120),
                  let counts = b["request_counts"] as? [String: Int] else { continue }
            if counts.values.reduce(0, +) == count { return id }
        }
        return nil
    }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let key = Claude.apiKey else { throw ClaudeError.noKey }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "content-type") }
        r.httpBody = body
        r.timeoutInterval = 120
        return r
    }

    enum ClaudeError: LocalizedError {
        case noKey, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: "Add your Claude API key first."
            case .http(let code, let msg): code == 401 ? "Claude didn't accept the API key. Check it in Settings." : "Claude returned an error (\(code)). \(msg)"
            }
        }
    }

    /// The moments still to send. Each year gets a fixed budget of N plus a fifth of N, flagged photos included;
    /// photos Claude already scored (with this model, kept or removed) use up the budget, so re-ranking
    /// (for example by the learned score) never sends more than the chosen number. Within the budget, the best
    /// candidates go first: by the learned score once there is one, otherwise by Apple's.
    /// `refill`: slots freed by photos the final check held back go to the next-best candidates, not the spread.
    func candidates(_ library: Library, skipping skip: Set<String> = [], refill: Bool = false) -> [Moment] {
        let model = library.claudeModel, n = library.claudeScope
        let pending = Set(library.claudeBatches.flatMap { $0.photos.values })
        let sentToModel = library.claudeSent[model] ?? []
        func used(_ p: PhotoScore) -> Bool {
            pending.contains(p.id) || (library.claudeFailures[p.id] ?? 0) >= 2 || sentToModel.contains(p.id)
                || (p.claude.map { $0.model == model && $0.rubric == Claude.rubric } ?? false)
        }
        // The budget is counted over every photo Claude has scored (or is scoring) that year, removed, hidden or
        // no longer a burst's best included, so nothing can free up a slot that was already paid for.
        let cal = Calendar.current
        var spent: [Int: Int] = [:]
        // Counted by photo id, with the year fixed when it was sent, so deleted or re-dated photos still count.
        var spentIDs = sentToModel.union(pending)
        for p in library.photos.values where used(p) { spentIDs.insert(p.id) }
        for id in spentIDs {
            guard let y = library.claudeSentYear[id] ?? library.photos[id].map({ cal.component(.year, from: $0.date) }) else { continue }
            spent[y, default: 0] += 1
        }
        let forbidden = library.neverSend
        // A burst Claude removed (with any model) is never sent again, so switching models can't re-send it.
        func open(_ m: Moment) -> Bool {
            !skip.contains(m.best.id) && !m.memberIDs.contains { id in
                forbidden.contains(id) || library.photos[id].map(used) == true || library.photos[id]?.claude?.exclude != nil
                    || library.claudeRemoved[id] != nil
            }
        }
        var byYear: [Int: [Moment]] = [:]
        for m in library.claudePool { byYear[m.year, default: []].append(m) }   // cached at each rebuild
        var out: [Moment] = []
        for (year, list) in byYear {
            let list = list.filter(open)
            if n <= 0 { out += list; continue }
            // One budget for everything listed, flagged or not (N plus a fifth). Most of it goes to the best
            // candidates; a fifth of what's left is spread evenly over the rest of the year, so Claude also sees
            // photos Apple ranked low (and the app learns where Apple was wrong).
            let left = max(0, n + max(1, n / 5) - (spent[year] ?? 0))
            // Photos with faces but no child label (often grown-ups) only compete for the spread, never the top.
            let top = refill ? left : left - min(left, max(1, n / 5))
            let isPool = { (m: Moment) in Scorer.poolOnly.contains(m.best.excluded ?? "") }
            let pool = list.filter { !(isPool($0) && library.learnedRemoves($0.best)) }
            let topPicks = Array(pool.filter { !isPool($0) }.prefix(top))
            out += topPicks
            let taken = Set(topPicks.map(\.best.id))
            let rest = pool.filter { !taken.contains($0.best.id) }
            let spreadCount = left - topPicks.count   // unused top slots (too few listed photos) go to the spread
            if spreadCount > 0 && !rest.isEmpty {
                let step = Double(rest.count) / Double(spreadCount)
                var picked = Set<Int>()
                for k in 0..<spreadCount {
                    let i = min(rest.count - 1, Int((Double(k) + 0.5) * step))
                    if picked.insert(i).inserted { out.append(rest[i]) }
                }
            }
        }
        return out
    }

    /// Whether a moment may be sent right now. Reads the photo library itself (not just the app's records):
    /// every photo taken within 10 minutes of the moment (the Hidden album is never looked at) must have been checked by the
    /// current scorer and read successfully, none of them may make the moment off-limits (Scorer.neverSend), and
    /// no photo within 2 minutes may be one Claude removed (the same burst, however it's grouped now).
    /// Photos outside a Limited Access selection can't be seen, so they can't be checked.
    static func sendable(_ m: Moment, _ library: Library) -> Bool {
        // The Hidden album is never looked at: a photo moved there isn't found, so its moment isn't sent.
        let live = AssetImage.visible(m.memberIDs)
        var dates: [Date] = []
        live.enumerateObjects { a, _, _ in if let d = a.creationDate { dates.append(d) } }
        guard dates.count == m.memberIDs.count, let lo = dates.min(), let hi = dates.max() else { return false }
        let o = PHFetchOptions()
        o.includeHiddenAssets = false   // never look in the Hidden album
        o.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
                                  PHAssetMediaType.image.rawValue, lo.addingTimeInterval(-600) as NSDate,
                                  hi.addingTimeInterval(600) as NSDate)
        var near: [PhotoScore] = [], allChecked = true
        PHAsset.fetchAssets(with: o).enumerateObjects { a, _, stop in
            guard var p = library.photos[a.localIdentifier], p.version == Scorer.version,
                  p.excluded != Scorer.unavailable, !Scorer.needsShirtlessRecheck(p)
            else { allChecked = false; stop.pointee = true; return }
            if let d = a.creationDate { p.date = d }   // the photo's date now (it may have been changed in Photos)
            near.append(p)
        }
        guard allChecked else { return false }
        let blocked = Scorer.neverSend(near, allowSwimShirtless: library.claudeSensitive, removed: library.claudeRemoved)
        if m.memberIDs.contains(where: blocked.contains) { return false }
        let sensitive: Set<String> = ["bath", "undressed", "swimwear"]
        for p in near where sensitive.contains(p.claude?.exclude ?? library.claudeRemoved[p.id] ?? "") {
            if dates.contains(where: { abs($0.timeIntervalSince(p.date)) <= 120 }) { return false }
        }
        return true
    }

    /// Sends the next photos in batches of 50 (small enough to finish uploading if the app is closed), then checks for results.
    /// How many photos the consistency check re-sends.
    static let recheckCount = 100

    /// Photos Claude already scored (kept, with this model) and not yet re-checked, spread across the years.
    func recheckCandidates(_ library: Library) -> [Moment] {
        let model = library.claudeModel
        let pending = Set(library.claudeBatches.flatMap { $0.photos.values })
        let pool = library.claudePool.filter { m in
            guard let c = m.best.claude, c.exclude == nil, c.model == model, c.rubric == Claude.rubric, c.rechecked != true else { return false }
            return !pending.contains(m.best.id) && !m.memberIDs.contains(where: library.neverSend.contains)
        }.sorted { $0.best.date < $1.best.date }
        guard pool.count > Self.recheckCount else { return pool }
        let step = Double(pool.count) / Double(Self.recheckCount)
        return (0..<Self.recheckCount).map { pool[min(pool.count - 1, Int(Double($0) * step))] }
    }

    func send(_ library: Library, recheck: Bool = false) async {
        guard !busy else { return }
        // Only once the scan is finished: until then a bath photo near a candidate may not be checked yet.
        guard !Shared.scanner.isScanning else { status = "Wait for the scan to finish, then send."; return }
        if Shared.scanner.needsScan {
            Shared.scanner.startIfNeeded(library: library)
            status = "New photos need checking first. Send again when the scan finishes."
            return
        }
        busy = true; defer { busy = false }
        var paused = false, unloadedIDs = Set<String>()
        library.rebuild()   // fresh never-send set and pool, including photos added since the list last redrew
        let list = recheck ? recheckCandidates(library) : candidates(library)
        toSend = list.count; sent = 0
        if list.isEmpty {
            status = recheck ? "No photos left to re-check with this model." : "Everything chosen is already scored by Claude."
            await collect(library); return
        }
        let model = library.claudeModel
        do {
            status = "Checking your API key…"
            try await checkKey()
            // Photos the final check holds back free their slot for the next candidates (a few rounds at most).
            var held = Set<String>(), queue = list, round = 0
            while !queue.isEmpty && !paused && round < 4 {
            round += 1
            toSend = sent + queue.count
            for chunk in stride(from: 0, to: queue.count, by: 25).map({ Array(queue[$0..<min($0 + 25, queue.count)]) }) {
                // A scan that started meanwhile (new photos) may find a bath photo next to these: stop, send later.
                if Shared.scanner.isScanning || Shared.scanner.needsScan { paused = true; break }
                let blocked = library.neverSend
                let unblocked = chunk.filter { !$0.memberIDs.contains(where: blocked.contains) }
                // Checked before any photo is even loaded, and again right before upload.
                let preCleared = Set(unblocked.filter { Self.sendable($0, library) }.map(\.best.id))
                held.formUnion(unblocked.map(\.best.id).filter { !preCleared.contains($0) })
                let chunk = unblocked.filter { preCleared.contains($0.best.id) }
                if chunk.isEmpty { continue }
                var reqs: [[String: Any]] = [], map: [String: String] = [:]
                status = "Preparing photos \((sent + 1).formatted())–\((sent + chunk.count).formatted()) of \(toSend.formatted())…"
                // Load and shrink several photos at once.
                let ids = chunk.map(\.best.id)
                let jpegs: [Int: Data] = await withTaskGroup(of: (Int, Data?).self) { group in
                    var out: [Int: Data] = [:], next = 0
                    func addNext() { if next < ids.count { let k = next, id = ids[k]; next += 1; group.addTask { (k, await ClaudeService.jpeg(id)) } } }
                    for _ in 0..<min(6, ids.count) { addNext() }
                    for await (k, d) in group { if let d { out[k] = d }; addNext() }
                    return out
                }
                // The last check before anything leaves the phone: every photo taken within 10 minutes must be
                // checked, and none may be (or be near) a possible bath photo.
                if Shared.scanner.isScanning || Shared.scanner.needsScan { paused = true; break }
                let cleared = Set(chunk.filter { Self.sendable($0, library) }.map(\.best.id))
                held.formUnion(chunk.map(\.best.id).filter { !cleared.contains($0) })
                for (i, m) in chunk.enumerated() {
                    guard cleared.contains(m.best.id) else { continue }
                    guard let jpeg = jpegs[i] else { unloadedIDs.insert(m.best.id); held.insert(m.best.id); continue }
                    let cid = "p\(sent + i)_\(Int(Date().timeIntervalSince1970))"
                    map[cid] = m.best.id
                    reqs.append(["custom_id": cid, "params": [
                        "model": model, "max_tokens": 2000, "system": Claude.system,
                        "output_config": ["effort": "low"],
                        "messages": [["role": "user", "content": [
                            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                         "data": jpeg.base64EncodedString()]],
                            ["type": "text", "text": "Rate this photo."]
                        ]]]
                    ]])
                }
                if reqs.isEmpty { continue }
                status = "Sending \(reqs.count) photos to Claude…"
                let body = try JSONSerialization.data(withJSONObject: ["requests": reqs], options: [.withoutEscapingSlashes])
                // Finish the upload (and record the batch) even if the app is closed mid-send.
                let ended = Once()
                var bg = UIBackgroundTaskIdentifier.invalid
                bg = UIApplication.shared.beginBackgroundTask(withName: "Send to Claude") {
                    if ended.claim() { UIApplication.shared.endBackgroundTask(bg) }
                }
                defer { if ended.claim() { UIApplication.shared.endBackgroundTask(bg) } }
                // Upload; if the connection drops, check whether the batch was created before trying again.
                let started = Date()
                var id: String?
                var aborted = false
                for attempt in 1...3 where id == nil {
                    // Before a retry (which can come minutes later), check again: new photos may have arrived.
                    if attempt > 1 && (Shared.scanner.isScanning || Shared.scanner.needsScan
                                       || chunk.contains(where: { cleared.contains($0.best.id) && !Self.sendable($0, library) })) {
                        aborted = true; break
                    }
                    do {
                        let (data, resp) = try await session.data(for: request(endpoint, method: "POST", body: body))
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        if code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            id = obj["id"] as? String
                        } else if (code == 429 || code >= 500) && attempt < 3 {
                            try await Task.sleep(nanoseconds: UInt64(attempt * 3) * 1_000_000_000)
                        } else {
                            throw ClaudeError.http(code, code == 429 || code >= 500 ? "Claude is busy; try again in a few minutes." : "")
                        }
                    } catch where Self.transient(error) {
                        status = "Connection dropped; checking and retrying…"
                        if let existing = await recentBatch(count: reqs.count, since: started, known: Set(library.claudeBatches.map(\.id))) { id = existing; break }
                        if attempt == 3 { throw error }
                        try await Task.sleep(nanoseconds: UInt64(attempt * 3) * 1_000_000_000)
                    }
                }
                if aborted { paused = true; break }
                guard let id else { throw URLError(.networkConnectionLost) }
                library.addClaudeBatch(ClaudeBatch(id: id, model: model, photos: map, sent: Date(), recheck: recheck ? true : nil))
                sent += reqs.count
            }
            queue = held.isEmpty || recheck ? [] : candidates(library, skipping: held, refill: true)
            }
            let before = status
            await collect(library)
            if paused && !Shared.scanner.isScanning { Shared.scanner.startIfNeeded(library: library) }   // check the changes now
            if paused {
                let why = "your photo library changed while sending (new, changed or still-unchecked photos). Send again; the app checks them first."
                status = sent == 0 ? "Paused before sending: " + why : "Sent \(sent.formatted()) photos, then paused: " + why
            } else if sent == 0 {
                status = !unloadedIDs.isEmpty
                    ? "Nothing could be sent: \(unloadedIDs.count.formatted()) photos couldn't be loaded (check your connection if they're in iCloud)" + (unloadedIDs.count < toSend ? ", and the rest are held back." : ".")
                    : "Nothing could be sent yet: photos taken near the chosen ones aren't all checked yet, or are near possible bath photos or ones Claude removed."
            } else if sent > 0 && status == before {
                status = "Sent \(sent.formatted()) photos. Claude's scores usually arrive within an hour; they're picked up when you open the app."
            }
        } catch {
            status = Self.describe(error)
        }
    }

    /// Downloads finished batches and applies the scores.
    private var collecting = false
    func collect(_ library: Library) async {
        guard !collecting else { return }   // one check at a time, so a batch is never counted twice
        collecting = true; defer { collecting = false }
        for b in library.claudeBatches {
            do {
                let (data, code) = try await fetch(request(endpoint.appendingPathComponent(b.id)))
                if code == 404 { if b.recheck != true { library.unsend(model: b.model, Array(b.photos.values)) }; library.removeClaudeBatch(b.id); status = "A batch was no longer on Anthropic's side; those photos can be sent again."; continue }
                guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ClaudeError.http(code, code == 429 || code >= 500 ? "Claude is busy; try again in a few minutes." : "")
                }
                if obj["processing_status"] as? String != "ended" {
                    if let counts = obj["request_counts"] as? [String: Int] {
                        status = "Claude is scoring… \((counts["succeeded"] ?? 0).formatted()) of \(b.photos.count.formatted()) done in the latest batch."
                    }
                    continue
                }
                guard let urlString = obj["results_url"] as? String, let url = URL(string: urlString) else {
                    if b.recheck != true { library.unsend(model: b.model, Array(b.photos.values)) }; library.removeClaudeBatch(b.id); continue
                }
                let (results, rcode) = try await fetch(request(url))
                guard rcode == 200 else { throw ClaudeError.http(rcode, "Couldn't download the results yet; they'll be retried.") }
                var verdicts: [String: ClaudeVerdict] = [:]
                var failed: [String] = [], firstError = ""
                for line in String(decoding: results, as: UTF8.self).split(separator: "\n") {
                    let text = String(line)
                    if let r = Claude.parseResultLine(text), let photo = b.photos[r.id], let v = Claude.parse(r.text, model: b.model) {
                        verdicts[photo] = v
                    } else if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                              let cid = obj["custom_id"] as? String, let photo = b.photos[cid] {
                        failed.append(photo)
                        if firstError.isEmpty, let err = ((obj["result"] as? [String: Any])?["error"] as? [String: Any])?["error"] as? [String: Any] {
                            firstError = err["message"] as? String ?? ""
                        }
                    }
                }
                if b.recheck == true {
                    library.applyRecheck(verdicts, failed: failed)   // second scores; failures aren't offered again
                } else {
                    library.applyClaude(verdicts)
                    library.noteClaudeFailures(failed)
                    library.unsend(model: b.model, failed)   // can be tried again (up to twice in all)
                }
                library.removeClaudeBatch(b.id)
                status = "Claude scored \(verdicts.count.formatted()) photos." +
                    (failed.isEmpty ? "" : " \(failed.count.formatted()) couldn't be scored" + (firstError.isEmpty ? "." : ": \(firstError)"))
            } catch {
                status = Self.describe(error)
                return
            }
        }
    }

    /// The photo upright, at most 768 px on its long side, as JPEG. Redrawing drops location and other file details.
    nonisolated static func jpeg(_ id: String) async -> Data? {
        guard let img = await AssetImage.load(id: id, size: CGSize(width: 768, height: 768), mode: .aspectFit).image else { return nil }
        let k = min(1, 768 / max(img.size.width, img.size.height))
        let size = CGSize(width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let upright = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return upright.jpegData(compressionQuality: 0.8)
    }
}
