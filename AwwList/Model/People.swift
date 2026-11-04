import Accelerate
import Foundation

/// One face found in a counted photo: where it is, and a compact "fingerprint" of how it looks.
struct FaceRecord: Codable, Hashable {
    /// Normalized box on the upright photo, bottom-left origin: x, y, width, height.
    var box: [Float]
    /// 512 signed bytes: the face-identity model's print of the face (see FaceID).
    var vec: Data
    /// This person's expression in the shot, for ranking their best photos: smiling (0/1), eyes open (0/1), Apple's
    /// face capture quality (0...1), and how far the head is turned from the camera (0...1). −1 where it couldn't be
    /// read; nil on faces read before it was kept. Deleted with the face print.
    var look: [Float]? = nil
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
    /// Example faces (512-byte face prints): the ones you named first, then ones the app learned are this person.
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
    /// Face prints are the face-identity model's 512 numbers (FaceID); prints from older versions (256 numbers from
    /// a general image fingerprint) are read again.
    static let dim = FaceID.dims

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
    /// (For the face-identity model: the same person usually scores well above 0.4, different people well below.)
    static func threshold(strictness: Int) -> Float { strictness <= 0 ? 0.48 : strictness == 1 ? 0.40 : 0.33 }

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
    static func learn(_ faces: [[Float]], people: [Person], threshold: Float, rounds: Int = 5,
                      rejected: [Int: Set<UUID>] = [:], owners: [String] = [], ignored: Set<Int> = [],
                      confirmed: [Int: UUID] = [:], dates: [Date] = [])
        -> (matched: [Int: UUID], learned: [Int: UUID], review: [Int: (id: UUID, chance: Float)]) {
        let P = people.count
        guard P > 0 else { return ([:], [:], [:]) }
        let pIndex = Dictionary(people.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let when: [Double?] = faces.indices.map { $0 < dates.count ? dates[$0].timeIntervalSinceReferenceDate : nil }
        let photos = owners.count == faces.count
        var matched = [Int: UUID](), learned = [Int: UUID]()
        var sims = [Int: Float]()
        // Faces you confirmed yourself are always that person (they never come up for checking again).
        for (i, id) in confirmed where rejected[i]?.contains(id) != true && pIndex[id] != nil { matched[i] = id; sims[i] = 2 }

        // Who's counted in each photo, so a second face there isn't taken as the same person (kids photographed
        // together: once one is known, the other is compared only with everyone else).
        var inPhoto: [String: [Int: Int]] = [:]   // photo → person index → face
        func claim(_ i: Int, _ id: UUID) { if photos, let k = pIndex[id] { inPhoto[owners[i], default: [:]][k] = i } }
        for (i, id) in matched { claim(i, id) }
        // Nobody is in a photo taken before they were born (a day's leeway for time zones).
        let born: [Double?] = people.map { $0.birthday.map { $0.timeIntervalSinceReferenceDate - 86_400 } }
        func unborn(_ i: Int) -> Set<Int> {
            guard let t = when[i] else { return [] }
            return Set((0..<P).filter { k in born[k].map { t < $0 } ?? false })
        }
        func excluded(_ i: Int) -> Set<Int> {
            var out = Set((rejected[i] ?? []).compactMap { pIndex[$0] }).union(unborn(i))
            if photos { for (k, j) in inPhoto[owners[i]] ?? [:] where j != i { out.insert(k) } }
            return out
        }

        // Each person's anchors: their named faces plus up to 400 faces you confirmed, spread over the years.
        var anchors: [Ref] = []
        for (k, p) in people.enumerated() {
            if p.centroid.count == dim { anchors.append(Ref(p: k, v: p.centroid, t: nil)) }
            for e in p.examples ?? [] where e.count == dim { anchors.append(Ref(p: k, v: floats(e), t: nil)) }
        }
        for (id, idx) in Dictionary(grouping: matched.keys, by: { matched[$0]! }) {
            guard let k = pIndex[id] else { continue }
            let byDate = idx.sorted { (when[$0] ?? 0, $0) < (when[$1] ?? 0, $1) }
            for i in spread(byDate, to: 400) { anchors.append(Ref(p: k, v: faces[i], t: when[i])) }
        }
        let all = Array(faces.indices)
        let anchor = closeness(faces, all, when: when, refs: anchors, people: P)   // faces × people
        if Task.isCancelled { return ([:], [:], [:]) }
        func best(_ row: [Float], _ skip: Set<Int>) -> (k: Int, s: Float, second: Float)? {
            var b = -1, bs: Float = -2, sec: Float = -2
            for k in 0..<P where !skip.contains(k) {
                if row[k] > bs { sec = bs; bs = row[k]; b = k } else if row[k] > sec { sec = row[k] }
            }
            return b < 0 ? nil : (b, bs, sec)
        }
        func row(_ table: [Float], _ r: Int) -> [Float] { Array(table[(r * P)..<(r * P + P)]) }

        // One person per photo: if two faces in a photo were both taken as the same person, only the closest stays.
        func onePerPhoto() {
            guard photos else { return }
            var bestIn: [String: Int] = [:]   // "photo|person" → face index
            for (i, id) in matched.merging(learned, uniquingKeysWith: { a, _ in a }).sorted(by: { $0.key < $1.key }) {
                let k = owners[i] + "|" + id.uuidString
                if let j = bestIn[k] {
                    let keep = (sims[i] ?? 0) > (sims[j] ?? 0) ? i : j, drop = keep == i ? j : i
                    bestIn[k] = keep
                    if confirmed[drop] == nil { matched[drop] = nil; learned[drop] = nil }   // your own tags always stay
                } else { bestIn[k] = i }
            }
        }
        // Ordinary matching: close enough to someone's named or confirmed faces (not someone you confirmed is
        // another face in the same photo). The closest face in a photo wins; the other can be someone else below.
        // Faces you set aside (strangers and the like) are never matched or learned as anyone, unless you tag them.
        for i in faces.indices where matched[i] == nil && !ignored.contains(i) {
            if let b = best(row(anchor, i), excluded(i)), b.s >= threshold { matched[i] = people[b.k].id; sims[i] = b.s }
        }
        onePerPhoto()
        for (i, id) in matched { claim(i, id) }
        // A face that lost its photo's spot to a closer face (a kid who looks a bit like the parent beside them)
        // gets one more ordinary match, with the people already in that photo ruled out.
        for i in faces.indices where matched[i] == nil && !ignored.contains(i) {
            if let b = best(row(anchor, i), excluded(i)), b.s >= threshold {
                matched[i] = people[b.k].id; sims[i] = b.s; claim(i, people[b.k].id)
            }
        }
        // Each person's recognizer, trained on their named faces against everyone else's and your rejections.
        var negatives: [UUID: [[Float]]] = [:]
        for (i, ids) in rejected { for id in ids { negatives[id, default: []].append(faces[i]) } }
        // Faces far from everyone named teach each recognizer what "not them" looks like (strangers, other kids).
        let far = faces.indices.filter { i in confirmed[i] == nil && (row(anchor, i).max() ?? -2) < threshold - 0.2 }
        negatives[People.nobody] = spread(far, to: 300).map { faces[$0] }
        if Task.isCancelled { return ([:], [:], [:]) }
        var positives: [UUID: [[Float]]] = [:]
        for i in confirmed.keys.sorted() where rejected[i]?.contains(confirmed[i]!) != true { positives[confirmed[i]!, default: []].append(faces[i]) }
        let recognizers = trainRecognizers(people, negatives: negatives, positives: positives)
        let rec: [(k: Int, r: Recognizer)] = recognizers.compactMap { e in pIndex[e.key].map { ($0, e.value) } }
        func chances(_ v: [Float], _ skip: Set<Int>) -> [(k: Int, p: Float)] {
            rec.filter { !skip.contains($0.k) }.map { (k: $0.k, p: $0.r.chance(v)) }.sorted { $0.p > $1.p }
        }
        // References that reach further: the anchors, a sample of ordinary matches, then what each round learns.
        var refs = anchors
        for (id, idx) in Dictionary(grouping: matched.keys.filter { confirmed[$0] == nil }.sorted(), by: { matched[$0]! }) {
            guard let k = pIndex[id] else { continue }
            for i in spread(idx, to: 60) { refs.append(Ref(p: k, v: faces[i], t: when[i])) }
        }
        let bar = threshold + 0.03, reach = threshold - 0.15
        for _ in 0..<rounds {
            if Task.isCancelled { break }
            let open = faces.indices.filter { matched[$0] == nil && learned[$0] == nil && !ignored.contains($0) }
            if open.isEmpty { break }
            let near = closeness(faces, open, when: when, refs: refs, people: P)
            var added: [(Int, UUID)] = []
            for (r, i) in open.enumerated() {
                let skip = excluded(i)
                let a = row(anchor, i)
                // Clearly closest to one person's known faces, and still reasonably close to their anchors.
                if let b = best(row(near, r), skip), b.s >= bar, b.second < b.s - 0.03, a[b.k] >= reach {
                    added.append((i, people[b.k].id)); sims[i] = b.s
                    continue
                }
                // The person's own recognizer is very sure (and no one else's is), the face is nearly close enough to
                // their anchors anyway (just under the Grouping setting's bar), and clearly closer to them than
                // to anyone else — so a look-alike sibling isn't swept in.
                let c = chances(faces[i], skip)
                if let top = c.first, top.p >= 0.97, (c.dropFirst().first?.p ?? 0) < 0.3 {
                    let close = a[top.k]
                    let rival = (0..<P).filter { $0 != top.k && !skip.contains($0) }.map { a[$0] }.max() ?? -2
                    if close >= threshold - 0.05 && close - rival >= 0.05 {
                        added.append((i, people[top.k].id)); sims[i] = close
                    }
                }
            }
            // Two faces in one photo learned as the same person this round: only the closer one is kept, before
            // either becomes a reference (so a look-alike sibling can't pull in their own photos as the other child).
            if photos {
                var bestIn: [String: Int] = [:]
                for (n, (i, id)) in added.enumerated() {
                    let k = owners[i] + "|" + id.uuidString
                    if let m = bestIn[k], (sims[added[m].0] ?? 0) >= (sims[i] ?? 0) { continue }
                    bestIn[k] = n
                }
                let keep = Set(bestIn.values)
                for (n, (i, _)) in added.enumerated() where !keep.contains(n) { sims[i] = nil }
                added = added.enumerated().filter { keep.contains($0.offset) }.map(\.element)
            }
            if added.isEmpty { break }
            for (i, id) in added { learned[i] = id; claim(i, id) }
            // A sample of each person's new faces joins the references (enough to reach further, not so many it's slow).
            for (id, idx) in Dictionary(grouping: added, by: \.1) {
                guard let k = pIndex[id] else { continue }
                for (i, _) in spread(idx, to: 60) { refs.append(Ref(p: k, v: faces[i], t: when[i])) }
            }
        }
        onePerPhoto()
        // Faces left over that someone's recognizer thinks might be them: offered in Review faces.
        var review: [Int: (id: UUID, chance: Float)] = [:]
        if !rec.isEmpty {
            var counted = Set<String>()   // people already counted in each photo
            if photos {
                for (i, id) in matched.merging(learned, uniquingKeysWith: { a, _ in a }) { counted.insert(owners[i] + "|" + id.uuidString) }
            }
            for i in faces.indices where matched[i] == nil && learned[i] == nil && !ignored.contains(i) {
                guard let top = chances(faces[i], Set((rejected[i] ?? []).compactMap { pIndex[$0] }).union(unborn(i))).first, top.p >= 0.6,
                      anchor[i * P + top.k] >= reach else { continue }
                let id = people[top.k].id
                if photos && counted.contains(owners[i] + "|" + id.uuidString) { continue }
                review[i] = (id, top.p)
            }
        }
        return (matched, learned, review)
    }

    /// A reference face for one person (index into `people`), with the photo's date when known.
    struct Ref { let p: Int; let v: [Float]; let t: Double? }
    /// Kids' faces change: a reference from more than two years before or after the photo counts a little less.
    static let ageGap: Double = 2 * 365.25 * 86_400, agePenalty: Float = 0.03

    /// How close each face in `which` is to each person (their closest reference), as rows of `people` numbers.
    /// Done as one matrix multiply per block of faces, so thousands of references stay quick.
    static func closeness(_ faces: [[Float]], _ which: [Int], when: [Double?], refs: [Ref], people: Int) -> [Float] {
        let d = dim, r = refs.count, P = people
        var out = [Float](repeating: -2, count: which.count * P)
        guard r > 0, P > 0, !which.isEmpty else { return out }
        var rt = [Float](repeating: 0, count: d * r)   // references, one per column
        for (j, ref) in refs.enumerated() { for k in 0..<min(d, ref.v.count) { rt[k * r + j] = ref.v[k] } }
        let owner = refs.map(\.p), stamp = refs.map(\.t)
        let block = 256
        var start = 0
        while start < which.count {
            if Task.isCancelled { break }
            let n = min(block, which.count - start)
            var f = [Float](repeating: 0, count: n * d)
            for a in 0..<n { let v = faces[which[start + a]]; for k in 0..<min(d, v.count) { f[a * d + k] = v[k] } }
            var s = [Float](repeating: 0, count: n * r)
            vDSP_mmul(f, 1, rt, 1, &s, 1, vDSP_Length(n), vDSP_Length(r), vDSP_Length(d))
            for a in 0..<n {
                let base = (start + a) * P, row = a * r
                if let ft = when[which[start + a]] {
                    for j in 0..<r {
                        var v = s[row + j]
                        if let rtm = stamp[j], abs(ft - rtm) > ageGap { v -= agePenalty }
                        if v > out[base + owner[j]] { out[base + owner[j]] = v }
                    }
                } else {
                    for j in 0..<r where s[row + j] > out[base + owner[j]] { out[base + owner[j]] = s[row + j] }
                }
            }
            start += n
        }
        return out
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

/// Who's Who's last answer (which face is whom, and what to ask about), kept with a fingerprint of everything it
/// depends on, so it's only worked out again when something changed. On this iPhone only; it holds face keys
/// (photo id plus a hash), never face prints, and goes when Who's Who is turned off.
struct PeopleCache: Codable {
    var signature: UInt64
    var matched: [String: UUID] = [:]
    var learned: [String: UUID] = [:]
    var review: [String: UUID] = [:]
    var chance: [String: Float] = [:]

    init(signature: UInt64, faceKeys: [String], matched: [Int: UUID], learned: [Int: UUID], review: [Int: (id: UUID, chance: Float)]) {
        self.signature = signature
        for (i, id) in matched where i < faceKeys.count { self.matched[faceKeys[i]] = id }
        for (i, id) in learned where i < faceKeys.count { self.learned[faceKeys[i]] = id }
        for (i, r) in review where i < faceKeys.count { self.review[faceKeys[i]] = r.id; chance[faceKeys[i]] = r.chance }
    }

    func indexed(_ faceKeys: [String]) -> (matched: [Int: UUID], learned: [Int: UUID], review: [Int: (id: UUID, chance: Float)]) {
        var m: [Int: UUID] = [:], l: [Int: UUID] = [:], r: [Int: (id: UUID, chance: Float)] = [:]
        for (i, k) in faceKeys.enumerated() {
            if let id = matched[k] { m[i] = id }
            if let id = learned[k] { l[i] = id }
            if let id = review[k] { r[i] = (id, chance[k] ?? 0) }
        }
        return (m, l, r)
    }

    /// Order doesn't matter (each part is hashed alone and the hashes combined), so the same library always gives
    /// the same fingerprint. Bump `version` when People.learn changes.
    static let version = 2   // 2: five learning rounds
    static func signature(faceKeys: [String], dates: [Date], people: [Person], threshold: Float,
                          rejected: [Int: Set<UUID>], ignored: Set<Int>, confirmed: [Int: UUID]) -> UInt64 {
        func h(_ s: String) -> UInt64 { Learner.stableHash([s]) }
        var acc: UInt64 = 0, n: UInt64 = 0
        for (i, k) in faceKeys.enumerated() {
            var part = k + "@" + String(Int(dates[i].timeIntervalSinceReferenceDate))
            if let r = rejected[i] { part += "!" + r.map(\.uuidString).sorted().joined(separator: ",") }
            if ignored.contains(i) { part += "~" }
            if let c = confirmed[i] { part += "=" + c.uuidString }
            acc &+= h(part); n &+= 1
        }
        let who = people.sorted { $0.id.uuidString < $1.id.uuidString }.map { p in
            var e: UInt64 = 0
            for x in p.examples ?? [] { var v: UInt64 = 14695981039346656037; for b in x { v = (v ^ UInt64(b)) &* 1099511628211 }; e &+= v }
            return "\(p.id)|\(p.birthday?.timeIntervalSinceReferenceDate ?? 0)|\(p.count)|\(p.namedExamples ?? 0)|\(e)"
        }
        return Learner.stableHash(["v\(version)", "\(threshold)", "\(n)", "\(acc)"] + who)
    }

    static func read(_ u: URL) -> PeopleCache? {
        guard let d = try? Data(contentsOf: u) else { return nil }
        return try? PropertyListDecoder().decode(PeopleCache.self, from: d)
    }
    func write(_ u: URL) {
        guard UserDefaults.standard.bool(forKey: "faceConsent") else { return }   // Who's Who was turned off meanwhile
        let e = PropertyListEncoder(); e.outputFormat = .binary
        if let d = try? e.encode(self) { try? d.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }
}
