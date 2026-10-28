import Foundation
import Vision
import CoreImage

/// Runs Apple's on-device Vision models on one image and returns the measured signals.
/// Nothing leaves the phone.
final class Analyzer {
    private let faceDetector = CIDetector(ofType: CIDetectorTypeFace, context: CIContext(options: [.useSoftwareRenderer: false]),
                                          options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])

    // Vision label identifiers that mean a child is in the picture.
    static let childLabels: Set<String> = ["baby", "child", "toddler", "kid", "kids", "infant", "children", "newborn"]
    static let babyLabels: Set<String> = ["baby", "infant", "newborn"]
    // Labels that keep a photo off the list, matched as substrings.
    static let blockedFragments: [(fragment: String, reason: String)] = [
        ("swim", "swimwear"), ("bikini", "swimwear"), ("bathtub", "bath"), ("bathing", "bath"),
        ("underwear", "undressed"), ("document", "document"), ("receipt", "document"), ("screenshot", "screenshot"),
        ("meme", "meme"), ("collage", "collage")
    ]

    func analyze(_ image: CGImage, orientation: CGImagePropertyOrientation) -> Signals {
        var s = Signals()

        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do { try handler.perform([classify, faces]) } catch { return s }

        for obs in classify.results ?? [] where obs.confidence > 0.05 {
            let id = obs.identifier.lowercased()
            let c = Double(obs.confidence)
            if Self.childLabels.contains(id) { s.childConfidence = max(s.childConfidence, c) }
            if Self.babyLabels.contains(id) { s.babyConfidence = max(s.babyConfidence, c) }
            if c > 0.5, s.blockedLabel == nil, let hit = Self.blockedFragments.first(where: { id.contains($0.fragment) }) {
                s.blockedLabel = hit.reason
            }
        }

        let faceObs = faces.results ?? []
        s.faceCount = faceObs.count
        s.bestFaceQuality = Double(faceObs.compactMap { $0.faceCaptureQuality }.max() ?? 0)
        s.largestFaceArea = Double(faceObs.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0)

        if s.faceCount > 0, let detector = faceDetector {
            let ci = CIImage(cgImage: image).oriented(orientation)
            let feats = detector.features(in: ci, options: [CIDetectorSmile: true, CIDetectorEyeBlink: true])
            for case let f as CIFaceFeature in feats {
                if f.hasSmile { s.smiles += 1 }
                if f.leftEyeClosed || f.rightEyeClosed { s.closedEyes += 1 }
            }
        }
        return s
    }
}
