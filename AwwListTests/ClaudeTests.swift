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
        // Sonnet batch: 1,200 tokens × $1/M + 40 × $5/M = $0.0014 a photo
        XCTAssertEqual(Claude.estimatedCost(photos: 1000, model: "claude-sonnet-5-5"), 1.4, accuracy: 0.0001)
    }
}
