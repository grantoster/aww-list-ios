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
    /// Example faces (256-byte fingerprints): the ones you named first, then ones the app learned are this person.
    /// Matching against all of them (not just the average) recognizes a child across the years.
    var examples: [Data]? = nil
    /// How many of `examples` you named yourself (the rest were learned).
    var namedExamples: Int? = nil
    /// Faces the app learned are this person (not counting the ones you named).
    var learnedCount: Int? = nil
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

    /// The first `dims` numbers of the same projection (used for the whole-photo fingerprint of the learned score).
    static func embed(_ x: [Float], dims: Int) -> Data {
        guard !x.isEmpty else { return Data(count: dims) }
        let p = projection(for: x.count)
        var y = [Float](repeating: 0, count: dims)
        for r in 0..<min(dims, dim) {
            var s: Float = 0
            let base = r * x.count
            for c in 0..<x.count { s += p[base + c] * x[c] }
            y[r] = s
        }
        let n = max(y.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot(), 1e-9)
        return Data(y.map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 / n * 127).rounded())))) })
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
        Matcher(people).match(v, threshold: threshold)
    }

    /// Compares faces against every named person's average and example faces (built once, used for many faces).
    struct Matcher {
        var refs: [(id: UUID, v: [Float])] = []
        init(_ people: [Person]) {
            for p in people {
                if p.centroid.count == People.dim { refs.append((p.id, p.centroid)) }
                for e in p.examples ?? [] where e.count == People.dim { refs.append((p.id, People.floats(e))) }
            }
        }
        /// The closest person and how close (cosine), if any.
        func best(_ v: [Float]) -> (id: UUID, sim: Float)? {
            var out: (id: UUID, sim: Float)? = nil
            for r in refs where r.v.count == v.count {
                let s = People.cosine(v, r.v)
                if s > (out?.sim ?? -2) { out = (r.id, s) }
            }
            return out
        }
        func match(_ v: [Float], threshold: Float) -> UUID? {
            guard let b = best(v), b.sim >= threshold else { return nil }
            return b.id
        }
        mutating func add(_ id: UUID, _ v: [Float]) { refs.append((id, v)) }
        /// How close a face is to one person's references (their best one).
        func closeness(_ v: [Float], to id: UUID) -> Float {
            var out: Float = -2
            for r in refs where r.id == id && r.v.count == v.count { out = max(out, People.cosine(v, r.v)) }
            return out
        }
    }

    /// Who each face is, from the faces you named.
    /// - `matched`: faces close enough to someone's named faces (ordinary matching).
    /// - `learned`: faces the app worked out on its own. A face very close to faces already known to be someone (a
    ///   bit stricter than ordinary matching, and clearly closer to them than to anyone else) is taken as that
    ///   person, and a sample of those join the references, so the next round reaches a little further (a toddler
    ///   photo bridging a baby photo and a kid photo). Every learned face must still be reasonably close to that
    ///   person's named faces, so a chain can't wander into a look-alike sibling.
    /// Indices are into `faces`. Stops early (with what it has) if the task is cancelled.
    static func learn(_ faces: [[Float]], people: [Person], threshold: Float, rounds: Int = 3)
        -> (matched: [Int: UUID], learned: [Int: UUID]) {
        let named = Matcher(people)
        var matcher = named
        var matched = [Int: UUID](), learned = [Int: UUID]()
        for (i, v) in faces.enumerated() { if let id = named.match(v, threshold: threshold) { matched[i] = id } }
        // Ordinary matches are known faces too: a sample of them starts the references.
        for (id, idx) in Dictionary(grouping: matched.keys.sorted(), by: { matched[$0]! }) {
            for i in spread(idx, to: 30) { matcher.add(id, faces[i]) }
        }
        let bar = threshold + 0.03, anchor = threshold - 0.15
        for _ in 0..<rounds {
            if Task.isCancelled { break }
            var added: [(Int, UUID)] = []
            for (i, v) in faces.enumerated() where matched[i] == nil && learned[i] == nil {
                // Best and runner-up among different people.
                var best: (id: UUID, sim: Float)? = nil, second: Float = -2
                for r in matcher.refs where r.v.count == v.count {
                    let s = cosine(v, r.v)
                    if s > (best?.sim ?? -2) {
                        if let b = best, b.id != r.id { second = max(second, b.sim) }
                        best = (r.id, s)
                    } else if r.id != best?.id { second = max(second, s) }
                }
                guard let b = best, b.sim >= bar, second < b.sim - 0.03,
                      named.closeness(v, to: b.id) >= anchor else { continue }
                added.append((i, b.id))
            }
            if added.isEmpty { break }
            for (i, id) in added { learned[i] = id }
            // A sample of each person's new faces joins the references (enough to reach further, not so many it's slow).
            for (id, idx) in Dictionary(grouping: added, by: \.1) {
                for (i, _) in spread(idx, to: 30) { matcher.add(id, faces[i]) }
            }
        }
        return (matched, learned)
    }

    /// Keeps at most `n` items, spread evenly.
    static func spread<T>(_ items: [T], to n: Int) -> [T] {
        guard items.count > n, n > 0 else { return items }
        let step = Double(items.count) / Double(n)
        return (0..<n).map { items[Int(Double($0) * step)] }
    }

    /// Adds faces to a person's average (or starts it).
    static func merged(_ centroid: [Float], count: Int, adding vecs: [[Float]]) -> [Float] {
        guard let first = vecs.first else { return centroid }
        var sum = centroid.isEmpty ? [Float](repeating: 0, count: first.count) : centroid.map { $0 * Float(count) }
        for v in vecs { for d in 0..<min(sum.count, v.count) { sum[d] += v[d] } }
        return normalized(sum)
    }
}
