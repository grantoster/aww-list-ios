import Foundation

/// One face found in a counted photo: where it is, and a compact "fingerprint" of how it looks.
struct FaceRecord: Codable, Hashable {
    /// Normalized box on the upright photo, bottom-left origin: x, y, width, height.
    var box: [Float]
    /// 256 signed bytes: the face's appearance, projected and normalized (see People.embed).
    var vec: Data
}

/// Someone the user has named in Who's Who.
struct Person: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var birthday: Date?
    /// Average fingerprint of the faces named as this person (unit length).
    var centroid: [Float]
    var count: Int
    /// A face to show for them: photo id and box.
    var samplePhoto: String
    var sampleBox: [Float]
}

/// Face grouping for Who's Who. Apple doesn't let apps read the Photos People & Pets names, so faces are
/// compared with Vision's image fingerprint of the face crop and grouped here; the user names the groups.
/// This is looser than Apple's own face recognition, so the user confirms every name.
enum People {
    static let dim = 256

    // MARK: Fingerprints

    private static let lock = NSLock()
    private static var projections: [Int: [Float]] = [:]

    /// A fixed random projection from the feature print's size down to 256 numbers (same every launch).
    static func projection(for inputDim: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if let p = projections[inputDim] { return p }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(inputDim)
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        var m = [Float](repeating: 0, count: dim * inputDim)
        for i in m.indices {   // Box–Muller normal samples
            let u = max(next(), 1e-12), v = next()
            m[i] = Float((-2 * log(u)).squareRoot() * cos(2 * Double.pi * v))
        }
        projections[inputDim] = m
        return m
    }

    /// Turns a Vision feature print (any length) into a 256-byte fingerprint.
    static func embed(_ x: [Float]) -> Data {
        guard !x.isEmpty else { return Data(count: dim) }
        let p = projection(for: x.count)
        var y = [Float](repeating: 0, count: dim)
        for r in 0..<dim {
            var s: Float = 0
            let base = r * x.count
            for c in 0..<x.count { s += p[base + c] * x[c] }
            y[r] = s
        }
        let n = max(y.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot(), 1e-9)
        return Data(y.map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 / n * 127).rounded())))) })
    }

    static func floats(_ d: Data) -> [Float] {
        normalized(d.map { Float(Int8(bitPattern: $0)) })
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = max(v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot(), 1e-9)
        return v.map { $0 / n }
    }

    // MARK: Grouping

    /// How alike two faces must be to count as the same person, by the Who's Who "Grouping" setting
    /// (0 stricter, 1 normal, 2 looser).
    static func threshold(strictness: Int) -> Float { strictness <= 0 ? 0.90 : strictness == 1 ? 0.84 : 0.78 }

    /// Greedy grouping: each face joins the most similar group above the threshold, or starts a new one.
    /// Returns groups as index lists, largest first.
    static func cluster(_ vecs: [[Float]], threshold: Float) -> [[Int]] {
        var centroids: [[Float]] = [], sums: [[Float]] = [], members: [[Int]] = []
        for (i, v) in vecs.enumerated() {
            var best = -1, bestSim: Float = threshold
            for (k, c) in centroids.enumerated() {
                let s = cosine(v, c)
                if s >= bestSim { bestSim = s; best = k }
            }
            if best < 0 {
                centroids.append(v); sums.append(v); members.append([i])
            } else {
                for d in 0..<min(v.count, sums[best].count) { sums[best][d] += v[d] }
                centroids[best] = normalized(sums[best])
                members[best].append(i)
            }
        }
        return members.sorted { $0.count > $1.count }
    }

    /// The named person a face belongs to, if any is similar enough.
    static func match(_ v: [Float], people: [Person], threshold: Float) -> UUID? {
        var best: UUID?, bestSim = threshold
        for p in people where p.centroid.count == v.count {
            let s = cosine(v, p.centroid)
            if s >= bestSim { bestSim = s; best = p.id }
        }
        return best
    }

    /// Adds faces to a person's average (or starts it).
    static func merged(_ centroid: [Float], count: Int, adding vecs: [[Float]]) -> [Float] {
        guard let first = vecs.first else { return centroid }
        var sum = centroid.isEmpty ? [Float](repeating: 0, count: first.count) : centroid.map { $0 * Float(count) }
        for v in vecs { for d in 0..<min(sum.count, v.count) { sum[d] += v[d] } }
        return normalized(sum)
    }
}
