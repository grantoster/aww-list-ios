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
    /// A small neural net learned alongside the straight-line formula, and how much of it to use (0...1, picked on
    /// days held out from training). Nil when the formula alone did as well.
    var mlp: MLP? = nil
    var blend: Double? = nil
    /// The same check for the straight-line formula alone (to show what the net adds).
    var linearGap: Double? = nil
    /// Of Claude's top fifth in the held-back check, the share the learning also put in its top fifth.
    var topOverlap: Double? = nil
    /// How many of the scores it learned from were averaged from two Claude passes.
    var averaged: Int? = nil
}

/// A one-hidden-layer neural net (ReLU), with its output in score points. Its inputs are Apple's measurements
/// (standardized) plus the straight-line formula's own guess, so it learns the combinations the formula misses
/// (a big smile only counts if the face is sharp, ...) without having to sift the long scene and face prints.
struct MLP: Codable, Equatable {
    var h: Int
    var w1: [Double]   // h × Learner.netInputs
    var b1: [Double]   // h
    var w2: [Double]   // h
    var b2: Double
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
    /// Apple's measurements (each 0...1): the 12 original ones, then Apple's photo-quality score (and whether
    /// there is one), the "utility photo" flag, six measurements of the main face's shape, and nine of the bodies
    /// in the shot and where the eye goes (Analyzer.poseAndFocus).
    static let signalCount = 30
    /// Compact picture of the whole photo (Vision's image feature print, projected).
    static let sceneDims = 256
    /// Compact picture of the main face (its own feature print, projected): expression, gaze, who.
    static let faceDims = 64
    /// What's in the photo: the confidence of every one of Vision's ~1,300 scene and object labels, folded into
    /// 128 numbers (each label always lands in the same place, on every iPhone and iOS version).
    static let contentDims = 128
    static var featureCount: Int { signalCount + sceneDims + faceDims + contentDims }
    /// The net's inputs: Apple's measurements plus the formula's guess.
    static var netInputs: Int { signalCount + 1 }
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
        var out: [Float] = [
            b(subj?.smile == true),
            others.isEmpty ? 0 : Float(others.filter(\.smile).count) / Float(others.count),
            b(sleepingBaby),
            b(close)
        ]
        out.append(Float(min(1, (subj?.area ?? 0) / 0.12)))
        out.append(Float(min(1, s.childConfidence)))
        out.append(Float(min(1, s.babyConfidence)))
        out.append(Float(min(1, max(0, s.sharpness))))
        out.append(Float(min(6, s.faces.count)) / 6)
        out.append(b(subj?.eyesClosed == true))
        out.append(Float(min(1, max(0, apple))))
        out.append(b(!s.labels.isEmpty))
        let quality: Double = ((s.aesthetic ?? 0) + 1) / 2
        out.append(Float(min(1, max(0, quality))))
        out.append(b(s.aesthetic != nil))
        out.append(b(s.isUtility))
        for i in 0..<6 {
            let v: Double = i < s.faceShape.count ? s.faceShape[i] : 0
            out.append(Float(min(1, max(0, v))))
        }
        for i in 0..<9 {
            let v: Double = i < s.poseAndFocus.count ? s.poseAndFocus[i] : 0
            out.append(Float(min(1, max(0, v))))
        }
        return out
    }

    /// Folds classifier labels into `contentDims` numbers ("feature hashing"): each label adds its confidence,
    /// with a fixed sign, at a fixed place picked from its name. Faint labels (under 5%) are skipped.
    static func content(labels: [(String, Float)]) -> [Float] {
        var out = [Float](repeating: 0, count: contentDims)
        for (id, c) in labels where c >= 0.05 {
            let h = stableHash([id])
            out[Int(h % UInt64(contentDims))] += ((h >> 32) & 1 == 0 ? 1 : -1) * c
        }
        return out
    }

    static func contentBytes(_ v: [Float]) -> Data {
        Data(v.prefix(contentDims).map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 * 127).rounded())))) })
    }

    /// Packs a fingerprint into bytes: Apple's measurements as 0–255, the scene and face pictures as signed bytes.
    static func encode(signals: [Float], scene: Data, face: Data = Data(), content: Data = Data()) -> Data {
        var d = Data(signals.prefix(signalCount).map { UInt8(max(0, min(255, ($0 * 255).rounded()))) })
        if d.count < signalCount { d.append(Data(count: signalCount - d.count)) }
        d.append(scene.prefix(sceneDims))
        if d.count < signalCount + sceneDims { d.append(Data(count: signalCount + sceneDims - d.count)) }
        d.append(face.prefix(faceDims))
        if d.count < signalCount + sceneDims + faceDims { d.append(Data(count: signalCount + sceneDims + faceDims - d.count)) }
        d.append(content.prefix(contentDims))
        if d.count < featureCount { d.append(Data(count: featureCount - d.count)) }
        return d
    }

    static func decode(_ d: Data) -> [Double]? {
        guard d.count == featureCount else { return nil }
        let bytes = [UInt8](d)
        let sig = bytes[0..<signalCount].map { Double($0) / 255 }
        let pics = bytes[signalCount...].map { Double(Int8(bitPattern: $0)) / 127 }
        return sig + pics
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
        let f = Fit(mean: m.mean, std: m.std, w: m.weights, bias: m.bias)
        let linear = predict(f, x)
        guard let net = m.mlp, let a = m.blend, a > 0 else { return linear }
        return max(1, min(10, (1 - a) * linear + a * mlpOut(net, netInput(x, f))))
    }

    /// Apple's measurements, standardized, plus the formula's guess (centered on a middling score).
    static func netInput(_ x: [Double], _ f: Fit) -> [Double] {
        var z = (0..<min(signalCount, x.count, f.mean.count)).map { (x[$0] - f.mean[$0]) / f.std[$0] }
        z.append((predict(f, x) - 5.5) / 2)
        return z
    }

    // MARK: Neural net

    static func standardize(_ x: [Double], _ mean: [Double], _ std: [Double]) -> [Double] {
        (0..<min(x.count, mean.count)).map { (x[$0] - mean[$0]) / std[$0] }
    }

    static func mlpOut(_ m: MLP, _ z: [Double]) -> Double {
        let d = z.count
        var out = m.b2
        for j in 0..<m.h {
            var a = m.b1[j]
            let base = j * d
            for k in 0..<d { a += m.w1[base + k] * z[k] }
            if a > 0 { out += m.w2[j] * a }
        }
        return out
    }

    /// Trains the net (Adam, mini-batches of 32, light weight decay) on standardized inputs. With `val`, keeps the
    /// weights from the epoch that did best on it and returns that epoch; otherwise trains exactly `epochs` epochs.
    static func trainMLP(_ X: [[Double]], _ Y: [Double], epochs: Int, hidden h: Int = 32, seed: UInt64 = 7,
                         val: (x: [[Double]], y: [Double])? = nil) -> (net: MLP, epoch: Int)? {
        guard let d = X.first?.count, X.count >= 8, Y.count == X.count else { return nil }
        let n = X.count
        let ybar = Y.reduce(0, +) / Double(n)
        let ysd = max((Y.map { ($0 - ybar) * ($0 - ybar) }.reduce(0, +) / Double(n)).squareRoot(), 1e-6)
        let T = Y.map { ($0 - ybar) / ysd }
        var state = seed &+ 0x9E37_79B9
        func rnd() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(UInt64(1) << 53) }
        func gauss() -> Double { (-2 * log(max(rnd(), 1e-12))).squareRoot() * cos(2 * Double.pi * rnd()) }
        var w1 = (0..<(h * d)).map { _ in gauss() * (2.0 / Double(d)).squareRoot() }
        var b1 = [Double](repeating: 0, count: h)
        var w2 = (0..<h).map { _ in gauss() * (1.0 / Double(h)).squareRoot() }
        var b2 = 0.0
        var m1 = [Double](repeating: 0, count: h * d), v1 = m1
        var mb1 = [Double](repeating: 0, count: h), vb1 = mb1, m2 = mb1, v2 = mb1
        var mb2 = 0.0, vb2 = 0.0
        let lr = 0.003, beta1 = 0.9, beta2 = 0.999, eps = 1e-8, decay = 1e-3, batch = 32
        var step = 0
        func net() -> MLP { MLP(h: h, w1: w1, b1: b1, w2: w2.map { $0 * ysd }, b2: b2 * ysd + ybar) }
        func valLoss() -> Double {
            guard let val, !val.x.isEmpty else { return 0 }
            let m = net()
            return zip(val.x, val.y).map { abs(mlpOut(m, $0.0) - $0.1) }.reduce(0, +) / Double(val.x.count)
        }
        var best = (net: net(), epoch: 0, loss: Double.infinity)
        var order = Array(0..<n)
        var gw1 = [Double](repeating: 0, count: h * d), gb1 = [Double](repeating: 0, count: h), gw2 = gb1
        var act = [Double](repeating: 0, count: h)
        for epoch in 1...max(1, epochs) {
            for i in stride(from: n - 1, to: 0, by: -1) { order.swapAt(i, Int(rnd() * Double(i + 1)) % (i + 1)) }
            var start = 0
            while start < n {
                let idx = order[start..<min(start + batch, n)]
                for i in gw1.indices { gw1[i] = 0 }
                for j in 0..<h { gb1[j] = 0; gw2[j] = 0 }
                var gb2 = 0.0
                for r in idx {
                    let z = X[r]
                    var out = b2
                    for j in 0..<h {
                        var a = b1[j]
                        let base = j * d
                        for k in 0..<d { a += w1[base + k] * z[k] }
                        act[j] = max(0, a)
                        out += w2[j] * act[j]
                    }
                    let g = (out - T[r]) / Double(idx.count)   // squared-error gradient
                    gb2 += g
                    for j in 0..<h where act[j] > 0 {
                        gw2[j] += g * act[j]
                        let gj = g * w2[j]
                        gb1[j] += gj
                        let base = j * d
                        for k in 0..<d { gw1[base + k] += gj * z[k] }
                    }
                }
                step += 1
                let c1 = 1 - pow(beta1, Double(step)), c2 = 1 - pow(beta2, Double(step))
                for i in 0..<(h * d) {
                    let g = gw1[i] + decay * w1[i]
                    m1[i] = beta1 * m1[i] + (1 - beta1) * g; v1[i] = beta2 * v1[i] + (1 - beta2) * g * g
                    w1[i] -= lr * (m1[i] / c1) / ((v1[i] / c2).squareRoot() + eps)
                }
                for j in 0..<h {
                    let g2 = gw2[j] + decay * w2[j]
                    m2[j] = beta1 * m2[j] + (1 - beta1) * g2; v2[j] = beta2 * v2[j] + (1 - beta2) * g2 * g2
                    w2[j] -= lr * (m2[j] / c1) / ((v2[j] / c2).squareRoot() + eps)
                    let g1 = gb1[j]
                    mb1[j] = beta1 * mb1[j] + (1 - beta1) * g1; vb1[j] = beta2 * vb1[j] + (1 - beta2) * g1 * g1
                    b1[j] -= lr * (mb1[j] / c1) / ((vb1[j] / c2).squareRoot() + eps)
                }
                mb2 = beta1 * mb2 + (1 - beta1) * gb2; vb2 = beta2 * vb2 + (1 - beta2) * gb2 * gb2
                b2 -= lr * (mb2 / c1) / ((vb2 / c2).squareRoot() + eps)
                start += batch
            }
            if val != nil {
                let l = valLoss()
                if l < best.loss { best = (net(), epoch, l) }
                else if epoch - best.epoch >= 12 { break }   // stopped improving
            }
        }
        return val != nil ? (best.net, best.epoch) : (net(), epochs)
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
    static func train(_ examples: [(date: Date, x: [Double], y: Double)], averaged: Int = 0,
                      useNet: Bool = true) -> LearnedModel? {
        let test = examples.filter { heldBack($0.date) }, train = examples.filter { !heldBack($0.date) }
        guard train.count >= minimumExamples, test.count >= 10 else { return nil }
        func fold(_ d: Date) -> UInt64 { (group(d) / 5) % 4 }
        var bestLambda = 100.0, bestGap = Double.infinity
        for lambda in [1.0, 10, 100, 1000, 10000] {
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
        // The net's training rows see the formula's out-of-fold guess (as it will on new photos), not its guess on
        // rows it was fitted to; `f` is only used for standardizing.
        func netRows(_ rows: [(date: Date, x: [Double], y: Double)], _ f: Fit) -> [[Double]] {
            var out = rows.map { netInput($0.x, f) }
            for k in 0..<UInt64(4) {
                let idx = rows.indices.filter { fold(rows[$0].date) == k }
                let rest = rows.indices.filter { fold(rows[$0].date) != k }
                guard !idx.isEmpty, rest.count >= 2,
                      let g = fit(rest.map { rows[$0].x }, rest.map { rows[$0].y }, lambda: bestLambda) else { continue }
                for i in idx { out[i][out[i].count - 1] = (predict(g, rows[i].x) - 5.5) / 2 }
            }
            return out
        }

        // The neural net: trained on three folds of the training days, stopped when the fourth stops improving,
        // and blended with the formula by whatever mix does best on that fourth fold.
        var blend = 0.0, epochs = 0
        if useNet {
            let fitPart = train.filter { fold($0.date) != 0 }, valPart = train.filter { fold($0.date) == 0 }
            if fitPart.count >= minimumExamples, valPart.count >= 10,
               let rf = fit(fitPart.map(\.x), fitPart.map(\.y), lambda: bestLambda) {
                let zf = netRows(fitPart, rf), zv = valPart.map { netInput($0.x, rf) }
                if let (net, e) = trainMLP(zf, fitPart.map(\.y), epochs: 150, val: (zv, valPart.map(\.y))), e > 0 {
                    epochs = e
                    var bestErr = Double.infinity
                    for a in [0.0, 0.25, 0.5, 0.75, 1.0] {
                        let err = zip(valPart, zv).map { abs(max(1, min(10, (1 - a) * predict(rf, $0.0.x) + a * mlpOut(net, $0.1))) - $0.0.y) }
                            .reduce(0, +) / Double(valPart.count)
                        if err < bestErr - 1e-9 { bestErr = err; blend = a }
                    }
                }
            }
        }
        // The honest check on held-back days, with the formula and net trained on the training days only.
        var testNet: MLP? = nil
        if blend > 0 { testNet = trainMLP(netRows(train, f), train.map(\.y), epochs: epochs)?.net }
        func testPredict(_ x: [Double]) -> Double {
            let linear = predict(f, x)
            guard let n = testNet else { return linear }
            return max(1, min(10, (1 - blend) * linear + blend * mlpOut(n, netInput(x, f))))
        }
        let preds = test.map { testPredict($0.x) }
        let gaps = zip(preds, test).map { abs($0 - $1.y) }
        let linearGaps = test.map { abs(predict(f, $0.x) - $0.y) }
        let avg = train.map(\.y).reduce(0, +) / Double(train.count)
        let baseGaps = test.map { abs(avg - $0.y) }
        func within(_ g: [Double]) -> Double { Double(g.filter { $0 <= 1 }.count) / Double(g.count) }
        func mean(_ g: [Double]) -> Double { g.reduce(0, +) / Double(g.count) }
        // Top picks: Claude's top fifth of the held-back photos, and how many of them the learning also ranks there.
        let k = max(1, Int((Double(test.count) * 0.2).rounded(.up)))
        // A pick counts when Claude scored it at least as high as its k-th best (so ties can't change the result).
        let kth = test.map(\.y).sorted(by: >)[k - 1]
        let learnedTop = test.indices.sorted { preds[$0] != preds[$1] ? preds[$0] > preds[$1] : $0 < $1 }.prefix(k)
        let overlap = Double(learnedTop.filter { test[$0].y >= kth - 1e-9 }.count) / Double(k)
        // The final net, on everything (same number of epochs).
        var finalNet: MLP? = nil
        if blend > 0 { finalNet = trainMLP(netRows(examples, all), examples.map(\.y), epochs: epochs)?.net }
        return LearnedModel(mean: all.mean, std: all.std, weights: all.w, bias: all.bias, lambda: bestLambda,
                            trainedOn: examples.count, tested: test.count, within1: within(gaps), meanGap: mean(gaps),
                            date: Date(), baselineWithin1: within(baseGaps), baselineGap: mean(baseGaps),
                            mlp: finalNet, blend: finalNet == nil ? 0 : blend, linearGap: mean(linearGaps),
                            topOverlap: overlap, averaged: averaged)
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
    var mlpArrays: [String]?   // the net's w1, b1, w2 (when the score has one)

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
            if var net = m.mlp {
                mlpArrays = [net.w1, net.b1, net.w2].map(Self.pack)
                net.w1 = []; net.b1 = []; net.w2 = []
                m.mlp = net
            }
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
        if var m = p.model, let a = arrays(p.modelArrays) {
            m.mean = a[0]; m.std = a[1]; m.weights = a[2]
            if var net = m.mlp {
                let n = (p.mlpArrays ?? []).compactMap(unpack)
                if n.count == 3, n[0].count == net.h * Learner.netInputs, n[1].count == net.h, n[2].count == net.h {
                    net.w1 = n[0]; net.b1 = n[1]; net.w2 = n[2]; m.mlp = net
                } else { m.mlp = nil; m.blend = 0 }   // a net that doesn't fit: use the formula alone
            }
            model = m
        }
        if var f = p.filter, let a = arrays(p.filterArrays) { f.mean = a[0]; f.std = a[1]; f.weights = a[2]; filter = f }
        return (model, filter)
    }
}
