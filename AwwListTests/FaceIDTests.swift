import CoreImage
import CoreVideo
import XCTest
@testable import AwwList

final class FaceIDTests: XCTestCase {
    /// The face model on the iPhone gives the same numbers as the original model did on the reference picture.
    func testModelMatchesReference() throws {
        XCTAssertTrue(FaceID.available, "the face model isn't in the app")
        let b = Bundle(for: FaceIDTests.self)
        let png = try XCTUnwrap(b.url(forResource: "FaceIDTest", withExtension: "png"))
        let ref = try JSONDecoder().decode([Float].self, from: Data(contentsOf: XCTUnwrap(b.url(forResource: "FaceIDTest", withExtension: "json"))))
        let ci = try XCTUnwrap(CIImage(contentsOf: png))
        var pb: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 112, 112, kCVPixelFormatType_32BGRA, nil, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CIContext().render(ci, to: buffer, bounds: CGRect(x: 0, y: 0, width: 112, height: 112), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let v = try XCTUnwrap(FaceID.embedding(buffer))
        XCTAssertEqual(v.count, 512)
        let cos = zip(v, ref).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertGreaterThan(cos, 0.98, "cosine with the reference \(cos)")
        // Packed into bytes and back, it's still the same print.
        let back = People.floats(FaceID.pack(v))
        XCTAssertGreaterThan(zip(back, v).reduce(Float(0)) { $0 + $1.0 * $1.1 }, 0.999)
    }

    /// Lining up a face: a known turn, scale and shift is recovered exactly.
    func testSimilarityRecoversTransform() throws {
        let truth = CGAffineTransform(rotationAngle: 0.3).scaledBy(x: 0.5, y: 0.5).translatedBy(x: 12, y: -7)
        let p = [CGPoint(x: 100, y: 200), CGPoint(x: 180, y: 210), CGPoint(x: 110, y: 120), CGPoint(x: 170, y: 125)]
        let q = p.map { $0.applying(truth) }
        let t = try XCTUnwrap(FaceID.similarity(from: p, to: q))
        for (a, b) in zip(p, q) {
            let c = a.applying(t)
            XCTAssertEqual(c.x, b.x, accuracy: 1e-6); XCTAssertEqual(c.y, b.y, accuracy: 1e-6)
        }
    }

    /// Nobody is matched in a photo taken before they were born.
    func testBirthdayRule() {
        let a = (0..<768).map { Float(sin(Double($0))) }
        let face = People.floats(People.embed(a))
        var kid = Person(name: "Kid", centroid: face, count: 1, samplePhoto: "x", sampleBox: [0, 0, 1, 1])
        kid.examples = [People.embed(a)]
        kid.birthday = Date(timeIntervalSince1970: 1_600_000_000)
        let before = Date(timeIntervalSince1970: 1_500_000_000), after = Date(timeIntervalSince1970: 1_700_000_000)
        let r = People.learn([face, face], people: [kid], threshold: 0.84, owners: ["p1", "p2"], dates: [before, after])
        XCTAssertNil(r.matched[0] ?? r.learned[0])
        XCTAssertEqual(r.matched[1] ?? r.learned[1], kid.id)
    }
}
