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

    /// Rough cost of one photo: a 768 px photo (~600–784 image tokens) plus the instructions (~400) in,
    /// ~40 tokens out. Shown in Settings as an estimate before sending.
    static func estimatedCost(photos: Int, model: String) -> Double {
        guard let m = models.first(where: { $0.id == model }) else { return 0 }
        return Double(photos) * (1_200 * m.inPerM + 40 * m.outPerM) / 1_000_000
    }

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
        return ClaudeVerdict(score: max(1, min(10, score)), caption: caption, exclude: ex, model: model, rubric: rubric)
    }

    /// One line of a batch results file -> (custom_id, reply text) when it succeeded.
    static func parseResultLine(_ line: String) -> (id: String, text: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["custom_id"] as? String,
              let result = obj["result"] as? [String: Any], result["type"] as? String == "succeeded",
              let msg = result["message"] as? [String: Any],
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
            case .http(let code, let msg): code == 401 ? "Claude didn't accept the API key." : "Claude returned an error (\(code)): \(msg)"
            }
        }
    }

    /// The moments that still need Claude's score under the current settings.
    func candidates(_ library: Library) -> [Moment] {
        let model = library.claudeModel, n = library.claudeScope
        let pending = Set(library.claudeBatches.flatMap { $0.photos.values })
        var byYear: [Int: [Moment]] = [:]
        for m in library.moments { byYear[m.year, default: []].append(m) }   // already ranked best first
        return byYear.values.flatMap { n > 0 ? Array($0.prefix(n)) : $0 }
            .filter { m in
                guard !pending.contains(m.best.id) else { return false }
                if let c = m.best.claude { return c.model != model || c.rubric != Claude.rubric }
                return true
            }
    }

    /// Sends the next photos in batches of 200, then checks for results.
    func send(_ library: Library) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let list = candidates(library)
        toSend = list.count; sent = 0
        if list.isEmpty { status = "Everything chosen is already scored by Claude."; await collect(library); return }
        let model = library.claudeModel
        do {
            for chunk in stride(from: 0, to: list.count, by: 200).map({ Array(list[$0..<min($0 + 200, list.count)]) }) {
                var reqs: [[String: Any]] = [], map: [String: String] = [:]
                for (i, m) in chunk.enumerated() {
                    status = "Preparing photo \((sent + i + 1).formatted()) of \(toSend.formatted())…"
                    guard let jpeg = await Self.jpeg(m.best.id) else { continue }
                    let cid = "p\(sent + i)_\(Int(Date().timeIntervalSince1970))"
                    map[cid] = m.best.id
                    reqs.append(["custom_id": cid, "params": [
                        "model": model, "max_tokens": 200, "system": Claude.system,
                        "messages": [["role": "user", "content": [
                            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                         "data": jpeg.base64EncodedString()]],
                            ["type": "text", "text": "Rate this photo."]
                        ]]]
                    ]])
                }
                if reqs.isEmpty { sent += chunk.count; continue }
                status = "Sending \(reqs.count) photos to Claude…"
                let body = try JSONSerialization.data(withJSONObject: ["requests": reqs])
                let (data, resp) = try await URLSession.shared.data(for: request(endpoint, method: "POST", body: body))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = obj["id"] as? String else {
                    throw ClaudeError.http(code, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
                }
                library.addClaudeBatch(ClaudeBatch(id: id, model: model, photos: map, sent: Date()))
                sent += chunk.count
            }
            status = "Sent \(sent.formatted()) photos. Claude's scores usually arrive within an hour; they're picked up when you open the app."
            await collect(library)
        } catch {
            status = error.localizedDescription
        }
    }

    /// Downloads finished batches and applies the scores.
    func collect(_ library: Library) async {
        for b in library.claudeBatches {
            do {
                let (data, _) = try await URLSession.shared.data(for: request(endpoint.appendingPathComponent(b.id)))
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if obj["processing_status"] as? String != "ended" {
                    if let counts = obj["request_counts"] as? [String: Int] {
                        status = "Claude is scoring… \((counts["succeeded"] ?? 0).formatted()) of \(b.photos.count.formatted()) done in the latest batch."
                    }
                    continue
                }
                guard let urlString = obj["results_url"] as? String, let url = URL(string: urlString) else {
                    library.removeClaudeBatch(b.id); continue
                }
                let (results, _) = try await URLSession.shared.data(for: request(url))
                var verdicts: [String: ClaudeVerdict] = [:]
                for line in String(decoding: results, as: UTF8.self).split(separator: "\n") {
                    guard let r = Claude.parseResultLine(String(line)), let photo = b.photos[r.id],
                          let v = Claude.parse(r.text, model: b.model) else { continue }
                    verdicts[photo] = v
                }
                library.applyClaude(verdicts)
                library.removeClaudeBatch(b.id)
                status = "Claude scored \(verdicts.count.formatted()) photos."
            } catch {
                status = error.localizedDescription
                return
            }
        }
    }

    /// The photo at 768 px as JPEG. Re-encoding drops location and other file details.
    static func jpeg(_ id: String) async -> Data? {
        guard let img = await AssetImage.load(id: id, size: CGSize(width: 768, height: 768), mode: .aspectFit) else { return nil }
        return img.jpegData(compressionQuality: 0.8)
    }
}
