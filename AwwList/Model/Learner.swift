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
    /// The honest check: trained without a held-back fifth of Claude's scores, then compared on those.
    var tested: Int
    var within1: Double        // share of held-back photos within 1 point of Claude
    var meanGap: Double        // average distance from Claude's score, in points
    var date: Date
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

    /// Stable 1-in-5 split by photo id, so the held-back photos are the same every time.
    static func heldBack(_ id: String) -> Bool {
        var h: UInt64 = 14695981039346656037
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h % 5 == 0
    }

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

    /// Learns from (id, fingerprint, Claude's score). Picks the regularization on the held-back fifth, reports
    /// how close it gets there, then refits on everything. Nil until there are enough scores.
    static func train(_ examples: [(id: String, x: [Double], y: Double)]) -> LearnedModel? {
        let test = examples.filter { heldBack($0.id) }, train = examples.filter { !heldBack($0.id) }
        guard train.count >= minimumExamples, test.count >= 10 else { return nil }
        var best: (lambda: Double, gap: Double, within: Double)?
        for lambda in [1.0, 10, 100, 1000] {
            guard let f = fit(train.map(\.x), train.map(\.y), lambda: lambda) else { continue }
            let gaps = test.map { abs(predict(f, $0.x) - $0.y) }
            let gap = gaps.reduce(0, +) / Double(gaps.count)
            let within = Double(gaps.filter { $0 <= 1 }.count) / Double(gaps.count)
            if best == nil || gap < best!.gap { best = (lambda, gap, within) }
        }
        guard let b = best, let all = fit(examples.map(\.x), examples.map(\.y), lambda: b.lambda) else { return nil }
        return LearnedModel(mean: all.mean, std: all.std, weights: all.w, bias: all.bias, lambda: b.lambda,
                            trainedOn: examples.count, tested: test.count, within1: b.within, meanGap: b.gap, date: Date())
    }
}
