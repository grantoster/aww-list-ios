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
}
