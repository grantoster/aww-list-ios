import XCTest
@testable import AwwList

final class ClaudeTests: XCTestCase {
    func testParsesReplies() {
        let v = Claude.parse("```json\n{\"score\": 8.5, \"caption\": \"giggling in the leaf pile\", \"exclude\": null}\n```", model: "m")
        XCTAssertEqual(v?.score, 8.5)
        XCTAssertEqual(v?.caption, "giggling in the leaf pile")
        XCTAssertNil(v?.exclude)
        XCTAssertEqual(Claude.parse("{\"score\": 4, \"caption\": \"x\", \"exclude\": \"swimwear\"}", model: "m")?.exclude, "swimwear")
        XCTAssertNil(Claude.parse("{\"score\": 4, \"caption\": \"x\", \"exclude\": \"weird\"}", model: "m")?.exclude)
        XCTAssertEqual(Claude.parse("{\"score\": 14}", model: "m")?.score, 10)
        XCTAssertNil(Claude.parse("no json here", model: "m"))
        XCTAssertEqual(Claude.parse("{\"score\": 8.45}", model: "m")?.score, 8.5)   // halves round up
        let cut = #"{"custom_id":"p3","result":{"type":"succeeded","message":{"stop_reason":"max_tokens","content":[]}}}"#
        XCTAssertNil(Claude.parseResultLine(cut))
    }

    func testParsesBatchResultLines() {
        let line = #"{"custom_id":"p1_9","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"{\"score\":7}"}]}}}"#
        XCTAssertEqual(Claude.parseResultLine(line)?.id, "p1_9")
        XCTAssertEqual(Claude.parseResultLine(line)?.text, #"{"score":7}"#)
        XCTAssertNil(Claude.parseResultLine(#"{"custom_id":"p2","result":{"type":"errored"}}"#))
    }

    func testHalfRoundsUp() {
        XCTAssertEqual(Claude.displayScore(8.5), 9)
        XCTAssertEqual(Claude.displayScore(8.4), 8)
        XCTAssertEqual(Claude.displayScore(6.5), 7)
    }

    func testCostEstimateUsesBatchPrices() {
        // Sonnet batch: 1,200 tokens × $1/M + 300 × $5/M = $0.0027 a photo
        XCTAssertEqual(Claude.estimatedCost(photos: 1000, model: "claude-sonnet-5-5"), 2.7, accuracy: 0.0001)
        XCTAssertEqual(Claude.dollars(0.125), "$0.13")
        XCTAssertEqual(Claude.dollars(micros: Claude.costMicros(photos: 775, model: "claude-opus-5-5")), "$4.19")   // $4.185 rounds up
        XCTAssertEqual(Claude.dollars(micros: Claude.costMicros(photos: 1550, model: "claude-sonnet-5-5")), "$4.19")
        XCTAssertEqual(Claude.dollars(2.7), "$2.70")
    }

    @MainActor func testRescanKeepsClaudesVerdict() {
        let lib = Library()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        var p = PhotoScore(id: "keep-test", date: t, raw: 0.7, excluded: nil, age: .kid, caption: "", version: Scorer.version)
        p.claude = ClaudeVerdict(score: 8, caption: "x", exclude: "swimwear", model: "m", rubric: Claude.rubric)
        lib.add([p])
        var again = p; again.claude = nil
        lib.add([again])
        XCTAssertEqual(lib.photos["keep-test"]?.claude?.exclude, "swimwear")
    }

    func testSetAsidePhotosAreOfferedToClaude() {
        var sig = Signals(); sig.childConfidence = 0.2
        sig.faces = [FaceSignal(area: 0.1, quality: 0.6, smile: true)]; sig.sharpness = 1
        XCTAssertEqual(Scorer.score(sig).excluded, "No child")
        let soft = Scorer.softScore(sig)
        XCTAssertNotNil(soft)
        var screenshot = sig; screenshot.isScreenshot = true
        XCTAssertNil(Scorer.softScore(screenshot))
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        var p = PhotoScore(id: "aside", date: t, raw: nil, excluded: "No child", age: .kid, caption: "", version: Scorer.version)
        p.soft = soft
        XCTAssertEqual(Scorer.moments(from: [p]).count, 1)                // flagged, but still listed
        XCTAssertEqual(p.appleFlag, "No child")
    }

    func testOnlyBathAndUndressedAreHeldBack() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        func flagged(_ id: String, _ why: String, _ dt: Double) -> PhotoScore {
            var p = PhotoScore(id: id, date: t.addingTimeInterval(dt), raw: nil, excluded: why, age: .kid, caption: "", version: Scorer.version)
            p.soft = 0.5; return p
        }
        let ok = PhotoScore(id: "ok", date: t.addingTimeInterval(400), raw: 0.6, excluded: nil, age: .kid, caption: "", version: Scorer.version)
        for why in ["Water", "Swimwear", "Shirtless", "AI image", "Edited", "Not a camera photo", "No face"] {
            XCTAssertEqual(Set(Scorer.moments(from: [flagged("f", why, 0), ok]).map(\.best.id)), ["f", "ok"], why)
        }
        let bath = flagged("bath", "Bath", 0)
        XCTAssertTrue(Scorer.moments(from: [bath, ok]).isEmpty)                         // held back, and its 10 minutes
        XCTAssertEqual(Set(Scorer.moments(from: [bath, ok], putBack: ["bath"]).map(\.best.id)), ["bath", "ok"])
        var undressed = flagged("u", "Undressed", 0); undressed.soft = nil
        XCTAssertEqual(Scorer.moments(from: [undressed], putBack: ["u"]).count, 0)     // nothing to score it by
        let doc = PhotoScore(id: "d", date: t, raw: nil, excluded: "Document", age: nil, caption: "", version: Scorer.version)
        XCTAssertNil(Scorer.listedValue(doc))
        // Putting a bath photo back lists it, but it and its whole session still never go to Claude.
        let burst = PhotoScore(id: "burst", date: t.addingTimeInterval(10), raw: 0.7, excluded: nil, age: .kid, caption: "", version: Scorer.version)
        let never = Scorer.neverSend([bath, burst, ok], allowSwimShirtless: false)
        XCTAssertEqual(never, ["bath", "burst", "ok"])   // ok is 400 s later, inside the 10 minutes
        XCTAssertEqual(Set(Scorer.moments(from: [bath, burst, ok], putBack: ["bath"]).flatMap(\.ids)), ["bath", "burst", "ok"])
        // A put-back photo with no score doesn't free its neighbors.
        XCTAssertTrue(Scorer.moments(from: [undressed, ok.withDate(t.addingTimeInterval(60))], putBack: ["u"]).isEmpty)
        // Swimwear: listed, but not sent (nor the 10 minutes around it) unless allowed.
        let swim = flagged("swim", "Swimwear", 0)
        XCTAssertEqual(Scorer.neverSend([swim, burst, ok], allowSwimShirtless: false), ["swim", "burst", "ok"])
        XCTAssertTrue(Scorer.neverSend([swim, burst, ok], allowSwimShirtless: true).isEmpty)
        // Claude's own bath call, or a photo that couldn't be read, also blocks the 10 minutes around it.
        var claudeBath = PhotoScore(id: "cb", date: t, raw: 0.6, excluded: nil, age: .kid, caption: "", version: Scorer.version)
        claudeBath.claude = ClaudeVerdict(score: 1, caption: "", exclude: "bath", model: "m", rubric: Claude.rubric)
        XCTAssertEqual(Scorer.neverSend([claudeBath, burst], allowSwimShirtless: true), ["cb", "burst"])
        let unreadable = PhotoScore(id: "x", date: t, raw: nil, excluded: Scorer.unavailable, age: nil, caption: "", version: Scorer.version)
        XCTAssertEqual(Scorer.neverSend([unreadable, burst], allowSwimShirtless: true), ["x", "burst"])
    }

    func testFilterLearnsClaudesRemovals() {
        // Claude removes photos whose first feature is high; the filter should pick that up.
        var ex: [(date: Date, x: [Double], removed: Bool)] = []
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(UInt64(1) << 53) }
        for i in 0..<400 {
            let d = Date(timeIntervalSince1970: 1_600_000_000 + Double(i) * 86_400)
            var x = (0..<Learner.featureCount).map { _ in rnd() }
            let removed = i % 4 == 0
            x[0] = removed ? 0.9 + 0.1 * rnd() : 0.4 * rnd()
            ex.append((d, x, removed))
        }
        let f = Learner.trainFilter(ex)
        XCTAssertNotNil(f)
        guard let f else { return }
        XCTAssertTrue(f.useful)
        XCTAssertGreaterThan(f.accuracy, f.baselineAccuracy)
        XCTAssertGreaterThan(f.caught ?? 0, 0.8)
        XCTAssertNil(Learner.trainFilter(ex.map { ($0.date, $0.x, false) }))   // no removals: nothing to learn
        var few = f; few.testRemovals = 4
        XCTAssertFalse(few.useful)                                              // too few removals in the check
    }
}

final class LearningPackTests: XCTestCase {
    func testPackRoundTripsAndStaysSmall() {
        let n = Learner.featureCount
        let arr = (0..<n).map { Double($0) / 7 - 3 }
        let m = LearnedModel(mean: arr, std: arr.map { abs($0) + 1 }, weights: arr.reversed(), bias: 6.4, lambda: 100,
                             trainedOn: 300, tested: 60, within1: 0.7, meanGap: 0.8, date: Date(timeIntervalSince1970: 1_800_000_000),
                             baselineWithin1: 0.5, baselineGap: 1.2)
        let f = LearnedFilter(mean: arr, std: arr.map { abs($0) + 1 }, weights: arr, bias: 0.2, lambda: 10, trainedOn: 300,
                              removals: 40, tested: 60, accuracy: 0.9, baselineAccuracy: 0.85, caught: 0.5, wronglyRemoved: 0.02,
                              date: Date(timeIntervalSince1970: 1_800_000_000))
        let text = LearningPack(model: m, filter: f).text()
        XCTAssertLessThan(text.utf8.count, 8000)
        let back = LearningPack.read(text)
        XCTAssertEqual(back.model?.weights.count, n)
        XCTAssertEqual(back.model?.weights.first ?? 0, m.weights.first!, accuracy: 1e-5)
        XCTAssertEqual(back.model?.bias, 6.4)
        XCTAssertEqual(back.filter?.removals, 40)
        XCTAssertEqual(back.filter?.std.last ?? 0, f.std.last!, accuracy: 1e-5)
        XCTAssertNil(LearningPack.read("not a pack").model)
        XCTAssertNil(LearningPack.read(LearningPack(model: nil, filter: f).text()).model)
    }
}

final class PoolTests: XCTestCase {
    func testFacesWithoutChildLabelAreOfferedNotListed() {
        var s = Signals(); s.childConfidence = 0.02
        s.faces = [FaceSignal(area: 0.1, quality: 0.6, smile: true)]; s.sharpness = 1
        XCTAssertEqual(Scorer.score(s).excluded, "No child")
        XCTAssertNil(Scorer.softScore(s))
        XCTAssertNotNil(Scorer.poolScore(s))
        var none = s; none.faces = []
        XCTAssertNil(Scorer.poolScore(none))
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        var p = PhotoScore(id: "g", date: t, raw: nil, excluded: "No child seen", age: .kid, caption: "", version: Scorer.version)
        p.soft = Scorer.poolScore(s)
        XCTAssertTrue(Scorer.moments(from: [p]).isEmpty)
        XCTAssertEqual(Scorer.moments(from: [p], includePoolOnly: true).count, 1)
        XCTAssertEqual(Scorer.neverSend([p], allowSwimShirtless: false, removed: ["g": "bath"]), ["g"])
        // A bare chest with a weak child label is never offered or listed (the shirtless safeguard can't see it).
        var bare = s; bare.faces[0].bareTorso = 0.9
        XCTAssertNil(Scorer.poolScore(bare))
        var band = bare; band.childConfidence = 0.12
        XCTAssertEqual(Scorer.score(band).excluded, "Shirtless")   // gets the shirtless safeguards (2-minute window)
        var bp = PhotoScore(id: "band", date: t, raw: nil, excluded: "Shirtless", age: .kid, caption: "", version: Scorer.version)
        bp.soft = Scorer.softScore(band)
        XCTAssertTrue(Scorer.neverSend([bp], allowSwimShirtless: false).contains("band"))
        // Photos in the iOS Hidden album are never listed.
        var h = PhotoScore(id: "h", date: t, raw: 0.8, excluded: nil, age: .kid, caption: "", version: Scorer.version)
        h.hiddenAlbum = true
        XCTAssertTrue(Scorer.moments(from: [h]).isEmpty)
    }
}

private extension PhotoScore {
    func withDate(_ d: Date) -> PhotoScore {
        var p = PhotoScore(id: id, date: d, raw: raw, excluded: excluded, age: age, caption: caption, version: version)
        p.soft = soft; return p
    }
}
