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
        // Before the grown-up check, so a shirtless kid on their own still guards the photos around it.
        if s.blockedLabel == "swimwear" { return (nil, "Swimwear") }
        if Scorer.hasBareChest(s) { return (nil, "Shirtless") }
        guard let v = value(s) else { return (nil, "No grown-up") }
        return (v, nil)
    }
    /// The score a Swimwear or Shirtless photo keeps (it stays on the list).
    static func softScore(_ s: Signals, reason: String) -> Double? {
        reason == "Swimwear" || reason == "Shirtless" ? value(s) : nil
    }

    /// Bumped when the measurements or the scoring change, so AwwSnap reads its photos again.
    static let version = 2

    /// 0...1 light on a face from its exposure and evenness (both 0...1).
    static func lightScore(exposure: Double, even: Double) -> Double { max(0, min(1, 0.6 * exposure + 0.4 * even)) }

    /// 0...1 framing of the main face: not cut off at the top, some room above the head, not jammed to an edge.
    static func framing(_ f: FaceSignal) -> Double? {
        guard f.box.count == 4 else { return nil }
        let top = f.box[1] + f.box[3], cx = f.box[0] + f.box[2] / 2
        let room = 1 - top                                            // space above the head
        let head = room < 0.01 ? 0 : room < 0.04 ? 0.6 : room <= 0.35 ? 1 : max(0.3, 1 - (room - 0.35) * 2)
        let side = cx < 0.08 || cx > 0.92 ? 0.3 : cx < 0.15 || cx > 0.85 ? 0.7 : 1
        return head * side
    }

    /// How great the grown-ups look in the photo, for picking the best shots (a dating profile, say). Only
    /// things about the photo: a real smile, eyes open, looking at the camera, light on the face, the face big and
    /// clear enough, framing and posture. Never anyone's features, body or looks. Measurements a photo doesn't
    /// have (older reads, faces too small) are left out and the rest count in their place.
    static func value(_ s: Signals) -> Double? {
        let a = adults(s)
        guard !a.isEmpty else { return nil }
        let fs = a.map { s.faces[$0] }, n = Double(fs.count)
        let main = fs.max { $0.area < $1.area }!
        func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        var parts: [(w: Double, v: Double)] = [
            (0.30, Double(fs.filter(\.smile).count) / n),                       // a genuine smile counts most
            (0.10, Double(fs.filter { !$0.eyesClosed }.count) / n),             // eyes open
            (0.15, min(1, max(0, fs.map(\.quality).reduce(0, +) / n))),        // Apple's face capture quality
            (0.10, min(1, main.area / 0.08)),                                    // a face big enough to see well
        ]
        if let t = avg(fs.compactMap(\.turn)) { parts.append((0.12, max(0, 1 - t * 1.5))) }   // looking at the camera
        if let l = avg(fs.compactMap(\.light)) { parts.append((0.10, l)) }                     // light on the face
        if let f = framing(main) { parts.append((0.08, f)) }                                     // framing
        if let u = s.upright { parts.append((0.05, u)) }                                         // posture
        var raw = parts.map { $0.w * $0.v }.reduce(0, +) / parts.map(\.w).reduce(0, +)
        // Clearly about one or two people: a crowd isn't a portrait.
        if s.faces.count > 6 { raw *= 0.85 } else if a.count >= 3 { raw *= 0.92 }
        raw *= 0.4 + 0.6 * min(1, max(0, s.sharpness))               // blur caps how good a photo can be
        return max(0, min(1, raw))
    }
}
