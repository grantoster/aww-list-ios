import Foundation

/// AwwSnap's on-device score: how great the grown-ups look in a photo (kids can be in it too). It's a starting
/// point; Claude's scores (and what AwwSnap learns from them) refine it. It scores the photo, never the person.
enum SnapScorer {
    /// The main faces that are grown-ups: Apple's own adult check when it can tell; otherwise a face whose own
    /// child reading is low, or, unmeasured, a face in a photo with no child reading at all.
    static func adults(_ s: Signals) -> [Int] {
        let main = s.mainFaceIndices.isEmpty ? Array(s.faces.indices) : s.mainFaceIndices
        return main.filter { i in
            let f = s.faces[i]
            guard f.box.count == 4, f.box[3] >= 0.04 else { return false }   // too small to judge
            if let a = s.isAdult(i) { return a }
            if let c = f.child { return c < 0.25 }
            return s.childConfidence < 0.3 && s.babyConfidence < 0.3
        }
    }

    /// Swimwear and bare chests stay listed (scored as usual) but are marked like Awwbum's, so they and the
    /// minutes around them are only sent to Claude if you allow it (kids can be in these photos).
    static func score(_ s: Signals) -> (raw: Double?, excluded: String?) {
        if s.isScreenshot { return (nil, "Screenshot") }
        if let b = s.blockedLabel, b != "swimwear" { return (nil, b.capitalized) }   // documents, baths, undressed
        guard let v = value(s) else { return (nil, "No grown-up") }
        if s.blockedLabel == "swimwear" { return (nil, "Swimwear") }
        if Scorer.hasBareChest(s) { return (nil, "Shirtless") }
        return (v, nil)
    }
    /// The score a Swimwear or Shirtless photo keeps (it stays on the list).
    static func softScore(_ s: Signals, reason: String) -> Double? {
        reason == "Swimwear" || reason == "Shirtless" ? value(s) : nil
    }

    private static func value(_ s: Signals) -> Double? {
        let a = adults(s)
        guard !a.isEmpty else { return nil }
        let fs = a.map { s.faces[$0] }, n = Double(fs.count)
        let smile = Double(fs.filter(\.smile).count) / n             // a genuine smile counts most
        let eyes = Double(fs.filter { !$0.eyesClosed }.count) / n    // eyes open
        let quality = fs.map(\.quality).reduce(0, +) / n             // Apple's face capture quality (light, angle, focus)
        let presence = min(1, (fs.map(\.area).max() ?? 0) / 0.08)     // a face big enough to see well
        var raw = 0.40 * smile + 0.15 * eyes + 0.25 * min(1, max(0, quality)) + 0.20 * presence
        if s.faces.count > 6 { raw *= 0.85 }                         // crowds aren't portraits
        raw *= 0.4 + 0.6 * min(1, max(0, s.sharpness))               // blur caps how good a photo can be
        return max(0, min(1, raw))
    }
}
