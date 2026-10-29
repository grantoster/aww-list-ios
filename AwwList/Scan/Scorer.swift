import Foundation

/// One detected face, as measured by Vision (box, quality) and CIDetector (smile, eyes).
struct FaceSignal: Equatable {
    var area: Double = 0          // fraction of the image the face covers
    var quality: Double = 0       // Vision faceCaptureQuality; only compared within a burst
    var smile: Bool = false
    var eyesClosed: Bool = false
    var bareTorso: Double = 0     // 0...1, share of the chest below this face that matches its skin tone
    var baby: Double? = nil       // "baby" label confidence on this person's own face-and-chest crop, when measured
    var child: Double? = nil      // child/baby label confidence on this person's own head-and-shoulders, when measured
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
    var aesthetic: Double? = nil         // Apple's photo-quality score, -1...1 (iOS 18 and later)
    var isUtility = false                // Apple thinks it's a "utility" photo (receipt, note, screenshot-like)
    var faceShape: [Double] = []         // main face, each 0...1: smile curve, mouth width, mouth open, eyes open, head turn, head tilt
    var facePrint: [Float] = []          // Vision's feature print of the main face crop
    var privacyHint = false              // even a faint bath/undressed sign: listed, but never sent to Claude

    /// The main subject: the largest face that reads as a child (so in a selfie with a parent it's the kid, not the
    /// grown-up's bigger face), or simply the largest face when no face was checked or none reads as a child.
    var subjectIndex: Int? {
        let kids = faces.indices.filter { (faces[$0].child ?? 0) >= 0.3 }
        let pool = kids.isEmpty ? Array(faces.indices) : kids
        return pool.max { faces[$0].area < faces[$1].area }
    }
    var subject: FaceSignal? { subjectIndex.map { faces[$0] } }
}

enum Scorer {
    /// Bump when scoring changes; photos scored by an older version are analyzed again.
    static let version = 11   // 11: richer fingerprint for the learned score (photo quality, face shape and crop); 10: bath check rebuilt
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
    /// Records of these kinds from before the any-bare-chest-is-Shirtless rule (flagVersion < 4) are re-read once,
    /// and count as not yet checked when deciding what may be sent.
    /// Bath, undressed, swimwear, document and screenshot flags from before the labels needed real confidence
    /// (flagVersion < 5) are re-read once.
    static func needsLabelRecheck(_ p: PhotoScore) -> Bool {
        ["Bath", "Undressed", "Swimwear", "Document", "Screenshot"].contains(p.excluded ?? "") && (p.flagVersion ?? 0) < 5
    }
    static func needsShirtlessRecheck(_ p: PhotoScore) -> Bool {
        (p.excluded == "No child" || p.excluded == "No child seen") && (p.faces ?? 0) > 0 && (p.flagVersion ?? 0) < 4
    }
    /// Flags from the file's details (Provenance.verdict). The photo stays listed; Claude makes the call.
    static let provenanceReasons: Set<String> = ["AI image", "Edited", "Not a camera photo"]
    static var sensitive: Set<String> { Set(quarantineWindow.keys) }
    static let quarantine: TimeInterval = quarantineWindow.values.max() ?? 0   // the longest window
    /// Share of the chest area that has to match the face's skin tone for a photo to count as shirtless.
    static let bareTorsoLimit = 0.6
    /// A year with fewer moments than this counts for less when spreading scores (so 3 photos from January
    /// can't claim a full year's share of 9s and 10s).
    static let fullYear = 200.0

    /// A bare chest that isn't a baby's (babies in just a diaper are fine).
    /// At most one bare chest is exempt: the smallest bare-chested face, and only when the photo reads as a baby
    /// photo and that person's own crop does too (or, if no crop was measured, by being the smallest face).
    static func hasBareChest(_ s: Signals) -> Bool {
        let bareIdx = s.faces.indices.filter { s.faces[$0].bareTorso >= bareTorsoLimit }
        let anyMeasured = s.faces.contains { $0.baby != nil }
        let smallestBare = bareIdx.min { s.faces[$0].area < s.faces[$1].area }
        let smallestFace = s.faces.indices.min { s.faces[$0].area < s.faces[$1].area }
        var exempt: Int? = nil
        if s.babyConfidence > 0.5, let i = smallestBare {
            if let b = s.faces[i].baby { if b > 0.5 { exempt = i } }
            else if !anyMeasured && i == smallestFace { exempt = i }
        }
        return bareIdx.contains { $0 != exempt }
    }

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
        let bare = hasBareChest(s)
        // Any non-baby bare chest is Shirtless, even with a weak child label, so its 2-minute window still guards
        // the burst around it (a grown-up's photo with no hint of a child gets no listing score either way).
        if bare { return (nil, "Shirtless") }
        guard s.childPrecise || s.childConfidence >= childThreshold else { return (nil, "No child") }
        if s.waterScene { return (nil, "Water") }
        guard let si = s.subjectIndex else { return (nil, "No face") }
        let subj = s.faces[si]
        let others = s.faces.enumerated().filter { $0.offset != si }.map(\.element)

        // Expression: the subject (the child's face, see subjectIndex) counts double; everyone else shares the rest.
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
        case ..<0.01: return 10
        case ..<0.05: return 9
        case ..<0.15: return 8
        case ..<0.30: return 7
        case ..<0.55: return 6
        case ..<0.75: return 5
        case ..<0.88: return 4
        case ..<0.95: return 3
        case ..<0.99: return 2
        default: return 1
        }
    }

    /// Turns raw scores into 1...10 by percentile: the top 1% are 10s, the next 4% 9s (so about 1 in 20 moments
    /// a year is a 9 or 10), the next 10% 8s, the next 15% 7s, the next 25% 6s, the next 20% 5s, the rest 1–4.
    /// Each full year carries equal weight, so one huge year can't push every other year up or down;
    /// a year with under 200 moments counts in proportion to its size.
    /// Tied raw scores get the same score. A weak photo can't earn a high score just by being the best of a weak bunch.
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
        let libraryCap = raws.count < 50 ? 9 : 10
        return zip(out, raws).map { v, r in min(v, libraryCap, ceiling(r)) }
    }

    /// The highest score a raw value can earn, whatever the rest of the library looks like.
    static func ceiling(_ r: Double) -> Int { r < 0.25 ? 4 : r < 0.40 ? 6 : r < 0.50 ? 8 : 10 }

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

    /// Photos with faces but no hint of a child at all: not listed (they're usually grown-ups), but still offered
    /// to Claude, because Apple's child labels miss kids seen from the side, in costumes, or far away.
    static let poolOnly: Set<String> = ["No child seen"]

    /// The score a photo with faces but no child label would have if a child were in it (nil without a face).
    static func poolScore(_ s: Signals) -> Double? {
        if s.isScreenshot || s.blockedLabel != nil || s.faces.isEmpty || hasBareChest(s) { return nil }
        var t = s
        t.waterScene = false; t.childPrecise = true
        for i in t.faces.indices { t.faces[i].bareTorso = 0 }
        return score(t).raw
    }

    /// The value a photo is listed with: its score, or for a flagged photo the score it would have had.
    /// Held-back photos count only once the user puts them back.
    static func listedValue(_ p: PhotoScore, putBack: Set<String> = [], includePoolOnly: Bool = false) -> Double? {
        if let r = p.raw { return r }
        guard let e = p.excluded else { return nil }
        if includePoolOnly && poolOnly.contains(e) { return p.soft }
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
                        putBack: Set<String> = [], includePoolOnly: Bool = false) -> [(best: PhotoScore, shots: Int, ids: [String])] {
        func value(_ p: PhotoScore) -> Double? { listedValue(p, putBack: putBack, includePoolOnly: includePoolOnly) }
        // A put-back photo stops holding back its neighbors only when it can actually be listed (has a score).
        // Nothing is taken off the list for being near a possible bath photo any more (those shots are only kept
        // from Claude, by neverSend); a photo the user keeps out drops only itself.
        let hot: [(date: Date, window: TimeInterval)] = []
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

    /// Photos that must never be sent to Claude, whatever the user puts back: every possible bath or undressed
    /// photo (by Apple's check or an earlier Claude verdict) and every shot within 10 minutes of one; every shot
    /// within 10 minutes of a photo that couldn't be read (so it was never checked); plus, unless the user allows
    /// it, possible swimwear photos (10 minutes around) and shirtless ones (2 minutes around).
    /// `removed` holds Claude's removal reasons kept after "Go back to on-device scores only" cleared the verdicts.
    static func neverSend(_ photos: [PhotoScore], allowSwimShirtless: Bool, removed: [String: String] = [:]) -> Set<String> {
        var windows: [String: TimeInterval] = ["Bath": 600, "Undressed": 600, unavailable: 600]
        if !allowSwimShirtless { windows["Swimwear"] = 600; windows["Shirtless"] = 120 }
        let claudeReason = ["bath": "Bath", "undressed": "Undressed", "swimwear": "Swimwear"]
        func window(_ p: PhotoScore) -> TimeInterval? {
            let a = windows[p.excluded ?? ""], b = p.claude?.exclude.flatMap { claudeReason[$0] }.flatMap { windows[$0] }
            let c = removed[p.id].flatMap { claudeReason[$0] }.flatMap { windows[$0] }
            return [a, b, c].compactMap { $0 }.max()
        }
        let sorted = photos.sorted { $0.date < $1.date }
        var out = Set<String>()
        for (i, p) in sorted.enumerated() {
            guard let w = [window(p), p.privacyHold == true ? 600 : nil].compactMap({ $0 }).max() else { continue }
            out.insert(p.id)
            var j = i - 1
            while j >= 0 && p.date.timeIntervalSince(sorted[j].date) <= w { out.insert(sorted[j].id); j -= 1 }
            j = i + 1
            while j < sorted.count && sorted[j].date.timeIntervalSince(p.date) <= w { out.insert(sorted[j].id); j += 1 }
        }
        return out
    }
}
