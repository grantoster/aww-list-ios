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
    /// Labels that keep a photo off the list. Checked with Apple's high-recall filter, so borderline cases are left out.
    static let blocked: [String: String] = [
        "bath": "bath", "bathroom": "bath", "shower": "bath", "jacuzzi": "bath", "bathrobe": "bath",
        "swimsuit": "swimwear", "swimming": "swimwear", "pool": "swimwear", "beach": "swimwear",
        "underwater": "swimwear", "waterpolo": "swimwear", "sunbathing": "swimwear",
        "diaper": "undressed",
        "document": "document", "receipt": "document", "screenshot": "screenshot"
    ]

    init() {
        // If a future iOS renames a label, say so in the log instead of silently never matching.
        if let ids = try? VNClassifyImageRequest().supportedIdentifiers() {
            let missing = Set(Self.blocked.keys).union(Self.childLabels).subtracting(ids)
            if !missing.isEmpty { NSLog("Aww List: classifier labels not found on this iOS: \(missing.sorted())") }
        }
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
            if s.blockedLabel == nil, let reason = Self.blocked[id],
               obs.confidence > 0.5 || (obs.hasPrecisionRecallCurve && obs.hasMinimumPrecision(0.1, forRecall: 0.9)) {
                s.blockedLabel = reason
            }
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
        var subjectBox = CGRect.zero
        for o in faceObs {
            let box = o.boundingBox
            var face = FaceSignal(area: Double(box.width * box.height), quality: Double(o.faceCaptureQuality ?? 0))
            if let m = ciFaces.max(by: { iou($0.box, box) < iou($1.box, box) }), iou(m.box, box) > 0.3 {
                face.smile = m.smile
                face.eyesClosed = m.closed
            }
            if face.area > subjectBox.width * subjectBox.height { subjectBox = box }
            s.faces.append(face)
        }
        s.sharpness = sharpness(ci, box: subjectBox)
        return s
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    /// Renders the face crop to a 128 px grayscale square and measures its sharpness.
    private func sharpness(_ ci: CIImage, box: CGRect) -> Double {
        let e = ci.extent
        let r = CGRect(x: e.minX + box.minX * e.width, y: e.minY + box.minY * e.height,
                       width: box.width * e.width, height: box.height * e.height).integral.intersection(e)
        guard !r.isNull, r.width >= 16, r.height >= 16 else { return 0 }
        let side = 128
        let crop = ci.cropped(to: r)
            .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(side) / r.width, y: CGFloat(side) / r.height))
        var px = [UInt8](repeating: 0, count: side * side)
        ciContext.render(crop, toBitmap: &px, rowBytes: side,
                         bounds: CGRect(x: 0, y: 0, width: side, height: side),
                         format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        return Scorer.sharpness(gray: px, side: side)
    }
}
