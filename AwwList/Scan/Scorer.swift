import Foundation

/// One detected face, as measured by Vision (box, quality) and CIDetector (smile, eyes).
struct FaceSignal: Equatable {
    var area: Double = 0          // fraction of the image the face covers
    var quality: Double = 0       // Vision faceCaptureQuality; only compared within a burst
    var smile: Bool = false
    var eyesClosed: Bool = false
    var bareTorso: Double = 0     // 0...1, share of the chest below this face that matches its skin tone
    var baby: Double? = nil       // "baby" label confidence on this person's own face-and-chest crop, when measured
    var box: [Double] = []        // normalized x, y, width, height on the upright photo (bottom-left origin)
}

/// Everything the analyzer measured on one photo. Pure data, so scoring can be unit tested.
struct Signals: Equatable {
    var childConfidence: Double = 0      // 0...1, strongest of the baby/child labels
    var childPrecise: Bool = false       // the child label passed Apple's high-precision filter
    var babyConfidence: Double = 0       // 0...1
    var faces: [FaceSignal] = []
    var sharpness: Double = 0            // 0...1, measured on the subject's face crop
    var labels: [String] = []            // scene/object labels used for the description (Describe.sceneLabels)
    var waterScene: Bool = false         // confident water-scene label (Analyzer.waterScenes)
    var isScreenshot: Bool = false
    var blockedLabel: String? = nil      // "bath", "swimwear", "undressed", "document", "screenshot"
    var scenePrint: [Float] = []         // Vision's feature print of the whole photo (for the learned score)

    var subjectIndex: Int? { faces.indices.max { faces[$0].area < faces[$1].area } }
    var subject: FaceSignal? { subjectIndex.map { faces[$0] } }
}

enum Scorer {
    /// Bump when scoring changes; photos scored by an older version are analyzed again.
    static let version = 9   // (soft scores are filled in for set-aside photos without a full rescan)
    /// Exclusion reason for a photo whose image couldn't be loaded (offline iCloud photo).
    static let unavailable = "Unavailable"

    /// Minimum label confidence for a photo to count as having a child in it (unless the precise filter passed).
    static let childThreshold = 0.35
    /// How long before and after a held-back photo every other shot is held back too: 10 minutes around a
    /// possible bath or undressed photo (the whole session). Swimwear and shirtless are only flags now (see softReasons).
    static let quarantineWindow: [String: TimeInterval] = ["Bath": 600, "Undressed": 600]
    /// The only checks Apple still decides on its own: possible bath or undressed photos stay off the list (and are
    /// never sent to Claude) unless the user puts them back in Settings.
    static let heldBack: Set<String> = ["Bath", "Undressed"]
    /// Flags from the file's details (Provenance.verdict). The photo stays listed; Claude makes the call.
    static let provenanceReasons: Set<String> = ["AI image", "Edited", "Not a camera photo"]
    static var sensitive: Set<String> { Set(quarantineWindow.keys) }
    static let quarantine: TimeInterval = quarantineWindow.values.max() ?? 0   // the longest window
    /// Share of the chest area that has to match the face's skin tone for a photo to count as shirtless.
    static let bareTorsoLimit = 0.6
    /// A year with fewer moments than this counts for less when spreading scores (so 3 photos from January
    /// can't claim a full year's share of 9s and 10s).
    static let fullYear = 200.0

    /// Returns (raw 0...1, excluded reason). Mirrors the Aww List rubric:
    /// the child's own expression counts most, then real closeness, then the moment; blur pulls everything down.
    static func score(_ s: Signals) -> (raw: Double?, excluded: String?) {
        if s.isScreenshot { return (nil, "Screenshot") }
        if let b = s.blockedLabel { return (nil, b.capitalized) }
        // Shirtless: any bare chest counts except a baby's (babies in just a diaper are fine).
        // Checked before the child test (with a lower bar) so an older kid the child label half-misses still
        // hides the burst around them.
        // At most one bare chest is exempt: the smallest bare-chested face, and only when the photo reads as a baby
        // photo and that person's own crop does too (or, if no crop was measured, by being the smallest face).
        let bareIdx = s.faces.indices.filter { s.faces[$0].bareTorso >= bareTorsoLimit }
        let anyMeasured = s.faces.contains { $0.baby != nil }
        let smallestBare = bareIdx.min { s.faces[$0].area < s.faces[$1].area }
        let smallestFace = s.faces.indices.min { s.faces[$0].area < s.faces[$1].area }
        var exempt: Int? = nil
        if s.babyConfidence > 0.5, let i = smallestBare {
            if let b = s.faces[i].baby { if b > 0.5 { exempt = i } }
            else if !anyMeasured && i == smallestFace { exempt = i }
        }
        let bare = bareIdx.contains { $0 != exempt }
        if bare && (s.childPrecise || s.childConfidence >= 0.15) { return (nil, "Shirtless") }
        guard s.childPrecise || s.childConfidence >= childThreshold else { return (nil, "No child") }
        if s.waterScene { return (nil, "Water") }
        guard let si = s.subjectIndex else { return (nil, "No face") }
        let subj = s.faces[si]
        let others = s.faces.enumerated().filter { $0.offset != si }.map(\.element)

        // Expression: the subject (largest face) counts double; everyone else shares the rest.
        // Two smiling adults beside a serious baby no longer beat one smiling child.
        var emotion = (2 * (subj.smile ? 1.0 : 0) + Double(others.filter(\.smile).count)) / Double(2 + others.count)
        // A sleeping baby is a sweet moment, not a miss, whether alone or in someone's arms.
        let isBaby = s.babyConfidence > 0.5
        // Alone, the closed eyes must be the baby's; with others, only the smallest face counts as the baby's
        // (so a parent's blink isn't mistaken for a sleeping baby).
        let babyFace = s.faces.count == 1 ? s.faces.first : s.faces.min { $0.area < $1.area }
        let sleepingBaby = isBaby && babyFace.map { $0.eyesClosed && !$0.smile && $0.area > 0.03 } == true
        if sleepingBaby { emotion = max(emotion, 0.6) }

        // Closeness: a second face of comparable size, not strangers in the background.
        let connection = others.contains { $0.area >= subj.area * 0.25 } ? 1.0 : 0
        let presence = min(1, subj.area / 0.12)
        let child = min(1, s.childConfidence)

        var raw = 0.45 * emotion + 0.20 * connection + 0.20 * presence + 0.15 * child
        if !isBaby && subj.eyesClosed && !subj.smile && !others.isEmpty { raw -= 0.10 }   // a blink in a group shot
        if s.faces.count > 5 { raw *= 0.85 }                                   // crowds aren't child portraits
        raw *= 0.4 + 0.6 * min(1, max(0, s.sharpness))                         // blur caps how good a photo can be
        return (max(0, min(1, raw)), nil)
    }

    /// Variance of the Laplacian over a grayscale crop (row-major, w x h): high for sharp detail, low for blur.
    /// Returned on a 0...1 scale (150 or more counts as fully sharp). Measured at the crop's own resolution,
    /// never upscaled, so small faces aren't mistaken for blurry ones.
    static func sharpness(gray px: [UInt8], width w: Int, height h: Int) -> Double {
        guard w >= 3, h >= 3, px.count >= w * h else { return 0 }
        var sum = 0.0, sumSq = 0.0, count = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let l = Double(px[i - w]) + Double(px[i + w]) + Double(px[i - 1]) + Double(px[i + 1]) - 4 * Double(px[i])
                sum += l; sumSq += l * l; count += 1
            }
        }
        let mean = sum / count
        return min(1, max(0, sumSq / count - mean * mean) / 150)
    }

    /// Share of `torso` pixels (RGB triples) whose chroma is close to the median chroma of `face`.
    /// Shirts in a skin-like color also match, which errs toward leaving a photo out.
    static func skinMatch(face: [UInt8], torso: [UInt8]) -> Double {
        func chroma(_ p: [UInt8], _ i: Int) -> (Double, Double) {
            let r = Double(p[i]), g = Double(p[i + 1]), b = Double(p[i + 2])
            return (128 - 0.168736 * r - 0.331264 * g + 0.5 * b, 128 + 0.5 * r - 0.418688 * g - 0.081312 * b)
        }
        guard face.count >= 3, torso.count >= 3 else { return 0 }
        let f = stride(from: 0, to: face.count - 2, by: 3).map { chroma(face, $0) }
        let cb = f.map(\.0).sorted()[f.count / 2], cr = f.map(\.1).sorted()[f.count / 2]
        let t = stride(from: 0, to: torso.count - 2, by: 3).map { chroma(torso, $0) }
        let hits = t.filter { abs($0.0 - cb) < 8 && abs($0.1 - cr) < 8 }.count
        return Double(hits) / Double(t.count)
    }

    static func bucket(_ p: Double) -> Int {
        switch p {
        case ..<0.002: return 10
        case ..<0.01: return 9
        case ..<0.05: return 8
        case ..<0.15: return 7
        case ..<0.35: return 6
        case ..<0.60: return 5
        case ..<0.80: return 4
        case ..<0.92: return 3
        case ..<0.98: return 2
        default: return 1
        }
    }

    /// Turns raw scores into 1...10 by percentile, so 9s and 10s stay rare:
    /// top 1% → 9–10, next 4% → 8, next 10% → 7, next 20% → 6, next 25% → 5, the rest 1–4.
    /// Each full year carries equal weight, so one huge year can't push every other year up or down;
    /// a year with under 200 moments counts in proportion to its size.
    /// Tied raw scores get the same score. Small libraries top out lower, and a weak photo
    /// can't earn a high score just by being the best of a weak bunch.
    static func calibrate(_ raws: [Double], years: [Int]? = nil) -> [Int] {
        guard !raws.isEmpty else { return [] }
        let yrs = years ?? Array(repeating: 0, count: raws.count)
        let perYear = Dictionary(grouping: yrs, by: { $0 }).mapValues { 1.0 / max(Double($0.count), fullYear) }
        let weight = yrs.map { perYear[$0]! }
        let total = weight.reduce(0, +)
        let order = raws.indices.sorted { raws[$0] > raws[$1] }
        var out = Array(repeating: 1, count: raws.count)
        var above = 0.0, i = 0
        while i < order.count {
            var j = i, tieWeight = 0.0
            while j < order.count && raws[order[j]] == raws[order[i]] { tieWeight += weight[order[j]]; j += 1 }
            let v = bucket(above / total + 1e-9)   // tiny nudge so summed weights land on exact percentile edges
            for k in i..<j { out[order[k]] = v }
            above += tieWeight
            i = j
        }
        let libraryCap = raws.count < 50 ? 8 : raws.count < 500 ? 9 : 10
        return zip(out, raws).map { v, r in min(v, libraryCap, ceiling(r)) }
    }

    /// The highest score a raw value can earn, whatever the rest of the library looks like.
    static func ceiling(_ r: Double) -> Int { r < 0.30 ? 4 : r < 0.45 ? 5 : r < 0.60 ? 7 : r < 0.70 ? 8 : 10 }

    /// Groups photos into moments: shots less than 60 s apart are one moment, but a moment never runs past 2 minutes.
    /// Everything within 10 minutes of a possible bath or undressed photo is held back too, so one missed frame
    /// of a bath burst can't slip onto the list. The best shot wins; ties go to the earlier, then the smaller id.
    /// Every stored photo feeds the quarantine (old versions and hidden ones too); only photos that are shown —
    /// not hidden, and scored by `version` when given — can become moments.
    /// Apple's flags that no longer take a photo off the list: its labels miss children seen from behind or far
    /// away, and its water/swim/shirtless and file checks lean hard toward leaving photos out. A flagged photo is
    /// listed with the score it would have had (`soft`), and Claude decides whether it stays. (A photo with no
    /// hint of a child at all still stays off: softScore is nil for it.)
    static let softReasons: Set<String> = Set(["No child", "No face", "Water", "Swimwear", "Shirtless"]).union(provenanceReasons)

    /// The value a photo is listed with: its score, or for a flagged photo the score it would have had.
    /// Held-back photos count only once the user puts them back.
    static func listedValue(_ p: PhotoScore, putBack: Set<String> = []) -> Double? {
        if let r = p.raw { return r }
        guard let e = p.excluded else { return nil }
        if softReasons.contains(e) || (heldBack.contains(e) && putBack.contains(p.id)) { return p.soft }
        return nil
    }

    /// A score for a photo Apple flagged (or held back), as if that check hadn't fired, so it can still be listed. Nil when there's nothing to go on (no face and no hint of a child) or it's a screenshot
    /// or document.
    static func softScore(_ s: Signals) -> Double? {
        if s.isScreenshot || s.blockedLabel == "document" || s.blockedLabel == "screenshot" { return nil }
        guard s.childConfidence >= 0.10 else { return nil }   // some hint of a child, so grown-up photos don't flood the pool
        var t = s
        t.blockedLabel = nil; t.waterScene = false; t.childPrecise = true
        for i in t.faces.indices { t.faces[i].bareTorso = 0 }
        if t.faces.isEmpty { return 0.15 * min(1, s.childConfidence) * (0.4 + 0.6 * min(1, max(0, s.sharpness))) }
        return score(t).raw
    }

    /// Flagged photos are grouped with their listed value (see listedValue); held-back photos the user put back
    /// count too, and neither they nor anything else they're near holds back the shots around them.
    static func moments(from photos: [PhotoScore], hidden: Set<String> = [], version: Int? = nil,
                        putBack: Set<String> = []) -> [(best: PhotoScore, shots: Int, ids: [String])] {
        func value(_ p: PhotoScore) -> Double? { listedValue(p, putBack: putBack) }
        let hot = photos.filter { !putBack.contains($0.id) }
            .compactMap { p in quarantineWindow[p.excluded ?? ""].map { (date: p.date, window: $0) } }
            .sorted { $0.date < $1.date }
        func quarantined(_ d: Date) -> Bool {
            var lo = 0, hi = hot.count
            while lo < hi { let m = (lo + hi) / 2; if hot[m].date < d.addingTimeInterval(-quarantine) { lo = m + 1 } else { hi = m } }
            while lo < hot.count && hot[lo].date <= d.addingTimeInterval(quarantine) {
                if abs(hot[lo].date.timeIntervalSince(d)) <= hot[lo].window { return true }
                lo += 1
            }
            return false
        }
        let counted = photos.filter { value($0) != nil && !hidden.contains($0.id) && (version == nil || $0.version == version) && (putBack.contains($0.id) || !quarantined($0.date)) }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        var result: [(best: PhotoScore, shots: Int, ids: [String])] = []
        var group: [PhotoScore] = []
        func flush() {
            guard var best = group.first else { return }
            for p in group.dropFirst() where (value(p) ?? 0) > (value(best) ?? 0) { best = p }
            result.append((best: best, shots: group.count, ids: group.map(\.id)))
            group = []
        }
        for p in counted {
            if let first = group.first, let last = group.last,
               p.date.timeIntervalSince(last.date) >= 60 || p.date.timeIntervalSince(first.date) >= 120 { flush() }
            group.append(p)
        }
        flush()
        return result
    }

    static func caption(_ s: Signals, date: Date? = nil) -> String { Describe.caption(s, date: date) }
}
