import XCTest
@testable import AwwList

final class ScorerTests: XCTestCase {
    func testScreenshotsAndNoChildAreLeftOut() {
        var s = Signals(); s.isScreenshot = true
        XCTAssertEqual(Scorer.score(s).excluded, "Screenshot")
        var n = Signals(); n.faceCount = 1; n.childConfidence = 0.1
        XCTAssertEqual(Scorer.score(n).excluded, "No child")
        var b = Signals(); b.faceCount = 1; b.childConfidence = 0.9; b.blockedLabel = "swimwear"
        XCTAssertEqual(Scorer.score(b).excluded, "Swimwear")
    }

    func testSmilesBeatNoSmiles() {
        var a = Signals(); a.faceCount = 1; a.childConfidence = 0.9; a.bestFaceQuality = 0.6; a.largestFaceArea = 0.1
        var b = a; b.smiles = 1
        XCTAssertGreaterThan(Scorer.score(b).raw!, Scorer.score(a).raw!)
    }

    func testCalibrationKeepsTopScoresRare() {
        let raws = (0..<1000).map { Double($0) / 1000 }
        let cal = Scorer.calibrate(raws)
        XCTAssertEqual(cal.filter { $0 >= 9 }.count, 10)
        XCTAssertEqual(cal[999], 10)
        XCTAssertEqual(cal[0], 1)
    }

    func testBurstsCollapseToBestShot() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let p = [
            PhotoScore(id: "a", date: t, raw: 0.4, excluded: nil, age: .kid, caption: ""),
            PhotoScore(id: "b", date: t.addingTimeInterval(20), raw: 0.9, excluded: nil, age: .kid, caption: ""),
            PhotoScore(id: "c", date: t.addingTimeInterval(200), raw: 0.5, excluded: nil, age: .kid, caption: "")
        ]
        let m = Scorer.moments(from: p)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m[0].best.id, "b")
        XCTAssertEqual(m[0].shots, 2)
    }
}
