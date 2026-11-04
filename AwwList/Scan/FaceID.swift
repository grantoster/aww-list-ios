import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision

/// Who's Who's face recognizer: an on-device face-identity model (InsightFace's w600k MobileFaceNet, converted to
/// Core ML; its pretrained weights are licensed for non-commercial use only). Each face is lined up by its eyes and
/// mouth corners to the model's standard 112 × 112 layout, then turned into 512 numbers that are close together for
/// the same person and far apart for different people. Nothing leaves the iPhone.
enum FaceID {
    static let side = 112
    static let dims = 512
    /// Bumped when faces are found differently, so listed photos are read again: 2 = up to 8 faces, down to about
    /// 1/300 of the photo (was 4 faces of at least 1/170).
    static let version = 3   // 3: how each face looks (smile, eyes, quality, head turn), for ranking a person's best photos
    static let maxFaces = 8, minArea = 0.003

    /// The standard ArcFace layout (pixels, top-left origin): left eye, right eye, left and right mouth corners
    /// ("left" as seen in the image).
    static let template: [CGPoint] = [CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
                                      CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041)]

    private static let lock = NSLock()
    private static let model: MLModel? = {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine   // not the GPU, which overnight background scans may not get
        let bundles = [Bundle.main, Bundle(for: BundleToken.self)]
        for b in bundles {
            if let u = b.url(forResource: "FaceEmbedder", withExtension: "mlmodelc"), let m = try? MLModel(contentsOf: u, configuration: cfg) { return m }
        }
        for b in bundles {
            // Not compiled at build time: compile it here (into a temporary folder).
            if let p = b.url(forResource: "FaceEmbedder", withExtension: "mlpackage"), let c = try? MLModel.compileModel(at: p),
               let m = try? MLModel(contentsOf: c, configuration: cfg) { return m }
        }
        return nil
    }()
    private final class BundleToken {}
    static var available: Bool { model != nil }

    /// The face's identity numbers (unit length) from an already lined-up 112 × 112 picture, or nil if it fails.
    static func embedding(_ pixels: CVPixelBuffer) -> [Float]? {
        guard let model else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(pixelBuffer: pixels)]),
              let out = try? model.prediction(from: input),
              let arr = out.featureValue(for: "embedding")?.multiArrayValue, arr.count == dims else { return nil }
        var v = [Float](repeating: 0, count: dims)
        for i in 0..<dims { v[i] = arr[i].floatValue }
        let n = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard n > 1e-6, n.isFinite else { return nil }
        return v.map { $0 / n }
    }

    /// Packs identity numbers into 512 signed bytes, scaled so the largest uses the full range (the scale doesn't
    /// matter: prints are compared by angle).
    static func pack(_ v: [Float]) -> Data {
        let m = max(v.map(abs).max() ?? 0, 1e-9)
        return Data(v.map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 / m * 127).rounded())))) })
    }

    /// The similarity transform (scale, turn, shift) that best maps `from` onto `to` (least squares, no mirroring).
    static func similarity(from p: [CGPoint], to q: [CGPoint]) -> CGAffineTransform? {
        guard p.count == q.count, p.count >= 2 else { return nil }
        let n = CGFloat(p.count)
        let pm = CGPoint(x: p.map(\.x).reduce(0, +) / n, y: p.map(\.y).reduce(0, +) / n)
        let qm = CGPoint(x: q.map(\.x).reduce(0, +) / n, y: q.map(\.y).reduce(0, +) / n)
        var num1: CGFloat = 0, num2: CGFloat = 0, den: CGFloat = 0
        for (a, b) in zip(p, q) {
            let px = a.x - pm.x, py = a.y - pm.y, qx = b.x - qm.x, qy = b.y - qm.y
            num1 += px * qx + py * qy; num2 += px * qy - py * qx; den += px * px + py * py
        }
        guard den > 1e-9 else { return nil }
        let a = num1 / den, b = num2 / den
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: qm.x - (a * pm.x - b * pm.y), ty: qm.y - (b * pm.x + a * pm.y))
    }

    /// Where the template points sit in Core Image's bottom-left-origin 112 × 112 output.
    static var templateBottomLeft: [CGPoint] { template.map { CGPoint(x: $0.x, y: CGFloat(side) - $0.y) } }

    /// The four alignment points of a face (image coordinates, bottom-left origin), from Vision's landmarks.
    static func points(_ l: VNFaceLandmarks2D, imageSize: CGSize) -> [CGPoint]? {
        func center(_ r: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let pts = r?.pointsInImage(imageSize: imageSize), !pts.isEmpty else { return nil }
            return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
        }
        guard let e1 = center(l.leftPupil) ?? center(l.leftEye), let e2 = center(l.rightPupil) ?? center(l.rightEye),
              let lips = l.outerLips?.pointsInImage(imageSize: imageSize), lips.count >= 2 else { return nil }
        // Left and right along the face's own axis (from the mouth up to the eyes), so a tilted or lying-down face
        // lines up the same way as an upright one.
        let em = CGPoint(x: (e1.x + e2.x) / 2, y: (e1.y + e2.y) / 2)
        let mm = CGPoint(x: lips.map(\.x).reduce(0, +) / CGFloat(lips.count), y: lips.map(\.y).reduce(0, +) / CGFloat(lips.count))
        let up = CGPoint(x: em.x - mm.x, y: em.y - mm.y)
        guard up.x * up.x + up.y * up.y > 1e-6 else { return nil }
        func side(_ p: CGPoint) -> CGFloat { p.x * up.y - p.y * up.x }   // along "right" = (up.y, −up.x)
        let eyes = [e1, e2].sorted { side($0) < side($1) }
        guard let m1 = lips.min(by: { side($0) < side($1) }), let m2 = lips.max(by: { side($0) < side($1) }) else { return nil }
        return [eyes[0], eyes[1], m1, m2]
    }

    /// The lined-up 112 × 112 face, ready for the model. Without landmarks, a square crop around the face box.
    static func aligned(_ ci: CIImage, box: [Double], landmarks: VNFaceLandmarks2D?, context: CIContext) -> CVPixelBuffer? {
        guard box.count == 4 else { return nil }
        let e = ci.extent
        let s = CGFloat(side)
        var t: CGAffineTransform?
        if let l = landmarks, let pts = points(l, imageSize: e.size) {
            let shifted = pts.map { CGPoint(x: $0.x + e.minX, y: $0.y + e.minY) }
            t = similarity(from: shifted, to: templateBottomLeft)
        }
        if t == nil {
            // A square around the face box, a little bigger than it (roughly the model's framing).
            let w = CGFloat(box[2]) * e.width, h = CGFloat(box[3]) * e.height
            let side0 = max(w, h) * 1.15
            let cx = e.minX + (CGFloat(box[0]) + CGFloat(box[2]) / 2) * e.width
            let cy = e.minY + (CGFloat(box[1]) + CGFloat(box[3]) / 2) * e.height
            guard side0 > 8 else { return nil }
            let k = s / side0
            t = CGAffineTransform(translationX: -(cx - side0 / 2), y: -(cy - side0 / 2)).concatenating(CGAffineTransform(scaleX: k, y: k))
        }
        guard let t else { return nil }
        let out = ci.clampedToExtent().transformed(by: t).cropped(to: CGRect(x: 0, y: 0, width: s, height: s))
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        context.render(out, to: pb, bounds: CGRect(x: 0, y: 0, width: s, height: s), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pb
    }

    /// Face prints for Who's Who from the (up to 8) largest faces of an upright photo. Nil when the recognizer
    /// couldn't run (then the photo keeps what it had and is read again on a later scan).
    static func records(_ image: CGImage, orientation: CGImagePropertyOrientation, faces: [FaceSignal],
                        context: CIContext) -> [FaceRecord]? {
        guard available else { return nil }
        let chosen = Array(faces.filter { $0.box.count == 4 && $0.area >= minArea }.sorted { $0.area > $1.area }.prefix(maxFaces))
        guard !chosen.isEmpty else { return [] }
        let ci = CIImage(cgImage: image).oriented(orientation)
        // Landmarks for each face, found where the face already is.
        let req = VNDetectFaceLandmarksRequest()
        req.inputFaceObservations = chosen.map {
            VNFaceObservation(boundingBox: CGRect(x: $0.box[0], y: $0.box[1], width: $0.box[2], height: $0.box[3]))
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        let found = (try? handler.perform([req])) != nil ? (req.results ?? []) : []
        var out: [FaceRecord] = []
        for f in chosen {
            let b = CGRect(x: f.box[0], y: f.box[1], width: f.box[2], height: f.box[3])
            // The landmarks that belong to this face (the observation whose box overlaps it most).
            let lm = found.max(by: { overlap($0.boundingBox, b) < overlap($1.boundingBox, b) })
                .flatMap { overlap($0.boundingBox, b) > 0.5 ? $0.landmarks : nil }
            guard let pb = aligned(ci, box: f.box, landmarks: lm, context: context) else { continue }   // too small to read
            guard let v = embedding(pb) else { return nil }
            let shape = lm.map { Analyzer.faceShape($0) } ?? []
            let turn: Float = shape.count == 6 ? Float(shape[4]) : -1
            out.append(FaceRecord(box: f.box.map { Float($0) }, vec: pack(v),
                                  look: [f.expressionRead ? (f.smile ? 1 : 0) : -1, f.expressionRead ? (f.eyesClosed ? 0 : 1) : -1,
                                         Float(min(1, max(0, f.quality))), turn]))
        }
        return out
    }

    /// Intersection over union of two boxes.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height, union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }
}
