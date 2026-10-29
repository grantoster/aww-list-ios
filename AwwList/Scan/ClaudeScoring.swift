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
}

/// A batch sent to Claude that hasn't come back yet.
struct ClaudeBatch: Codable, Hashable {
    var id: String
    var model: String
    var photos: [String: String]   // custom_id -> photo id
    var sent: Date
}

/// Optional final scoring by Claude, with your own Anthropic API key (stored in the iPhone's Keychain).
/// Apple's on-device pass still filters and pre-ranks everything; the photos you choose (each year's top N,
/// or every counted photo) are shrunk to 768 px, sent without location or other file details, and scored by
/// Claude through the Message Batches API (half price, results usually within hours, often minutes).
enum Claude {
    static let rubric = 1
    static let models: [(id: String, name: String, inPerM: Double, outPerM: Double)] = [
        // Batch prices (USD per million tokens) from Anthropic's pricing page.
        ("claude-haiku-5-5", "Haiku (cheapest)", 0.05, 0.25),
        ("claude-sonnet-5-5", "Sonnet (recommended)", 1, 5),
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

    /// The moments that still need Claude's score: each year's top N by Apple's on-device score (so the set
    /// doesn't shift as Claude's own scores come in), minus ones already scored or waiting in a batch.
    func candidates(_ library: Library) -> [Moment] {
        let model = library.claudeModel, n = library.claudeScope
        let pending = Set(library.claudeBatches.flatMap { $0.photos.values })
        var byYear: [Int: [Moment]] = [:]
        for m in library.appleRanked { byYear[m.year, default: []].append(m) }   // cached at each rebuild
        return byYear.values.flatMap { n > 0 ? Array($0.prefix(n)) : $0 }
            .filter { m in
                guard !pending.contains(m.best.id), (library.claudeFailures[m.best.id] ?? 0) < 2 else { return false }
                if let c = m.best.claude { return c.model != model || c.rubric != Claude.rubric }
                return true
            }
    }

    /// Sends the next photos in batches of 50 (small enough to finish uploading if the app is closed), then checks for results.
    func send(_ library: Library) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let list = candidates(library)
        toSend = list.count; sent = 0
        if list.isEmpty { status = "Everything chosen is already scored by Claude."; await collect(library); return }
        let model = library.claudeModel
        do {
            for chunk in stride(from: 0, to: list.count, by: 50).map({ Array(list[$0..<min($0 + 50, list.count)]) }) {
                var reqs: [[String: Any]] = [], map: [String: String] = [:]
                for (i, m) in chunk.enumerated() {
                    status = "Preparing photo \((sent + i + 1).formatted()) of \(toSend.formatted())…"
                    guard let jpeg = await Self.jpeg(m.best.id) else { continue }
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
                let (data, resp) = try await URLSession.shared.data(for: request(endpoint, method: "POST", body: body))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = obj["id"] as? String else {
                    throw ClaudeError.http(code, code == 429 || code >= 500 ? "Claude is busy; try again in a few minutes." : "")
                }
                library.addClaudeBatch(ClaudeBatch(id: id, model: model, photos: map, sent: Date()))
                sent += reqs.count
            }
            let before = status
            await collect(library)
            if sent > 0 && status == before {
                status = "Sent \(sent.formatted()) photos. Claude's scores usually arrive within an hour; they're picked up when you open the app."
            }
        } catch {
            status = error.localizedDescription
        }
    }

    /// Downloads finished batches and applies the scores.
    func collect(_ library: Library) async {
        for b in library.claudeBatches {
            do {
                let (data, resp) = try await URLSession.shared.data(for: request(endpoint.appendingPathComponent(b.id)))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 { library.removeClaudeBatch(b.id); status = "A batch was no longer on Anthropic's side; those photos can be sent again."; continue }
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
                    library.removeClaudeBatch(b.id); continue
                }
                let (results, rresp) = try await URLSession.shared.data(for: request(url))
                let rcode = (rresp as? HTTPURLResponse)?.statusCode ?? 0
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
                library.applyClaude(verdicts)
                library.noteClaudeFailures(failed)
                library.removeClaudeBatch(b.id)
                status = "Claude scored \(verdicts.count.formatted()) photos." +
                    (failed.isEmpty ? "" : " \(failed.count.formatted()) couldn't be scored" + (firstError.isEmpty ? "." : ": \(firstError)"))
            } catch {
                status = error.localizedDescription
                return
            }
        }
    }

    /// The photo upright, at most 768 px on its long side, as JPEG. Redrawing drops location and other file details.
    static func jpeg(_ id: String) async -> Data? {
        guard let img = await AssetImage.load(id: id, size: CGSize(width: 768, height: 768), mode: .aspectFit) else { return nil }
        let k = min(1, 768 / max(img.size.width, img.size.height))
        let size = CGSize(width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let upright = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return upright.jpegData(compressionQuality: 0.8)
    }
}
