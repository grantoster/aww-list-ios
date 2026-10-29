import Foundation

/// What the app learned from Claude's scores: a ridge regression from each photo's on-device fingerprint
/// (Apple's measurements plus a compact picture of the whole scene) to the score Claude gave it.
struct LearnedModel: Codable, Equatable {
    var mean: [Double]
    var std: [Double]
    var weights: [Double]
    var bias: Double
    var lambda: Double
    /// Claude scores it learned from (all of them, after testing).
    var trainedOn: Int
    /// The honest check: trained without a held-back fifth of the days, then compared on those days' Claude scores.
    var tested: Int
    var within1: Double        // share of held-back photos within 1 point of Claude
    var meanGap: Double        // average distance from Claude's score, in points
    var date: Date
    /// The same check for simply guessing the average Claude score every time (to show what the model adds).
    var baselineWithin1: Double? = nil
    var baselineGap: Double? = nil
}

/// What the app learned from Claude's removals: the chance Claude would take a photo off the list
/// (bath, swimwear, no child, AI or edited, ...), from the same on-device fingerprint.
struct LearnedFilter: Codable, Equatable {
    var mean: [Double]
    var std: [Double]
    var weights: [Double]
    var bias: Double
    var lambda: Double
    /// Claude verdicts it learned from, and how many of them were removals.
    var trainedOn: Int
    var removals: Int
    /// The honest check, on a held-back fifth of the days (as for the learned score).
    var tested: Int
    var accuracy: Double           // share of held-back photos where it agrees with Claude (keep or remove)
    var baselineAccuracy: Double   // the same for simply keeping everything
    var caught: Double?            // share of Claude's held-back removals it also removes (nil: none held back)
    var wronglyRemoved: Double?    // share of the photos Claude kept that it would remove (nil: none held back)
    var date: Date
    var testRemovals: Int? = nil   // Claude's removals among the held-back photos
    /// Only used when the check had enough of Claude's removals to mean something and it beat keeping everything
    /// by at least 2 points (so one lucky photo can't switch it on).
    var useful: Bool { (testRemovals ?? 0) >= Learner.minimumTestRemovals && accuracy + 1e-9 >= baselineAccuracy + 0.02 }
}

/// Turns photos into fingerprints and learns Claude's scoring from them. Pure math, so it's unit tested.
enum Learner {
    /// Apple's measurements (each 0...1).
    static let signalCount = 12
    /// Compact picture of the whole photo (Vision's image feature print, projected).
    static let sceneDims = 128
    static var featureCount: Int { signalCount + sceneDims }
    /// Fewest Claude scores before the app trains (plus some held back to check it).
    static let minimumExamples = 60

    // MARK: Fingerprints

    /// Apple's measurements for one photo, each scaled 0...1.
    static func signals(_ s: Signals, apple: Double) -> [Float] {
        let si = s.subjectIndex
        let subj = s.subject
        let others = s.faces.indices.filter { $0 != si }.map { s.faces[$0] }
        let sleepingBaby = s.babyConfidence > 0.5 && (s.faces.count == 1 ? s.faces.first : s.faces.min { $0.area < $1.area })
            .map { $0.eyesClosed && !$0.smile && $0.area > 0.03 } == true
        let close = others.contains { $0.area >= (subj?.area ?? 0) * 0.25 }
        func b(_ v: Bool) -> Float { v ? 1 : 0 }
        return [
            b(subj?.smile == true),
            others.isEmpty ? 0 : Float(others.filter(\.smile).count) / Float(others.count),
            b(sleepingBaby),
            b(close),
            Float(min(1, (subj?.area ?? 0) / 0.12)),
            Float(min(1, s.childConfidence)),
            Float(min(1, s.babyConfidence)),
            Float(min(1, max(0, s.sharpness))),
            Float(min(6, s.faces.count)) / 6,
            b(subj?.eyesClosed == true),
            Float(min(1, max(0, apple))),
            b(!s.labels.isEmpty)
        ]
    }

    /// Packs a fingerprint into bytes: Apple's measurements as 0–255, the scene picture as signed bytes.
    static func encode(signals: [Float], scene: Data) -> Data {
        var d = Data(signals.prefix(signalCount).map { UInt8(max(0, min(255, ($0 * 255).rounded()))) })
        d.append(scene.prefix(sceneDims))
        if d.count < featureCount { d.append(Data(count: featureCount - d.count)) }
        return d
    }

    static func decode(_ d: Data) -> [Double]? {
        guard d.count == featureCount else { return nil }
        let bytes = [UInt8](d)
        let sig = bytes[0..<signalCount].map { Double($0) / 255 }
        let scene = bytes[signalCount...].map { Double(Int8(bitPattern: $0)) / 127 }
        return sig + scene
    }

    // MARK: Learning

    /// A hash that's the same on every launch (Swift's Hasher is seeded per run), for "anything new to learn?".
    static func stableHash(_ parts: [String]) -> UInt64 {
        var h: UInt64 = 14695981039346656037
        for p in parts { for b in p.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }; h = (h ^ 0x1F) &* 1099511628211 }
        return h
    }

    /// Photos are grouped by the day they were taken, so near-identical shots from one outing never end up on
    /// both sides of the test (which would make the accuracy look better than it is).
    static func group(_ date: Date) -> UInt64 {
        // A fixed time zone (US Central), so the split doesn't move when the phone travels.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        var h: UInt64 = 14695981039346656037
        for b in "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)".utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
    /// Stable 1-in-5 held-back split, by day.
    static func heldBack(_ date: Date) -> Bool { group(date) % 5 == 0 }

    struct Fit { var mean: [Double]; var std: [Double]; var w: [Double]; var bias: Double }

    /// Ridge regression on standardized features: w = (XᵀX + λI)⁻¹ Xᵀ(y − ȳ).
    static func fit(_ x: [[Double]], _ y: [Double], lambda: Double) -> Fit? {
        guard let d = x.first?.count, x.count >= 2, y.count == x.count else { return nil }
        let n = Double(x.count)
        var mean = [Double](repeating: 0, count: d), std = [Double](repeating: 0, count: d)
        for r in x { for j in 0..<d { mean[j] += r[j] } }
        for j in 0..<d { mean[j] /= n }
        for r in x { for j in 0..<d { std[j] += (r[j] - mean[j]) * (r[j] - mean[j]) } }
        for j in 0..<d { std[j] = max((std[j] / n).squareRoot(), 1e-6) }
        let ybar = y.reduce(0, +) / n
        var a = [Double](repeating: 0, count: d * d), rhs = [Double](repeating: 0, count: d)
        var z = [Double](repeating: 0, count: d)
        for (i, r) in x.enumerated() {
            for j in 0..<d { z[j] = (r[j] - mean[j]) / std[j] }
            let yi = y[i] - ybar
            for j in 0..<d {
                rhs[j] += z[j] * yi
                let zj = z[j]
                if zj == 0 { continue }
                for k in j..<d { a[j * d + k] += zj * z[k] }
            }
        }
        for j in 0..<d { for k in 0..<j { a[j * d + k] = a[k * d + j] }; a[j * d + j] += lambda }
        guard let w = solve(a, rhs, d) else { return nil }
        return Fit(mean: mean, std: std, w: w, bias: ybar)
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ m: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var a = m, x = b
        for c in 0..<n {
            var p = c
            for r in (c + 1)..<max(c + 1, n) where abs(a[r * n + c]) > abs(a[p * n + c]) { p = r }
            guard abs(a[p * n + c]) > 1e-12 else { return nil }
            if p != c {
                for k in 0..<n { a.swapAt(c * n + k, p * n + k) }
                x.swapAt(c, p)
            }
            let piv = a[c * n + c]
            for r in (c + 1)..<max(c + 1, n) {
                let f = a[r * n + c] / piv
                if f == 0 { continue }
                for k in c..<n { a[r * n + k] -= f * a[c * n + k] }
                x[r] -= f * x[c]
            }
        }
        var out = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = x[r]
            for k in (r + 1)..<max(r + 1, n) { s -= a[r * n + k] * out[k] }
            out[r] = s / a[r * n + r]
        }
        return out
    }

    static func predict(_ f: Fit, _ x: [Double]) -> Double {
        var s = f.bias
        for j in 0..<min(x.count, f.w.count) { s += f.w[j] * (x[j] - f.mean[j]) / f.std[j] }
        return max(1, min(10, s))
    }

    static func predict(_ m: LearnedModel, _ x: [Double]) -> Double {
        predict(Fit(mean: m.mean, std: m.std, w: m.weights, bias: m.bias), x)
    }

    /// The filter's chance (0...1) that Claude would remove a photo; it removes at 0.5 or more.
    static func removalChance(_ f: LearnedFilter, _ x: [Double]) -> Double {
        var v = f.bias
        for j in 0..<min(x.count, f.weights.count) { v += f.weights[j] * (x[j] - f.mean[j]) / f.std[j] }
        return max(0, min(1, v))
    }
    static let removeAt = 0.5
    static let minimumRemovals = 10
    static let minimumTestRemovals = 5

    /// Learns Claude's removals from (photo date, fingerprint, removed?), with the same day-grouped held-back
    /// fifth and 4-fold choice of regularization as the learned score. Nil until there are enough verdicts
    /// (and enough removals among them).
    static func trainFilter(_ examples: [(date: Date, x: [Double], removed: Bool)]) -> LearnedFilter? {
        let test = examples.filter { heldBack($0.date) }, train = examples.filter { !heldBack($0.date) }
        guard train.count >= minimumExamples, test.count >= 10,
              train.filter(\.removed).count >= minimumRemovals else { return nil }
        func y(_ e: (date: Date, x: [Double], removed: Bool)) -> Double { e.removed ? 1 : 0 }
        func chance(_ f: Fit, _ x: [Double]) -> Double {
            var v = f.bias
            for j in 0..<min(x.count, f.w.count) { v += f.w[j] * (x[j] - f.mean[j]) / f.std[j] }
            return max(0, min(1, v))
        }
        func fold(_ d: Date) -> UInt64 { (group(d) / 5) % 4 }
        var bestLambda = 100.0, bestErr = Double.infinity
        for lambda in [1.0, 10, 100, 1000] {
            var total = 0.0, count = 0
            for k in 0..<UInt64(4) {
                let fitPart = train.filter { fold($0.date) != k }, checkPart = train.filter { fold($0.date) == k }
                guard !checkPart.isEmpty, let f = fit(fitPart.map(\.x), fitPart.map(y), lambda: lambda) else { continue }
                for e in checkPart { let d = chance(f, e.x) - y(e); total += d * d; count += 1 }
            }
            if count > 0, total / Double(count) < bestErr { bestErr = total / Double(count); bestLambda = lambda }
        }
        guard let f = fit(train.map(\.x), train.map(y), lambda: bestLambda),
              let all = fit(examples.map(\.x), examples.map(y), lambda: bestLambda) else { return nil }
        let calls = test.map { (removed: $0.removed, says: chance(f, $0.x) >= removeAt) }
        let agree = Double(calls.filter { $0.removed == $0.says }.count) / Double(calls.count)
        let keepAll = Double(calls.filter { !$0.removed }.count) / Double(calls.count)
        let removed = calls.filter(\.removed), kept = calls.filter { !$0.removed }
        return LearnedFilter(mean: all.mean, std: all.std, weights: all.w, bias: all.bias, lambda: bestLambda,
                             trainedOn: examples.count, removals: examples.filter(\.removed).count, tested: test.count,
                             accuracy: agree, baselineAccuracy: keepAll,
                             caught: removed.isEmpty ? nil : Double(removed.filter(\.says).count) / Double(removed.count),
                             wronglyRemoved: kept.isEmpty ? nil : Double(kept.filter(\.says).count) / Double(kept.count),
                             date: Date(), testRemovals: removed.count)
    }

    /// Learns from (photo date, fingerprint, Claude's score):
    /// 1. holds back a fifth of the days, untouched, for the reported check;
    /// 2. picks the regularization by 4-fold cross-validation on the rest (also grouped by day);
    /// 3. reports how close that model gets on the held-back days, next to just guessing the average;
    /// 4. refits on everything. Nil until there are enough scores.
    static func train(_ examples: [(date: Date, x: [Double], y: Double)]) -> LearnedModel? {
        let test = examples.filter { heldBack($0.date) }, train = examples.filter { !heldBack($0.date) }
        guard train.count >= minimumExamples, test.count >= 10 else { return nil }
        func fold(_ d: Date) -> UInt64 { (group(d) / 5) % 4 }
        var bestLambda = 100.0, bestGap = Double.infinity
        for lambda in [1.0, 10, 100, 1000] {
            var total = 0.0, count = 0
            for k in 0..<UInt64(4) {
                let fitPart = train.filter { fold($0.date) != k }, checkPart = train.filter { fold($0.date) == k }
                guard !checkPart.isEmpty, let f = fit(fitPart.map(\.x), fitPart.map(\.y), lambda: lambda) else { continue }
                for e in checkPart { total += abs(predict(f, e.x) - e.y); count += 1 }
            }
            if count > 0, total / Double(count) < bestGap { bestGap = total / Double(count); bestLambda = lambda }
        }
        guard let f = fit(train.map(\.x), train.map(\.y), lambda: bestLambda),
              let all = fit(examples.map(\.x), examples.map(\.y), lambda: bestLambda) else { return nil }
        let gaps = test.map { abs(predict(f, $0.x) - $0.y) }
        let avg = train.map(\.y).reduce(0, +) / Double(train.count)
        let baseGaps = test.map { abs(avg - $0.y) }
        func within(_ g: [Double]) -> Double { Double(g.filter { $0 <= 1 }.count) / Double(g.count) }
        func mean(_ g: [Double]) -> Double { g.reduce(0, +) / Double(g.count) }
        return LearnedModel(mean: all.mean, std: all.std, weights: all.w, bias: all.bias, lambda: bestLambda,
                            trainedOn: examples.count, tested: test.count, within1: within(gaps), meanGap: mean(gaps),
                            date: Date(), baselineWithin1: within(baseGaps), baselineGap: mean(baseGaps))
    }
}

/// The learned score and removal filter as a few KB of text: copied out of one phone (Settings → Copy learning)
/// and built into the app as the starting point for new installs (Resources/BuiltInLearning.json).
/// Only numbers: no photos, faces, captions or dates of photos.
struct LearningPack: Codable {
    var version = 1
    var model: LearnedModel?
    var filter: LearnedFilter?
    // The long arrays, as base64 little-endian Float32 (the fields above carry them empty).
    var modelArrays: [String]?
    var filterArrays: [String]?

    static func pack(_ a: [Double]) -> String {
        var d = Data(capacity: a.count * 4)
        for v in a { withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        return d.base64EncodedString()
    }
    static func unpack(_ s: String) -> [Double]? {
        guard let d = Data(base64Encoded: s), d.count % 4 == 0 else { return nil }
        let b = [UInt8](d)
        var out: [Double] = []
        out.reserveCapacity(b.count / 4)
        for i in stride(from: 0, to: b.count, by: 4) {
            var u = UInt32(b[i])
            u |= UInt32(b[i + 1]) << 8
            u |= UInt32(b[i + 2]) << 16
            u |= UInt32(b[i + 3]) << 24
            out.append(Double(Float(bitPattern: u)))
        }
        return out
    }

    init(model: LearnedModel?, filter: LearnedFilter?) {
        if var m = model {
            modelArrays = [m.mean, m.std, m.weights].map(Self.pack)
            m.mean = []; m.std = []; m.weights = []
            self.model = m
        }
        if var f = filter {
            filterArrays = [f.mean, f.std, f.weights].map(Self.pack)
            f.mean = []; f.std = []; f.weights = []
            self.filter = f
        }
    }

    func text() -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys; e.dateEncodingStrategy = .secondsSince1970
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Reads a pack back; parts that don't fit this version of the app (wrong fingerprint size) are dropped.
    static func read(_ text: String) -> (model: LearnedModel?, filter: LearnedFilter?) {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let p = try? d.decode(LearningPack.self, from: data) else { return (nil, nil) }
        func arrays(_ s: [String]?) -> [[Double]]? {
            guard let s, s.count == 3 else { return nil }
            let a = s.compactMap(unpack)
            return a.count == 3 && a.allSatisfy({ $0.count == Learner.featureCount }) ? a : nil
        }
        var model: LearnedModel?, filter: LearnedFilter?
        if var m = p.model, let a = arrays(p.modelArrays) { m.mean = a[0]; m.std = a[1]; m.weights = a[2]; model = m }
        if var f = p.filter, let a = arrays(p.filterArrays) { f.mean = a[0]; f.std = a[1]; f.weights = a[2]; filter = f }
        return (model, filter)
    }
}
