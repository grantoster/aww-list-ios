import Foundation
import Vision
import CoreImage
import ImageIO

/// Runs Apple's on-device Vision models on one image and returns the measured signals.
/// Nothing leaves the phone.
final class Analyzer {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private lazy var faceDetector = CIDetector(ofType: CIDetectorTypeFace, context: ciContext,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])

    /// Vision classifier labels that mean a child is in the picture (exact identifiers from Apple's taxonomy).
    static let childLabels: Set<String> = ["baby", "child"]
    static let babyLabels: Set<String> = ["baby"]
    /// Labels that keep a photo off the list, checked with Apple's high-recall filter so borderline cases are left out.
    /// Exact names from Apple's published taxonomy; diapers are fine, so "diaper" is deliberately not here.
    static let blockedExact: [String: String] = [
        "bath": "bath", "bathroom": "bath", "shower": "bath", "jacuzzi": "bath", "bathrobe": "bath",
        "swimsuit": "swimwear", "swimming": "swimwear", "pool": "swimwear", "beach": "swimwear",
        "underwater": "swimwear", "waterpolo": "swimwear", "sunbathing": "swimwear",
        "watersport": "swimwear",
        "surfing": "swimwear", "surfboard": "swimwear", "bodyboard": "swimwear", "wetsuit": "swimwear", "diving": "swimwear",
        "sandcastle": "swimwear", "snorkeling": "swimwear", "scuba": "swimwear", "wakeboarding": "swimwear",
        "kiteboarding": "swimwear", "windsurfing": "swimwear",
        "document": "document", "receipt": "document", "screenshot": "screenshot"
    ]
    /// Water scenes: a swimsuit with a covered chest gets past the shirtless check, so the scene decides. These fire on
    /// plenty of fully clothed photos too (a lake walk, a ferry), so they need a confident label and don't hide nearby shots.
    static let waterScenes: Set<String> = ["lake", "ocean", "shore", "water_body", "waterways", "river", "creek", "waterfall",
                                           "water", "sprinkler", "fountain"]
    /// Name fragments matched against whatever labels this iOS actually supports, so a renamed or new label
    /// (bathtub, hot_tub, swimming_pool, water_park, ...) is still caught.
    static let blockedFragments: [(String, String)] = [
        ("bath", "bath"), ("shower", "bath"), ("jacuzzi", "bath"), ("hot_tub", "bath"), ("hottub", "bath"),
        ("swim", "swimwear"), ("pool", "swimwear"), ("beach", "swimwear"), ("bikini", "swimwear"),
        ("water_park", "swimwear"), ("waterpark", "swimwear"), ("splash_pad", "swimwear"),
        ("underwater", "swimwear"), ("waterpolo", "swimwear"), ("snorkel", "swimwear"), ("scuba", "swimwear"),
        ("underwear", "undressed"), ("lingerie", "undressed"), ("nude", "undressed"), ("shirtless", "undressed")
    ]
    /// The full blocklist for a given set of supported labels: the exact names plus every label containing a fragment.
    static func blocklist(for supported: [String]) -> [String: String] {
        var out = blockedExact
        for id in supported {
            let l = id.lowercased()
            if out[id] == nil, let hit = blockedFragments.first(where: { l.contains($0.0) }) { out[id] = hit.1 }
        }
        return out
    }
    private let blocked: [String: String]

    init() {
        let ids = (try? VNClassifyImageRequest().supportedIdentifiers()) ?? []
        blocked = Self.blocklist(for: ids)
        let missing = Set(Self.blockedExact.keys).union(Self.childLabels).subtracting(ids)
        if !ids.isEmpty && !missing.isEmpty { NSLog("Aww List: classifier labels not on this iOS (fragments still apply): \(missing.sorted())") }
    }

    /// Nil when Vision failed, so the caller stores nothing and the photo is tried again on the next scan.
    func analyze(_ image: CGImage, orientation: CGImagePropertyOrientation) -> Signals? {
        var s = Signals()

        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do { try handler.perform([classify, faces]) } catch { return nil }

        for obs in classify.results ?? [] {
            let id = obs.identifier
            if s.blockedLabel == nil, let reason = blocked[id],
               obs.confidence > 0.5 || (obs.hasPrecisionRecallCurve && obs.hasMinimumPrecision(0.1, forRecall: 0.9)) {
                s.blockedLabel = reason
            }
            if s.waterScene == false, Self.waterScenes.contains(id), obs.confidence > 0.5 { s.waterScene = true }
            if Self.childLabels.contains(id) {
                s.childConfidence = max(s.childConfidence, Double(obs.confidence))
                if obs.hasPrecisionRecallCurve && obs.hasMinimumRecall(0.01, forPrecision: 0.9) { s.childPrecise = true }
            }
            if Self.babyLabels.contains(id) { s.babyConfidence = max(s.babyConfidence, Double(obs.confidence)) }
        }

        let faceObs = faces.results ?? []
        guard !faceObs.isEmpty else { return s }

        // Vision boxes and CIDetector boxes are both bottom-left origin on the upright image; match them by overlap.
        let ci = CIImage(cgImage: image).oriented(orientation)
        let e = ci.extent
        var ciFaces: [(box: CGRect, smile: Bool, closed: Bool)] = []
        if let detector = faceDetector {
            for case let f as CIFaceFeature in detector.features(in: ci, options: [CIDetectorSmile: true, CIDetectorEyeBlink: true]) {
                let b = CGRect(x: (f.bounds.minX - e.minX) / e.width, y: (f.bounds.minY - e.minY) / e.height,
                               width: f.bounds.width / e.width, height: f.bounds.height / e.height)
                ciFaces.append((b, f.hasSmile, f.leftEyeClosed && f.rightEyeClosed))
            }
        }
        var subjectBox = CGRect.zero, subjectArea: CGFloat = -1
        for o in faceObs {
            let box = o.boundingBox
            var face = FaceSignal(area: Double(box.width * box.height), quality: Double(o.faceCaptureQuality ?? 0))
            if let m = ciFaces.max(by: { iou($0.box, box) < iou($1.box, box) }), iou(m.box, box) > 0.3 {
                face.smile = m.smile
                face.eyesClosed = m.closed
            }
            if box.width * box.height > subjectArea { subjectBox = box; subjectArea = box.width * box.height }
            // Shirtless check on every face big enough to measure (about 30 px tall or more), near or far.
            if box.height >= 0.04 {
                face.bareTorso = bareTorso(ci, face: box)
                // A bare chest is fine only on a baby: ask the classifier about this person alone.
                if face.bareTorso >= Scorer.bareTorsoLimit { face.baby = babyConfidence(handler, around: box) }
            }
            s.faces.append(face)
        }
        s.sharpness = sharpness(ci, box: subjectBox)
        return s
    }

    /// "baby" label confidence for one person: the classifier run on their face and chest only.
    private func babyConfidence(_ handler: VNImageRequestHandler, around b: CGRect) -> Double? {
        let roi = CGRect(x: b.minX - b.width * 0.3, y: b.minY - b.height * 1.8, width: b.width * 1.6, height: b.height * 2.8)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !roi.isNull, roi.width > 0.05, roi.height > 0.05 else { return nil }
        let req = VNClassifyImageRequest()
        req.regionOfInterest = roi
        guard (try? handler.perform([req])) != nil else { return nil }
        return Double(req.results?.first { $0.identifier == "baby" }?.confidence ?? 0)
    }

    /// Compares the skin tone in the middle of the face with the chest below it. The band starts half a face below
    /// the chin, past the neck and collarbone, so tank tops and V-necks don't count as shirtless.
    private func bareTorso(_ ci: CIImage, face b: CGRect) -> Double {
        let faceCore = CGRect(x: b.minX + b.width * 0.25, y: b.minY + b.height * 0.2, width: b.width * 0.5, height: b.height * 0.45)
        let chest = CGRect(x: b.minX - b.width * 0.1, y: b.minY - b.height * 1.8, width: b.width * 1.2, height: b.height * 1.3)
        // Judge whatever part of the chest is in the photo, as long as there's enough of it (close-ups included).
        let inside = chest.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !inside.isNull, inside.width * inside.height >= chest.width * chest.height * 0.3, inside.height >= b.height * 0.4,
              let f = rgb(ci, faceCore, side: 16), let t = rgb(ci, inside, side: 32) else { return 0 }
        return Scorer.skinMatch(face: f, torso: t)
    }

    /// Renders a normalized region to a small RGB buffer.
    private func rgb(_ ci: CIImage, _ n: CGRect, side: Int) -> [UInt8]? {
        let e = ci.extent
        let r = CGRect(x: e.minX + n.minX * e.width, y: e.minY + n.minY * e.height,
                       width: n.width * e.width, height: n.height * e.height).integral.intersection(e)
        guard !r.isNull, r.width >= 4, r.height >= 4 else { return nil }
        let img = ci.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(side) / r.width, y: CGFloat(side) / r.height))
        var px = [UInt8](repeating: 0, count: side * side * 4)
        ciContext.render(img, toBitmap: &px, rowBytes: side * 4, bounds: CGRect(x: 0, y: 0, width: side, height: side),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var out = [UInt8](); out.reserveCapacity(side * side * 3)
        for i in stride(from: 0, to: px.count, by: 4) { out += [px[i], px[i + 1], px[i + 2]] }
        return out
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    /// Renders the face crop to grayscale (shrunk to 128 px at most, never enlarged) and measures its sharpness.
    private func sharpness(_ ci: CIImage, box: CGRect) -> Double {
        let e = ci.extent
        let r = CGRect(x: e.minX + box.minX * e.width, y: e.minY + box.minY * e.height,
                       width: box.width * e.width, height: box.height * e.height).integral.intersection(e)
        guard !r.isNull, r.width >= 8, r.height >= 8 else { return 0 }
        let k = min(1, 128 / max(r.width, r.height))
        let w = max(3, Int(r.width * k)), h = max(3, Int(r.height * k))
        let crop = ci.cropped(to: r)
            .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / r.width, y: CGFloat(h) / r.height))
        var px = [UInt8](repeating: 0, count: w * h)
        ciContext.render(crop, toBitmap: &px, rowBytes: w,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        return Scorer.sharpness(gray: px, width: w, height: h)
    }
}
