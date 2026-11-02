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

    /// A small recognizer for one named person: a weighted sum of the 256 fingerprint numbers, trained on the faces
    /// you named (and the app learned) as them versus everyone else's and the ones you said aren't them.
    struct Recognizer: Sendable {
        var w: [Float]; var b: Float
        func chance(_ v: [Float]) -> Float {
            var s = b
            for i in 0..<min(w.count, v.count) { s += w[i] * v[i] }
            return 1 / (1 + exp(-s))
        }
    }

    /// Key in `negatives` for faces that aren't anyone named (strangers), used against every person.
    static let nobody = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Trains one recognizer per named person (with at least 4 of their faces and 4 that aren't them).
    /// `negatives`: extra faces that aren't a given person (the ones you rejected).
    static func trainRecognizers(_ people: [Person], negatives: [UUID: [[Float]]] = [:],
                                 positives: [UUID: [[Float]]] = [:]) -> [UUID: Recognizer] {
        var pos: [UUID: [[Float]]] = [:]
        for p in people {
            var v = (p.examples ?? []).filter { $0.count == dim }.map(floats)
            if p.centroid.count == dim { v.append(p.centroid) }
            pos[p.id] = v + spread(positives[p.id] ?? [], to: 300)   // plus every face you've confirmed (a sample)
        }
        var out: [UUID: Recognizer] = [:]
        for p in people {
            let yes = pos[p.id] ?? []
            // Other people's faces, the ones you rejected, and (shared) faces far from everyone named.
            let no = spread(people.filter { $0.id != p.id }.flatMap { pos[$0.id] ?? [] } + (negatives[p.id] ?? [])
                            + (negatives[People.nobody] ?? []), to: 400)
            guard yes.count >= 4, no.count >= 4 else { continue }
            out[p.id] = train(yes: yes, no: no)
        }
        return out
    }

    /// Logistic regression with the two sides weighted equally and a little shrinkage (few examples, 256 numbers).
    static func train(yes: [[Float]], no: [[Float]], epochs: Int = 150, rate: Float = 0.5, l2: Float = 0.01) -> Recognizer {
        let d = dim
        var w = [Float](repeating: 0, count: d), b: Float = 0
        let rows = yes.map { ($0, Float(1), Float(0.5) / Float(yes.count)) } + no.map { ($0, Float(0), Float(0.5) / Float(no.count)) }
        for _ in 0..<epochs {
            if Task.isCancelled { break }
            var gw = [Float](repeating: 0, count: d), gb: Float = 0
            for (x, y, wt) in rows {
                var s = b
                for i in 0..<min(d, x.count) { s += w[i] * x[i] }
                let e = (1 / (1 + exp(-s)) - y) * wt
                for i in 0..<min(d, x.count) { gw[i] += e * x[i] }
                gb += e
            }
            for i in 0..<d { w[i] -= rate * (gw[i] * 4 + l2 * w[i]) }   // ×4: the weights sum to 1 across all rows
            b -= rate * gb * 4
        }
        return Recognizer(w: w, b: b)
    }

    /// Who each face is, from the faces you named.
    /// - `matched`: faces close enough to someone's named faces (ordinary matching).
    /// - `learned`: faces the app worked out on its own. A face very close to faces already known to be someone (a
    ///   bit stricter than ordinary matching, and clearly closer to them than to anyone else) is taken as that
    ///   person, and a sample of those join the references, so the next round reaches a little further (a toddler
    ///   photo bridging a baby photo and a kid photo). A face each person's own recognizer is very sure about is taken
    ///   too. Every learned face must still be reasonably close to that person's named faces, so a chain can't wander
    ///   into a look-alike sibling.
    /// - `review`: faces that might be someone but aren't sure enough, with how likely (for Review faces).
    /// - `owners`: each face's photo; one person is counted at most once per photo (the closest face wins).
    /// Indices are into `faces`. Stops early (with what it has) if the task is cancelled.
    /// `rejected`: faces you said aren't someone (index → those people); they're never matched or learned as
    /// them, and so never become references that reach further.
    static func learn(_ faces: [[Float]], people: [Person], threshold: Float, rounds: Int = 3,
                      rejected: [Int: Set<UUID>] = [:], owners: [String] = [], ignored: Set<Int> = [],
                      confirmed: [Int: UUID] = [:])
        -> (matched: [Int: UUID], learned: [Int: UUID], review: [Int: (id: UUID, chance: Float)]) {
        let named = Matcher(people)
        var matcher = named
        var matched = [Int: UUID](), learned = [Int: UUID]()
        var sims = [Int: Float]()
        // Faces you confirmed yourself are always that person (they never come up for checking again).
        for (i, id) in confirmed where rejected[i]?.contains(id) != true { matched[i] = id; sims[i] = 2 }
        for (i, v) in faces.enumerated() where matched[i] == nil {
            if let b = named.best(v), b.sim >= threshold, rejected[i]?.contains(b.id) != true { matched[i] = b.id; sims[i] = b.sim }
        }
        // Each person's recognizer, trained on their named faces against everyone else's and your rejections.
        var negatives: [UUID: [[Float]]] = [:]
        for (i, ids) in rejected { for id in ids { negatives[id, default: []].append(faces[i]) } }
        // Faces far from everyone named teach each recognizer what "not them" looks like (strangers, other kids).
        let far = faces.indices.filter { i in confirmed[i] == nil && (named.best(faces[i])?.sim ?? -2) < threshold - 0.2 }
        negatives[People.nobody] = spread(far, to: 300).map { faces[$0] }
        if Task.isCancelled { return ([:], [:], [:]) }
        var positives: [UUID: [[Float]]] = [:]
        for i in confirmed.keys.sorted() where rejected[i]?.contains(confirmed[i]!) != true { positives[confirmed[i]!, default: []].append(faces[i]) }
        let recognizers = trainRecognizers(people, negatives: negatives, positives: positives)
        func chances(_ v: [Float]) -> [(id: UUID, p: Float)] {
            recognizers.map { (id: $0.key, p: $0.value.chance(v)) }.sorted { $0.p > $1.p }
        }
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
                if let b = best, b.sim >= bar, second < b.sim - 0.03, rejected[i]?.contains(b.id) != true,
                   named.closeness(v, to: b.id) >= anchor {
                    added.append((i, b.id)); sims[i] = b.sim
                    continue
                }
                // The person's own recognizer is very sure (and no one else's is), the face is nearly close enough to
                // their named faces anyway (just under the Grouping setting's bar), and clearly closer to them than
                // to anyone else named — so a look-alike sibling isn't swept in.
                let c = chances(v)
                if let top = c.first, top.p >= 0.97, (c.dropFirst().first?.p ?? 0) < 0.3,
                   rejected[i]?.contains(top.id) != true {
                    let close = named.closeness(v, to: top.id)
                    let rival = people.filter { $0.id != top.id }.map { named.closeness(v, to: $0.id) }.max() ?? -2
                    if close >= threshold - 0.05 && close - rival >= 0.05 {
                        added.append((i, top.id)); sims[i] = close
                    }
                }
            }
            if added.isEmpty { break }
            for (i, id) in added { learned[i] = id }
            // A sample of each person's new faces joins the references (enough to reach further, not so many it's slow).
            for (id, idx) in Dictionary(grouping: added, by: \.1) {
                for (i, _) in spread(idx, to: 30) { matcher.add(id, faces[i]) }
            }
        }
        // One person per photo: if two faces in a photo were both taken as the same person, only the closest stays.
        if owners.count == faces.count {
            var bestIn: [String: Int] = [:]   // "photo|person" → face index
            for (i, id) in matched.merging(learned, uniquingKeysWith: { a, _ in a }) {
                let k = owners[i] + "|" + id.uuidString
                if let j = bestIn[k] {
                    let keep = (sims[i] ?? 0) > (sims[j] ?? 0) ? i : j, drop = keep == i ? j : i
                    bestIn[k] = keep; matched[drop] = nil; learned[drop] = nil
                } else { bestIn[k] = i }
            }
        }
        // Faces left over that someone's recognizer thinks might be them: offered in Review faces.
        var review: [Int: (id: UUID, chance: Float)] = [:]
        if !recognizers.isEmpty {
            // People already counted in each photo (a second face there isn't asked about for them).
            var inPhoto = Set<String>()
            if owners.count == faces.count {
                for (i, id) in matched.merging(learned, uniquingKeysWith: { a, _ in a }) { inPhoto.insert(owners[i] + "|" + id.uuidString) }
            }
            for (i, v) in faces.enumerated() where matched[i] == nil && learned[i] == nil && !ignored.contains(i) {
                guard let top = chances(v).first(where: { rejected[i]?.contains($0.id) != true }), top.p >= 0.6,
                      named.closeness(v, to: top.id) >= anchor else { continue }
                if owners.count == faces.count && inPhoto.contains(owners[i] + "|" + top.id.uuidString) { continue }
                review[i] = (top.id, top.p)
            }
        }
        return (matched, learned, review)
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
