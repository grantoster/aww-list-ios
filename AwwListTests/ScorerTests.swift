import Foundation
import XCTest
@testable import AwwList

final class ScorerTests: XCTestCase {
    private func kid(smile: Bool = true, area: Double = 0.12, sharp: Double = 1) -> Signals {
        var s = Signals()
        s.childConfidence = 0.9
        s.faces = [FaceSignal(area: area, quality: 0.6, smile: smile, eyesClosed: false)]
        s.sharpness = sharp
        return s
    }

    func testScreenshotsBlockedAndNoChildAreLeftOut() {
        var s = Signals(); s.isScreenshot = true
        XCTAssertEqual(Scorer.score(s).excluded, "Screenshot")
        var n = kid(); n.childConfidence = 0.1
        XCTAssertEqual(Scorer.score(n).excluded, "No child")
        var p = kid(); p.childConfidence = 0.1; p.childPrecise = true
        XCTAssertNil(Scorer.score(p).excluded)
        var b = kid(); b.blockedLabel = "bath"
        XCTAssertEqual(Scorer.score(b).excluded, "Bath")
    }

    func testBlocklistCatchesLabelVariantsButNotDiapers() {
        let list = Analyzer.blocklist(for: ["bathtub", "hot_tub", "swimming_pool", "water_park", "diaper", "dog", "child"])
        XCTAssertEqual(list["bathtub"], "bath")
        XCTAssertEqual(list["hot_tub"], "bath")
        XCTAssertEqual(list["swimming_pool"], "swimwear")
        XCTAssertEqual(list["water_park"], "swimwear")
        XCTAssertNil(list["diaper"])          // diapers are fine
        XCTAssertNil(list["dog"])
        XCTAssertNil(list["child"])
        XCTAssertEqual(list["bath"], "bath")  // exact names are always included
    }

    func testShirtlessIsLeftOut() {
        var s = kid(); s.bareTorso = 0.8
        XCTAssertEqual(Scorer.score(s).excluded, "Shirtless")
        let skin: [UInt8] = Array([UInt8]([224, 172, 150]).repeated(64))
        let shirt: [UInt8] = Array([UInt8]([40, 80, 200]).repeated(64))
        XCTAssertEqual(Scorer.skinMatch(face: skin, torso: skin), 1)
        XCTAssertEqual(Scorer.skinMatch(face: skin, torso: shirt), 0)
    }

    func testSmilesBeatNoSmiles() {
        XCTAssertGreaterThan(Scorer.score(kid(smile: true)).raw!, Scorer.score(kid(smile: false)).raw!)
    }

    func testSmilingAdultsDoNotBeatSmilingChild() {
        var group = kid(smile: false, area: 0.10)
        group.faces += [FaceSignal(area: 0.06, quality: 0.8, smile: true), FaceSignal(area: 0.06, quality: 0.8, smile: true)]
        XCTAssertGreaterThan(Scorer.score(kid()).raw!, Scorer.score(group).raw!)
    }

    func testBlurPullsScoreDown() {
        let sharpNeutral = Scorer.score(kid(smile: false, sharp: 1)).raw!
        let blurrySmile = Scorer.score(kid(smile: true, sharp: 0)).raw!
        XCTAssertLessThan(blurrySmile, Scorer.score(kid(smile: true, sharp: 1)).raw! * 0.5)
        XCTAssertLessThan(blurrySmile, sharpNeutral)
        XCTAssertLessThanOrEqual(Scorer.ceiling(blurrySmile), 5)
    }

    func testSleepingBabyIsNotPenalized() {
        var asleep = kid(smile: false); asleep.babyConfidence = 0.9; asleep.faces[0].eyesClosed = true
        var crying = kid(smile: false); crying.babyConfidence = 0.9
        XCTAssertGreaterThan(Scorer.score(asleep).raw!, Scorer.score(crying).raw!)
        // asleep in a parent's arms (parent's face is larger) isn't penalized either
        var held = asleep; held.faces.append(FaceSignal(area: 0.15, quality: 0.8, smile: false))
        var awakeHeld = crying; awakeHeld.faces.append(FaceSignal(area: 0.15, quality: 0.8, smile: false))
        XCTAssertGreaterThanOrEqual(Scorer.score(held).raw!, Scorer.score(awakeHeld).raw!)
    }

    func testIdenticalFacesBothCount() {
        var s = kid(); s.faces.append(s.faces[0])
        XCTAssertGreaterThan(Scorer.score(s).raw!, Scorer.score(kid()).raw!)
    }

    func testSharpnessMeasure() {
        let n = 32
        let flat = [UInt8](repeating: 128, count: n * n)
        let checker = (0..<(n * n)).map { i in UInt8(((i / n) + (i % n)) % 2 == 0 ? 0 : 255) }
        XCTAssertEqual(Scorer.sharpness(gray: flat, width: n, height: n), 0)
        XCTAssertEqual(Scorer.sharpness(gray: checker, width: n, height: n), 1)
    }

    func testCalibrationKeepsTopScoresRare() {
        let raws = (0..<1000).map { Double($0) / 1000 }
        let cal = Scorer.calibrate(raws)
        XCTAssertEqual(cal.filter { $0 >= 9 }.count, 10)
        XCTAssertEqual(cal[999], 10)
        XCTAssertEqual(cal[0], 1)
    }

    func testCalibrationTiesSmallLibrariesAndCeilings() {
        XCTAssertEqual(Set(Scorer.calibrate([0.8, 0.8, 0.8])).count, 1)          // ties share a score
        XCTAssertLessThanOrEqual(Scorer.calibrate([0.95, 0.5, 0.4]).max()!, 8)   // under 50 moments: 8 at most
        XCTAssertLessThanOrEqual(Scorer.calibrate((0..<100).map { _ in 0.4 } + [0.42]).max()!, 5) // weak library stays weak
    }

    func testOneHugeYearDoesNotSwampAnother() {
        let small = (0..<100).map { 0.5 + Double($0) / 250 }   // 100 good moments in 2020
        let big = (0..<3000).map { _ in 0.3 }                    // 3,000 weak ones in 2021
        let weighted = Scorer.calibrate(small + big, years: Array(repeating: 2020, count: 100) + Array(repeating: 2021, count: 3000))
        let pooled = Scorer.calibrate(small + big)
        XCTAssertLessThan(weighted[..<100].filter { $0 >= 8 }.count, pooled[..<100].filter { $0 >= 8 }.count)
    }

    func testATinyYearDoesNotClaimAFullYearOfTopScores() {
        let a = (0..<1000).map { 0.3 + Double($0) / 2000 }, b = (0..<1000).map { 0.3 + Double($0) / 2000 }
        let cal = Scorer.calibrate(a + b + [0.9], years: Array(repeating: 2024, count: 1000) + Array(repeating: 2025, count: 1000) + [2026])
        XCTAssertGreaterThanOrEqual(cal[999], 9)            // best of 2024 stays at the top
        let pooled = Scorer.calibrate(a + b + [0.9]).filter { $0 >= 8 }.count
        XCTAssertLessThanOrEqual(abs(cal.filter { $0 >= 8 }.count - pooled), 5)   // equal per-year weight would add ~50
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

    func testLongSessionsSplitEveryTwoMinutes() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let p = (0..<41).map { PhotoScore(id: "s\($0)", date: t.addingTimeInterval(Double($0) * 30), raw: 0.5, excluded: nil, age: .kid, caption: "") }
        XCTAssertGreaterThanOrEqual(Scorer.moments(from: p).count, 10)
    }

    func testFramesNearABathPhotoAreQuarantined() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        var p = (0..<10).map { PhotoScore(id: "bath\($0)", date: t.addingTimeInterval(Double($0) * 5), raw: nil, excluded: "Bath", age: nil, caption: "") }
        p[3] = PhotoScore(id: "bath3", date: t.addingTimeInterval(15), raw: 0.8, excluded: nil, age: .baby, caption: "Baby grin")
        p.append(PhotoScore(id: "later", date: t.addingTimeInterval(3600), raw: 0.6, excluded: nil, age: .kid, caption: ""))
        XCTAssertEqual(Scorer.moments(from: p).map(\.best.id), ["later"])
    }

    func testTiesPickTheSameShotEveryTime() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let p = ["z", "x", "y"].map { PhotoScore(id: $0, date: t, raw: 0.5, excluded: nil, age: .kid, caption: "") }
        for _ in 0..<20 { XCTAssertEqual(Scorer.moments(from: p.shuffled())[0].best.id, "x") }
    }
}

private extension Array {
    func repeated(_ n: Int) -> [Element] { (0..<n).flatMap { _ in self } }
}
