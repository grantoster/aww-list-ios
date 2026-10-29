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
                                           "water", "sprinkler", "fountain", "lifejacket", "jetski", "flipper"]
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
            if ["baby_shower", "bridal_shower"].contains(where: { l.contains($0) }) { continue }   // parties, not baths
            if l.contains("bathing_suit") { out[id] = "swimwear"; continue }
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

    /// Labels that mean an actual bath or shower (not just a bathroom or a bathrobe).
    static func isActualBath(_ id: String) -> Bool {
        let l = id.lowercased()
        if ["baby_shower", "bridal_shower", "shower_curtain", "bathing_suit"].contains(where: { l.contains($0) }) { return false }
        return l == "bath" || l == "bathing" || ["bathtub", "bath_tub", "shower", "jacuzzi", "hot_tub", "hottub", "bubble_bath"]
            .contains { l.contains($0) }
    }

    static func severity(_ reason: String?) -> Int {
        switch reason { case "bath", "undressed": 3; case "swimwear": 2; case .some: 1; case nil: 0 }
    }

    /// Nil when Vision failed, so the caller stores nothing and the photo is tried again on the next scan.
    func analyze(_ image: CGImage, orientation: CGImagePropertyOrientation) -> Signals? {
        var s = Signals()

        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do { try handler.perform([classify, faces]) } catch { return nil }

        var bathroomRoom = false, roomFaint = false, tubFaint = false, hint = false
        for obs in classify.results ?? [] {
            let id = obs.identifier
            // The most serious match wins (bath or undressed over swimwear over document or screenshot),
            // whatever order Vision lists them in. Each needs a real level of confidence: the old "loose" bar
            // (10% precision) flagged fully clothed kids in hallways, classrooms and kitchens as bath photos.
            if let reason = blocked[id] {
                // Any faint bath or undressed sign keeps the photo (and its session) from ever being sent.
                if (reason == "bath" || reason == "undressed") && obs.confidence > 0.1 {
                    if !(reason == "bath" && !Self.isActualBath(id)) { hint = true }
                    if reason == "bath" && Self.isActualBath(id) { tubFaint = true }
                    if reason == "bath" && !Self.isActualBath(id) { roomFaint = true }
                }
                let need: Float
                if reason == "bath" && !Self.isActualBath(id) {
                    // A bathroom or bathrobe label alone isn't a bath: it only counts with a bare chest (checked below).
                    if obs.confidence > 0.5 { bathroomRoom = true }
                    need = 2
                } else {
                    need = reason == "bath" || reason == "undressed" ? 0.3 : 0.5
                }
                if obs.confidence > need, Self.severity(reason) > Self.severity(s.blockedLabel) { s.blockedLabel = reason }
            }
            if obs.confidence > 0.6, Describe.sceneLabels.contains(id) { s.labels.append(id) }
            if s.waterScene == false, Self.waterScenes.contains(id), obs.confidence > 0.5 { s.waterScene = true }
            if Self.childLabels.contains(id) {
                s.childConfidence = max(s.childConfidence, Double(obs.confidence))
                if obs.hasPrecisionRecallCurve && obs.hasMinimumRecall(0.01, forPrecision: 0.9) { s.childPrecise = true }
            }
            if Self.babyLabels.contains(id) { s.babyConfidence = max(s.babyConfidence, Double(obs.confidence)) }
        }

        let faceObs = faces.results ?? []
        s.privacyHint = hint
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
        let largest = faceObs.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0
        let boxes = faceObs.map(\.boundingBox)
        for o in faceObs {
            let box = o.boundingBox
            var face = FaceSignal(area: Double(box.width * box.height), quality: Double(o.faceCaptureQuality ?? 0))
            face.box = [Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)]
            if let m = ciFaces.max(by: { iou($0.box, box) < iou($1.box, box) }), iou(m.box, box) > 0.3 {
                face.smile = m.smile
                face.eyesClosed = m.closed
            }
            // Is this person a child? (Checked for the four largest faces big enough to read.)
            // Only worth it with two or more faces and some sign of a child (otherwise it can't change the subject).
            if faceObs.count >= 2 && (s.childPrecise || s.childConfidence >= 0.1)
                && box.height >= 0.04 && boxes.filter({ $0.width * $0.height > box.width * box.height }).count < 4 {
                face.child = childConfidence(handler, face: box)
            }
            // Shirtless check on every face big enough to measure: about 30 px tall, or the main face(s) of the photo.
            if box.height >= 0.04 || box.width * box.height >= largest * 0.25 {
                face.bareTorso = bareTorso(ci, face: box)
                // A bare chest is fine only on a baby: ask the classifier about this person alone.
                if face.bareTorso >= Scorer.bareTorsoLimit {
                    face.baby = babyConfidence(handler, around: box, avoiding: boxes.filter { $0 != box })
                }
            }
            s.faces.append(face)
        }
        // Sharpness of the main subject (the child's face when one reads as a child).
        if let sf = s.subject, sf.box.count == 4 {
            subjectBox = CGRect(x: sf.box[0], y: sf.box[1], width: sf.box[2], height: sf.box[3])
        }
        s.sharpness = sharpness(ci, box: subjectBox)
        // A bathroom scene or a faint tub/shower label plus any bare chest (babies included: this is about baths,
        // not the diaper rule) counts as a possible bath photo.
        let anyBare = s.faces.contains { $0.bareTorso >= Scorer.bareTorsoLimit }
        if (bathroomRoom || tubFaint) && anyBare && Self.severity("bath") > Self.severity(s.blockedLabel) { s.blockedLabel = "bath" }
        // Even a faint bathroom label with any bare chest (a baby bathed in a sink) keeps the session from Claude.
        if anyBare && (bathroomRoom || roomFaint || tubFaint || hint) { s.privacyHint = true }
        return s
    }

    /// Vision's feature print of the whole photo, for the learned score. Run only for photos on the list or
    /// offered to Claude; empty if it fails (the photo still counts, without a learned score).
    func scenePrint(_ image: CGImage, orientation: CGImagePropertyOrientation) -> [Float] {
        let req = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([req])) != nil,
              let fp = req.results?.first, fp.elementType == .float else { return [] }
        return fp.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Face fingerprints for Who's Who: Vision's image feature print of each of the (up to 4) largest faces.
    func facePrints(_ image: CGImage, orientation: CGImagePropertyOrientation, faces: [FaceSignal]) -> [FaceRecord] {
        let ci = CIImage(cgImage: image).oriented(orientation)
        var out: [FaceRecord] = []
        for f in faces.filter({ $0.box.count == 4 && $0.area >= 0.006 }).sorted(by: { $0.area > $1.area }).prefix(4) {
            let floats = cropPrint(ci, f)
            if !floats.isEmpty { out.append(FaceRecord(box: f.box.map { Float($0) }, vec: People.embed(floats))) }
        }
        return out
    }

    /// Vision's feature print of one face crop (empty if the face is too small or it fails).
    private func cropPrint(_ ci: CIImage, _ f: FaceSignal) -> [Float] {
        guard f.box.count == 4 else { return [] }
        let e = ci.extent
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let b = CGRect(x: f.box[0], y: f.box[1], width: f.box[2], height: f.box[3])
            .insetBy(dx: -f.box[2] * 0.1, dy: -f.box[3] * 0.1).intersection(unit)
        let r = CGRect(x: e.minX + b.minX * e.width, y: e.minY + b.minY * e.height,
                       width: b.width * e.width, height: b.height * e.height).integral.intersection(e)
        guard !r.isNull, r.width >= 24, r.height >= 24, let crop = ciContext.createCGImage(ci, from: r) else { return [] }
        let req = VNGenerateImageFeaturePrintRequest()
        req.imageCropAndScaleOption = .scaleFill
        guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([req])) != nil,
              let fp = req.results?.first, fp.elementType == .float else { return [] }
        return fp.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Extra measurements for the learned score, for photos on the list or offered to Claude: Apple's photo-quality
    /// score (iOS 18 and later), the "utility photo" flag, the main face's shape, and a print of the main face.
    func learningExtras(_ image: CGImage, orientation: CGImagePropertyOrientation, subject: FaceSignal?)
        -> (aesthetic: Double?, utility: Bool, shape: [Double], facePrint: [Float]) {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        var aesthetic: Double? = nil, utility = false
        if #available(iOS 18.0, *) {
            let req = VNCalculateImageAestheticsScoresRequest()
            if (try? handler.perform([req])) != nil, let o = req.results?.first {
                aesthetic = Double(o.overallScore); utility = o.isUtility
            }
        }
        var shape: [Double] = [], print: [Float] = []
        if let f = subject, f.box.count == 4 {
            let box = CGRect(x: f.box[0], y: f.box[1], width: f.box[2], height: f.box[3])
            let lm = VNDetectFaceLandmarksRequest()
            lm.inputFaceObservations = [VNFaceObservation(boundingBox: box)]
            if (try? handler.perform([lm])) != nil, let l = lm.results?.first?.landmarks { shape = Self.faceShape(l) }
            print = cropPrint(CIImage(cgImage: image).oriented(orientation), f)
        }
        return (aesthetic, utility, shape, print)
    }

    /// Six 0...1 measurements of a face from its landmarks: smile curve (mouth corners above the middle of the lips),
    /// mouth width, mouth open, eyes open, head turned (nose off the middle of the eyes), head tilted (eye line).
    static func faceShape(_ l: VNFaceLandmarks2D) -> [Double] {
        func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] { r?.normalizedPoints ?? [] }
        let outer = pts(l.outerLips), inner = pts(l.innerLips), le = pts(l.leftEye), re = pts(l.rightEye), nose = pts(l.nose)
        guard outer.count >= 4, le.count >= 3, re.count >= 3 else { return [] }
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        let minX = outer.map(\.x).min()!, maxX = outer.map(\.x).max()!
        let width = Double(maxX - minX)
        let left = outer.min { $0.x < $1.x }!, right = outer.max { $0.x < $1.x }!
        let midY = Double(outer.map(\.y).reduce(0, +)) / Double(outer.count)
        let curve = width > 0 ? (Double(left.y + right.y) / 2 - midY) / width : 0
        let openH = inner.isEmpty ? 0 : Double((inner.map(\.y).max() ?? 0) - (inner.map(\.y).min() ?? 0))
        func openness(_ e: [CGPoint]) -> Double {
            let w = Double((e.map(\.x).max() ?? 0) - (e.map(\.x).min() ?? 0))
            let h = Double((e.map(\.y).max() ?? 0) - (e.map(\.y).min() ?? 0))
            return w > 0 ? h / w : 0
        }
        func center(_ e: [CGPoint]) -> CGPoint {
            CGPoint(x: e.map(\.x).reduce(0, +) / CGFloat(e.count), y: e.map(\.y).reduce(0, +) / CGFloat(e.count))
        }
        let lc = center(le), rc = center(re)
        let eyeDist = Double(hypot(rc.x - lc.x, rc.y - lc.y))
        let noseX = nose.isEmpty ? (lc.x + rc.x) / 2 : center(nose).x
        let turn = eyeDist > 0 ? abs(Double(noseX - (lc.x + rc.x) / 2)) / eyeDist : 0
        let tilt = abs(atan2(Double(rc.y - lc.y), Double(abs(rc.x - lc.x)) + 1e-6)) / (Double.pi / 4)
        return [clamp(0.5 + curve * 3), clamp(width * 1.5), clamp(width > 0 ? openH / width * 2 : 0),
                clamp((openness(le) + openness(re)) / 2 * 3), clamp(turn * 2), clamp(tilt)]
    }

    /// Child/baby label confidence for one person: the classifier run on their head and shoulders only.
    private func childConfidence(_ handler: VNImageRequestHandler, face b: CGRect) -> Double? {
        let roi = CGRect(x: b.minX - b.width * 0.3, y: b.minY - b.height * 0.5, width: b.width * 1.6, height: b.height * 1.7)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !roi.isNull, roi.width > 0.02, roi.height > 0.02 else { return nil }
        let req = VNClassifyImageRequest()
        req.regionOfInterest = roi
        guard (try? handler.perform([req])) != nil else { return nil }
        return Double((req.results ?? []).filter { Self.childLabels.contains($0.identifier) }.map(\.confidence).max() ?? 0)
    }

    /// "baby" label confidence for one person: the classifier run on their face and chest only.
    /// If another face overlaps that face-and-chest region (someone holding a baby), only this person's face is used,
    /// so a held baby can't make the person holding them read as a baby; if a smaller face still touches even that,
    /// this person is not treated as the baby at all.
    private func babyConfidence(_ handler: VNImageRequestHandler, around b: CGRect, avoiding others: [CGRect]) -> Double? {
        var roi = CGRect(x: b.minX - b.width * 0.3, y: b.minY - b.height * 1.8, width: b.width * 1.6, height: b.height * 2.8)
        if others.contains(where: { $0.intersects(roi) }) {
            roi = b.insetBy(dx: -b.width * 0.15, dy: -b.height * 0.15)
            if others.contains(where: { $0.intersects(roi) && $0.width * $0.height < b.width * b.height }) { return 0 }
        }
        roi = roi.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !roi.isNull, roi.width > 0.02, roi.height > 0.02 else { return nil }
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
