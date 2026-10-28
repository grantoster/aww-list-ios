import Foundation

/// Everything the analyzer measured on one photo. Pure data, so scoring can be unit tested.
struct Signals: Equatable {
    var childConfidence: Double = 0      // 0...1, strongest of baby/child/toddler labels
    var babyConfidence: Double = 0       // 0...1
    var faceCount: Int = 0
    var bestFaceQuality: Double = 0      // VNFaceObservation.faceCaptureQuality, 0...1
    var largestFaceArea: Double = 0      // fraction of the image covered by the largest face
    var smiles: Int = 0                  // faces CIDetector reports as smiling
    var closedEyes: Int = 0              // faces with an eye closed
    var isScreenshot: Bool = false
    var blockedLabel: String? = nil      // e.g. "swimwear", "bathtub", "document"
}

enum Scorer {
    /// Minimum label confidence for a photo to count as having a child in it.
    static let childThreshold = 0.35

    /// Returns (raw 0...1, excluded reason). Mirrors the Aww List rubric:
    /// genuine emotion counts most, then connection between people, then the moment; clarity breaks ties.
    static func score(_ s: Signals) -> (raw: Double?, excluded: String?) {
        if s.isScreenshot { return (nil, "Screenshot") }
        if let b = s.blockedLabel { return (nil, b.capitalized) }
        guard s.childConfidence >= childThreshold else { return (nil, "No child") }
        guard s.faceCount > 0 else { return (nil, "No face") }

        let emotion = min(1, Double(s.smiles) / Double(max(1, min(s.faceCount, 2))))       // smiling faces
        let connection = s.faceCount >= 2 ? min(1, 0.6 + 0.2 * Double(s.faceCount - 2)) : 0.0 // more than one person
        let presence = min(1, s.largestFaceArea / 0.12)                                       // face big in frame
        let clarity = s.bestFaceQuality                                                       // sharp, well lit
        let child = min(1, s.childConfidence)

        var raw = 0.40 * emotion + 0.15 * connection + 0.15 * presence + 0.15 * clarity + 0.15 * child
        if s.closedEyes > 0 && s.smiles == 0 { raw -= 0.10 }   // eyes closed with no smile reads as a miss
        return (max(0, min(1, raw)), nil)
    }

    /// Turns raw scores into a 1...10 scale by rank, so 9s and 10s stay rare in every library:
    /// top 1% → 9–10, next 4% → 8, next 10% → 7, next 20% → 6, next 25% → 5, the rest 1–4.
    static func calibrate(_ raws: [Double]) -> [Int] {
        guard !raws.isEmpty else { return [] }
        let order = raws.indices.sorted { raws[$0] > raws[$1] }
        var out = Array(repeating: 1, count: raws.count)
        let n = Double(raws.count)
        for (rank, i) in order.enumerated() {
            let p = Double(rank) / n   // 0 = best
            let v: Int
            switch p {
            case ..<0.002: v = 10
            case ..<0.01: v = 9
            case ..<0.05: v = 8
            case ..<0.15: v = 7
            case ..<0.35: v = 6
            case ..<0.60: v = 5
            case ..<0.80: v = 4
            case ..<0.92: v = 3
            case ..<0.98: v = 2
            default: v = 1
            }
            out[i] = v
        }
        // Small libraries shouldn't hand out a 10 for being first of a handful.
        if raws.count < 500 { out = out.map { min($0, 9) } }
        return out
    }

    /// Groups photos into moments: shots less than 60 s apart are one moment; the best shot wins, ties go to the earlier one.
    static func moments(from photos: [PhotoScore]) -> [(best: PhotoScore, shots: Int)] {
        let counted = photos.filter { $0.raw != nil }.sorted { $0.date < $1.date }
        var result: [(PhotoScore, Int)] = []
        var group: [PhotoScore] = []
        func flush() {
            guard var best = group.first else { return }
            for p in group.dropFirst() where (p.raw ?? 0) > (best.raw ?? 0) { best = p }
            result.append((best, group.count))
            group = []
        }
        for p in counted {
            if let last = group.last, p.date.timeIntervalSince(last.date) >= 60 { flush() }
            group.append(p)
        }
        flush()
        return result
    }

    static func caption(_ s: Signals) -> String {
        if s.faceCount >= 3 && s.smiles >= 2 { return "All smiles together" }
        if s.faceCount == 2 && s.smiles >= 2 { return "Two big smiles" }
        if s.faceCount >= 2 { return "Together" }
        if s.smiles > 0 { return s.babyConfidence > 0.5 ? "Baby grin" : "Big smile" }
        if s.closedEyes > 0 { return "Sleepy moment" }
        return s.babyConfidence > 0.5 ? "Baby close-up" : "Little moment"
    }
}
