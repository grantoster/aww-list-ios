import Foundation

/// One detected face, as measured by Vision (box, quality) and CIDetector (smile, eyes).
struct FaceSignal: Equatable {
    var area: Double = 0          // fraction of the image the face covers
    var quality: Double = 0       // Vision faceCaptureQuality; only compared within a burst
    var smile: Bool = false
    var eyesClosed: Bool = false
}

/// Everything the analyzer measured on one photo. Pure data, so scoring can be unit tested.
struct Signals: Equatable {
    var childConfidence: Double = 0      // 0...1, strongest of the baby/child labels
    var childPrecise: Bool = false       // the child label passed Apple's high-precision filter
    var babyConfidence: Double = 0       // 0...1
    var faces: [FaceSignal] = []
    var sharpness: Double = 0            // 0...1, measured on the subject's face crop
    var isScreenshot: Bool = false
    var blockedLabel: String? = nil      // "bath", "swimwear", "undressed", "document", "screenshot"

    var subject: FaceSignal? { faces.max { $0.area < $1.area } }
}

enum Scorer {
    /// Bump when scoring changes; photos scored by an older version are analyzed again.
    static let version = 2

    /// Minimum label confidence for a photo to count as having a child in it (unless the precise filter passed).
    static let childThreshold = 0.35
    /// Exclusion reasons that also hide every photo taken within 10 minutes of them.
    static let sensitive: Set<String> = ["Bath", "Swimwear", "Undressed"]
    static let quarantine: TimeInterval = 600

    /// Returns (raw 0...1, excluded reason). Mirrors the Aww List rubric:
    /// the child's own expression counts most, then real closeness, then the moment; blur pulls everything down.
    static func score(_ s: Signals) -> (raw: Double?, excluded: String?) {
        if s.isScreenshot { return (nil, "Screenshot") }
        if let b = s.blockedLabel { return (nil, b.capitalized) }
        guard s.childPrecise || s.childConfidence >= childThreshold else { return (nil, "No child") }
        guard let subj = s.subject else { return (nil, "No face") }
        let others = s.faces.filter { $0 != subj }

        // Expression: the subject (largest face) counts double; everyone else shares the rest.
        // Two smiling adults beside a serious baby no longer beat one smiling child.
        var emotion = (2 * (subj.smile ? 1.0 : 0) + Double(others.filter(\.smile).count)) / Double(2 + others.count)
        // A sleeping baby filling the frame is a sweet moment, not a miss.
        let sleepingBaby = s.babyConfidence > 0.5 && subj.eyesClosed && !subj.smile && others.isEmpty && subj.area > 0.08
        if sleepingBaby { emotion = 0.6 }

        // Closeness: a second face of comparable size, not strangers in the background.
        let connection = others.contains { $0.area >= subj.area * 0.25 } ? 1.0 : 0
        let presence = min(1, subj.area / 0.12)
        let child = min(1, s.childConfidence)

        var raw = 0.45 * emotion + 0.20 * connection + 0.20 * presence + 0.15 * child
        if subj.eyesClosed && !subj.smile && !others.isEmpty { raw -= 0.10 }   // a blink in a group shot
        if s.faces.count > 5 { raw *= 0.85 }                                   // crowds aren't child portraits
        raw *= 0.4 + 0.6 * min(1, max(0, s.sharpness))                         // blur caps how good a photo can be
        return (max(0, min(1, raw)), nil)
    }

    /// Variance of the Laplacian over a square grayscale crop: high for sharp detail, low for blur.
    /// Returned on a 0...1 scale (150 or more counts as fully sharp).
    static func sharpness(gray px: [UInt8], side n: Int) -> Double {
        guard n >= 3, px.count >= n * n else { return 0 }
        var sum = 0.0, sumSq = 0.0, count = 0.0
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) {
                let i = y * n + x
                let l = Double(px[i - n]) + Double(px[i + n]) + Double(px[i - 1]) + Double(px[i + 1]) - 4 * Double(px[i])
                sum += l; sumSq += l * l; count += 1
            }
        }
        let mean = sum / count
        return min(1, max(0, sumSq / count - mean * mean) / 150)
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
    /// Each year carries equal weight, so one huge year can't push every other year up or down.
    /// Tied raw scores get the same score. Small libraries top out lower, and a weak photo
    /// can't earn a high score just by being the best of a weak bunch.
    static func calibrate(_ raws: [Double], years: [Int]? = nil) -> [Int] {
        guard !raws.isEmpty else { return [] }
        let yrs = years ?? Array(repeating: 0, count: raws.count)
        let perYear = Dictionary(grouping: yrs, by: { $0 }).mapValues { 1.0 / Double($0.count) }
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
    /// Everything within 10 minutes of a bath, swimwear or undressed photo is left out too, so one missed frame
    /// of a bath burst can't slip onto the list. The best shot wins; ties go to the earlier, then the smaller id.
    static func moments(from photos: [PhotoScore]) -> [(best: PhotoScore, shots: Int, ids: [String])] {
        let hot = photos.filter { sensitive.contains($0.excluded ?? "") }.map(\.date).sorted()
        func quarantined(_ d: Date) -> Bool {
            var lo = 0, hi = hot.count
            while lo < hi { let m = (lo + hi) / 2; if hot[m] < d.addingTimeInterval(-quarantine) { lo = m + 1 } else { hi = m } }
            return lo < hot.count && hot[lo] <= d.addingTimeInterval(quarantine)
        }
        let counted = photos.filter { $0.raw != nil && !quarantined($0.date) }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        var result: [(best: PhotoScore, shots: Int, ids: [String])] = []
        var group: [PhotoScore] = []
        func flush() {
            guard var best = group.first else { return }
            for p in group.dropFirst() where (p.raw ?? 0) > (best.raw ?? 0) { best = p }
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

    static func caption(_ s: Signals) -> String {
        let smiles = s.faces.filter(\.smile).count
        let subj = s.subject
        if s.faces.count >= 3 && smiles >= 2 { return "All smiles together" }
        if s.faces.count == 2 && smiles >= 2 { return "Two big smiles" }
        if s.faces.count >= 2 { return "Together" }
        if subj?.smile == true { return s.babyConfidence > 0.5 ? "Baby grin" : "Big smile" }
        if subj?.eyesClosed == true { return s.babyConfidence > 0.5 ? "Sweet dreams" : "Sleepy moment" }
        return s.babyConfidence > 0.5 ? "Baby close-up" : "Little moment"
    }
}
