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
        // Real labels from Apple's taxonomy, plus made-up variants a future iOS might use.
        let list = Analyzer.blocklist(for: ["bathroom_room", "snorkeling", "lake", "sprinkler", "bathtub", "hot_tub", "swimming_pool", "diaper", "dog", "child"])
        XCTAssertEqual(list["bathroom_room"], "bath")
        XCTAssertEqual(list["snorkeling"], "swimwear")
        XCTAssertEqual(list["bathtub"], "bath")
        XCTAssertEqual(list["hot_tub"], "bath")
        XCTAssertEqual(list["swimming_pool"], "swimwear")
        XCTAssertNil(list["sprinkler"])       // a water scene (confident label only), not a quarantine trigger
        XCTAssertNil(list["diaper"])          // diapers are fine
        XCTAssertNil(list["dog"])
        XCTAssertNil(list["child"])
        XCTAssertEqual(list["bath"], "bath")  // exact names are always included
    }

    func testShirtlessIsLeftOut() {
        var s = kid(); s.faces[0].bareTorso = 0.8
        XCTAssertEqual(Scorer.score(s).excluded, "Shirtless")
        var diaperBaby = s; diaperBaby.babyConfidence = 0.9
        XCTAssertNil(Scorer.score(diaperBaby).excluded)   // diapers are fine
        var sibling = diaperBaby; sibling.faces[0].bareTorso = 0
        sibling.faces.append(FaceSignal(area: 0.2, quality: 0.8, smile: true, eyesClosed: false, bareTorso: 0.9))
        XCTAssertEqual(Scorer.score(sibling).excluded, "Shirtless")   // a baby in the shot doesn't excuse an older sibling
        // the older sibling farther back (smaller face) is caught by their own crop's classification
        var farSibling = diaperBaby; farSibling.faces[0].area = 0.15; farSibling.faces[0].baby = 0.9
        farSibling.faces.append(FaceSignal(area: 0.06, quality: 0.8, smile: true, eyesClosed: false, bareTorso: 0.9, baby: 0.1))
        XCTAssertEqual(Scorer.score(farSibling).excluded, "Shirtless")
        // a shirtless older brother holding a diaper baby: only the smallest bare chest can be exempt
        var holding = diaperBaby; holding.faces[0].area = 0.05; holding.faces[0].baby = 0.9
        holding.faces.append(FaceSignal(area: 0.12, quality: 0.8, smile: true, eyesClosed: false, bareTorso: 0.85, baby: 0.8))
        XCTAssertEqual(Scorer.score(holding).excluded, "Shirtless")
        // a crop that couldn't be measured is not a baby when another face was measured
        var unmeasured = diaperBaby; unmeasured.faces[0].area = 0.15; unmeasured.faces[0].bareTorso = 0; unmeasured.faces[0].baby = 0.9
        unmeasured.faces.append(FaceSignal(area: 0.03, quality: 0.8, smile: true, eyesClosed: false, bareTorso: 0.9, baby: nil))
        XCTAssertEqual(Scorer.score(unmeasured).excluded, "Shirtless")
        // shirtless at a lake is filed as Shirtless (which hides its burst), not just Water
        var lakeBoy = s; lakeBoy.waterScene = true
        XCTAssertEqual(Scorer.score(lakeBoy).excluded, "Shirtless")
        // an older kid the child label half-misses still counts as shirtless
        var older = s; older.childConfidence = 0.3
        XCTAssertEqual(Scorer.score(older).excluded, "Shirtless")
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let burst = [PhotoScore(id: "a", date: t, raw: nil, excluded: "Shirtless", age: nil, caption: ""),
                     PhotoScore(id: "b", date: t.addingTimeInterval(90), raw: 0.8, excluded: nil, age: .kid, caption: "")]
        XCTAssertTrue(Scorer.moments(from: burst).isEmpty)
        let later = [burst[0], PhotoScore(id: "c", date: t.addingTimeInterval(300), raw: 0.8, excluded: nil, age: .kid, caption: "")]
        XCTAssertEqual(Scorer.moments(from: later).map(\.best.id), ["c"])   // shirtless hides its burst, not the whole party
        var lake = kid(); lake.waterScene = true
        XCTAssertEqual(Scorer.score(lake).excluded, "Water")
        XCTAssertFalse(Scorer.sensitive.contains("Water"))
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

    func testParentBlinkIsNotASleepingBaby() {
        var awake = kid(smile: false, area: 0.06); awake.babyConfidence = 0.9
        awake.faces.append(FaceSignal(area: 0.15, quality: 0.8, smile: false))
        var blink = awake; blink.faces[1].eyesClosed = true
        XCTAssertLessThanOrEqual(Scorer.score(blink).raw!, Scorer.score(awake).raw!)
        XCTAssertLessThan(Scorer.score(blink).raw!, Scorer.score(kid()).raw!)
    }

    func testOldVersionsStillQuarantineButAreNotShown() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let p = [PhotoScore(id: "old", date: t, raw: nil, excluded: "Bath", age: nil, caption: "", version: 1),
                 PhotoScore(id: "new", date: t.addingTimeInterval(90), raw: 0.8, excluded: nil, age: .kid, caption: "", version: 4),
                 PhotoScore(id: "stale", date: t.addingTimeInterval(9000), raw: 0.8, excluded: nil, age: .kid, caption: "", version: 1)]
        XCTAssertTrue(Scorer.moments(from: p, version: 4).isEmpty)
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

final class DescribeTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    func testCaptionsNameTheMomentAndScene() {
        var s = Signals(); s.childConfidence = 0.9; s.babyConfidence = 0.9
        s.faces = [FaceSignal(area: 0.15, quality: 0.7, smile: true, eyesClosed: false)]
        s.labels = ["high_chair", "food"]
        XCTAssertEqual(Describe.caption(s, date: t), "Baby grin up close in the high chair")
        s.labels = ["birthday_cake", "balloon"]
        XCTAssertEqual(Describe.caption(s, date: t), "Baby grin up close with the birthday cake")
        s.faces[0].eyesClosed = true; s.labels = []
        XCTAssertEqual(Describe.caption(s, date: t), "Belly-laugh baby")
        s.faces[0].smile = false; s.labels = ["ballet", "crib"]
        XCTAssertEqual(Describe.caption(s, date: t), "Sweet sleeping baby in the crib")   // no "sleeping baby dancing"
        s.faces = [FaceSignal(area: 0.1, quality: 0.7, smile: true), FaceSignal(area: 0.08, quality: 0.7, smile: true)]
        s.labels = ["high_chair", "kitchen"]
        XCTAssertEqual(Describe.caption(s, date: t), "Two big smiles in the kitchen")     // no group "in the high chair"
    }

    func testHolidays() {
        var c = DateComponents(); c.year = 2024; c.month = 12; c.day = 25; c.hour = 10
        let xmas = Calendar.current.date(from: c)!
        c.month = 11; c.day = 28                       // 4th Thursday of November 2024
        let thanks = Calendar.current.date(from: c)!
        XCTAssertEqual(Describe.holiday(xmas), "on Christmas")
        XCTAssertEqual(Describe.holiday(thanks), "on Thanksgiving")
        var s = Signals(); s.faces = [FaceSignal(area: 0.05, quality: 0.7, smile: true)]
        XCTAssertEqual(Describe.caption(s, date: xmas), "Big smile on Christmas")
    }

    func testProvenanceVerdicts() {
        var f = Provenance.FileInfo(filename: "IMG_1234.HEIC", software: "17.4", cameraMake: "Apple")
        XCTAssertNil(Provenance.verdict(f))                                  // a normal iPhone photo
        f.aiMarker = true
        XCTAssertEqual(Provenance.verdict(f), "AI image")
        f = Provenance.FileInfo(filename: "ChatGPT Image Apr 2, 2025, 10_14_03 AM.png", isPNG: true)
        XCTAssertEqual(Provenance.verdict(f), "AI image")
        f = Provenance.FileInfo(filename: "IMG_9.JPG", software: "Facetune", cameraMake: "Apple")
        XCTAssertEqual(Provenance.verdict(f), "Edited")
        XCTAssertNil(Provenance.verdict(Provenance.FileInfo(filename: "image.png", isPNG: true, headerRead: false)))
        XCTAssertNil(Provenance.verdict(Provenance.FileInfo(filename: "firefly_jar.jpg")))
        XCTAssertNil(Provenance.verdict(Provenance.FileInfo(filename: "a.jpg", software: "Adobe Photoshop Camera Raw 16.0", cameraMake: "Canon")))
        f = Provenance.FileInfo(filename: "image.png", isPNG: true)
        XCTAssertEqual(Provenance.verdict(f), "Not a camera photo")          // a PNG no camera made
        f = Provenance.FileInfo(filename: "DSC_0042.jpg", software: "Adobe Photoshop Lightroom Classic 13.2", cameraMake: "NIKON")
        XCTAssertNil(Provenance.verdict(f))                                  // a photographer's Lightroom edit is fine
        f = Provenance.FileInfo(filename: "IMG_1.jpg", software: "Adobe Photoshop 25.0 (Windows)", cameraMake: "Canon")
        XCTAssertEqual(Provenance.verdict(f), "Edited")
        for name in ["Foto dalle vacanze.jpg", "reminiscing_with_grandma.jpg"] {
            XCTAssertNil(Provenance.verdict(Provenance.FileInfo(filename: name)))
        }
        XCTAssertNil(Provenance.verdict(Provenance.FileInfo(filename: "IMG_2.HEIC", software: "Influx Camera", cameraMake: "Apple")))
        f = Provenance.FileInfo(filename: "IMG-20240101-WA0003.jpg")
        XCTAssertNil(Provenance.verdict(f))                                  // WhatsApp strips details: not penalized
        f = Provenance.FileInfo(filename: "imagen_familia.jpg")
        XCTAssertNil(Provenance.verdict(f))
        XCTAssertTrue(Provenance.hasAIMarker(Data("<Iptc4xmpExt:DigitalSourceType>http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia".utf8)))
        XCTAssertFalse(Provenance.hasAIMarker(Data("ordinary jpeg bytes".utf8)))
        // a real photo touched up with Clean Up / Magic Eraser is kept
        XCTAssertFalse(Provenance.hasAIMarker(Data("digitalsourcetype/compositeWithTrainedAlgorithmicMedia".utf8)))
        XCTAssertFalse(Provenance.hasAIMarker(Data("digitalsourcetype/compositeSynthetic".utf8)))
    }
}

final class AgeTagTests: XCTestCase {
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: day, hour: 12))!
    }

    func testGroupsFromBirthdays() {
        let son = d(2016, 7, 29), daughter = d(2017, 11, 29)
        XCTAssertEqual(AgeGroup.of(birth: son, at: d(2017, 3, 1)), .baby)
        XCTAssertEqual(AgeGroup.of(birth: son, at: d(2018, 3, 1)), .toddler)
        XCTAssertEqual(AgeGroup.of(birth: son, at: d(2020, 7, 29)), .kid)
        // only the son was born: his group
        XCTAssertEqual(AgeGroup.tags(date: d(2017, 3, 1), birthdays: [son, daughter], looksLikeBaby: true, faces: 1), [.baby])
        // one face that looks like a baby, newborn sister and toddler brother: Baby
        XCTAssertEqual(AgeGroup.tags(date: d(2018, 2, 1), birthdays: [son, daughter], looksLikeBaby: true, faces: 1), [.baby])
        // one face that doesn't look like a baby: the toddler
        XCTAssertEqual(AgeGroup.tags(date: d(2018, 2, 1), birthdays: [son, daughter], looksLikeBaby: false, faces: 1), [.toddler])
        // two faces that look like a baby with someone: just Baby (usually held by a grown-up)
        XCTAssertEqual(AgeGroup.tags(date: d(2018, 2, 1), birthdays: [son, daughter], looksLikeBaby: true, faces: 2), [.baby])
        // two kids together, not baby-looking: both tags
        XCTAssertEqual(AgeGroup.tags(date: d(2019, 2, 1), birthdays: [son, daughter], looksLikeBaby: false, faces: 2), [.toddler])
        XCTAssertEqual(AgeGroup.tags(date: d(2021, 2, 1), birthdays: [son, daughter], looksLikeBaby: false, faces: 2), [.kid, .toddler])
        // before any child was born: no age tag
        XCTAssertEqual(AgeGroup.tags(date: d(2014, 6, 1), birthdays: [son, daughter], looksLikeBaby: false, faces: 3), [])
        // first-birthday party: Toddler all day, whatever time the birthday was saved with
        let sonAt3pm = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2016, month: 7, day: 29, hour: 15))!
        let party10am = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2017, month: 7, day: 29, hour: 10))!
        XCTAssertEqual(AgeGroup.of(birth: sonAt3pm, at: party10am), .toddler)
        // no birthdays saved
        XCTAssertEqual(AgeGroup.tags(date: d(2018, 2, 1), birthdays: [], looksLikeBaby: false, faces: 1), [.kid])
    }
}

final class PeopleTests: XCTestCase {
    private func noisy(_ base: [Float], _ seed: Int) -> [Float] {
        base.enumerated().map { i, v in v + Float(((i * 7919 + seed * 104729) % 1000) - 500) / 5000 }
    }

    func testFingerprintsGroupLookalikesAndMatchNames() {
        let a = (0..<768).map { Float(sin(Double($0))) }, b = (0..<768).map { Float(cos(Double($0) * 1.3)) }
        XCTAssertEqual(People.embed(a), People.embed(a))                       // same every time
        let faces = (0..<5).map { People.floats(People.embed(noisy(a, $0))) } + (0..<4).map { People.floats(People.embed(noisy(b, $0))) }
        let groups = People.cluster(faces, threshold: People.threshold(strictness: 1))
        XCTAssertEqual(groups.map(\.count), [5, 4])
        let daniel = Person(name: "Daniel", centroid: People.merged([], count: 0, adding: Array(faces[0..<5])), count: 5,
                            samplePhoto: "x", sampleBox: [0, 0, 1, 1])
        XCTAssertEqual(People.match(faces[2], people: [daniel], threshold: 0.84), daniel.id)
        XCTAssertNil(People.match(faces[7], people: [daniel], threshold: 0.84))
    }
}

final class LearnerTests: XCTestCase {
    func testFingerprintRoundTrip() {
        let sig: [Float] = [1, 0.5, 0, 1, 0.25, 0.9, 0.1, 0.8, 0.33, 0, 0.7, 1]
        let scene = Data((0..<Learner.sceneDims).map { UInt8(bitPattern: Int8($0 % 100 - 50)) })
        let d = Learner.encode(signals: sig, scene: scene)
        XCTAssertEqual(d.count, Learner.featureCount)
        let x = Learner.decode(d)!
        XCTAssertEqual(x[0], 1, accuracy: 0.01)
        XCTAssertEqual(x[1], 0.5, accuracy: 0.01)
        XCTAssertEqual(x[Learner.signalCount + 1], -49.0 / 127, accuracy: 0.001)
    }

    func testLearnsAPatternAndReportsHonestAccuracy() {
        // Claude's score depends on smile (feature 0) and sharpness (feature 7), plus a little noise.
        var examples: [(id: String, x: [Double], y: Double)] = []
        for i in 0..<400 {
            var x = [Double](repeating: 0, count: Learner.featureCount)
            for j in 0..<x.count { x[j] = Double((i * 31 + j * 17) % 97) / 97 }
            let y = 2 + 5 * x[0] + 2.5 * x[7] + Double((i * 13) % 7 - 3) / 10
            examples.append(("photo-\(i)", x, y))
        }
        let m = Learner.train(examples)
        XCTAssertNotNil(m)
        XCTAssertGreaterThan(m!.within1, 0.9)
        XCTAssertLessThan(m!.meanGap, 0.6)
        XCTAssertEqual(m!.trainedOn, 400)
        XCTAssertNil(Learner.train(Array(examples.prefix(30))))   // too few to learn from
    }

    func testHeldBackSplitIsStable() {
        let ids = (0..<1000).map { "id\($0)" }
        let share = Double(ids.filter(Learner.heldBack).count) / 1000
        XCTAssertEqual(share, 0.2, accuracy: 0.05)
        XCTAssertEqual(ids.filter(Learner.heldBack), ids.filter(Learner.heldBack))
    }
}

private extension Array {
    func repeated(_ n: Int) -> [Element] { (0..<n).flatMap { _ in self } }
}
