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

final class KidBalanceTests: XCTestCase {
    func testBalanceKids() {
        let girl = UUID(), boy = UUID()
        func m(_ i: Int, _ who: Set<UUID>) -> Moment {
            var x = Moment(best: PhotoScore(id: "p\(i)", date: Date(timeIntervalSince1970: Double(i) * 86_400), raw: 0.5,
                                            excluded: nil, age: nil, caption: "", version: 1),
                           shots: 1, memberIDs: ["p\(i)"], score: 5)
            x.people = who
            return x
        }
        // Scores favor her: her 6 photos rank above his 6.
        let ranked = (0..<6).map { m($0, [girl]) } + (6..<12).map { m($0, [boy]) }
        let out = KidBalance.order(ranked, kids: [(girl, nil), (boy, nil)])
        XCTAssertEqual(out.count, 12)
        XCTAssertEqual(Set(out.map(\.id)).count, 12)                                   // nothing lost or doubled
        let top4 = out.prefix(4)
        XCTAssertEqual(top4.filter { $0.people.contains(boy) }.count, 2)               // half the top spots each
        XCTAssertEqual(out.first?.id, "p0")                                            // the best photo still first
        // Each child's own order is unchanged.
        XCTAssertEqual(out.filter { $0.people.contains(boy) }.map(\.id), (6..<12).map { "p\($0)" })
        // One named child: nothing to balance.
        XCTAssertEqual(KidBalance.order(ranked, kids: [(girl, nil)]).map(\.id), ranked.map(\.id))
        // A grown-up with a birthday isn't balanced as a kid: with him born long before these photos, nothing moves.
        let grownUp = Date(timeIntervalSince1970: 0).addingTimeInterval(-40 * 365 * 86_400)
        XCTAssertEqual(KidBalance.order(ranked, kids: [(girl, nil), (boy, grownUp)]).map(\.id), ranked.map(\.id))
    }
}

final class SettingAndPlaceTests: XCTestCase {
    private func moment(_ i: Int, scenes: [String], date: Date = Date(timeIntervalSince1970: 1_600_000_000)) -> Moment {
        var p = PhotoScore(id: "s\(i)", date: date.addingTimeInterval(Double(i) * 86_400 * 2), raw: 0.5, excluded: nil, age: nil, caption: "", version: 1)
        p.scenes = scenes
        return Moment(best: p, shots: 1, memberIDs: [p.id], score: 5)
    }

    func testSettingMenu() {
        let beach = (0..<5).map { moment($0, scenes: ["beach", "sand"]) }
        let horses = (5..<15).map { moment($0, scenes: ["horse_riding"]) }
        let menu = Surroundings.menu(beach + horses)
        // Built-in kinds you have 3+ photos of, then things seen often in your photos (8+).
        XCTAssertEqual(menu.first?.kind.id, "label:horse_riding")                             // most photos first
        XCTAssertTrue(menu.contains { $0.kind.id == "beach" && $0.count == 5 })
        XCTAssertTrue(menu.contains { $0.kind.id == "label:horse_riding" && $0.kind.name == "Horse riding" && $0.count == 10 })
        XCTAssertFalse(menu.contains { $0.kind.id == "sports" })
        // Holidays count by date too.
        var c = DateComponents(); c.year = 2021; c.month = 12; c.day = 25; c.hour = 10
        let xmas = Calendar.current.date(from: c)!
        let parties = Surroundings.builtIn.first { $0.id == "parties" }!
        XCTAssertTrue(Surroundings.matches(moment(0, scenes: [], date: xmas).best.withDate(xmas), parties))
    }

    func testPlacesAndShots() {
        XCTAssertEqual(PlaceBook.cell(30.2460, -87.7008), PlaceBook.cell(30.2449, -87.7011))   // same few-km square
        XCTAssertNotEqual(PlaceBook.cell(30.25, -87.70), PlaceBook.cell(35.15, -90.05))       // Gulf Shores vs Memphis
        // Two faces with a grown-up recognized in the photo: Family & groups, not Kids together.
        var m = moment(1, scenes: [])
        XCTAssertEqual(ShotKind.of(faces: 2, adults: 0), .kids)
        m.namedAdults = 1
        XCTAssertEqual(ShotKind.of(faces: 2, adults: max(m.best.adults ?? 0, m.namedAdults)), .family)
    }
}

private extension PhotoScore {
    func withDate(_ d: Date) -> PhotoScore { var p = self; p.date = d; return p }
}

final class PairwiseTests: XCTestCase {
    private let day = 86_400.0
    private func cand(_ id: String, _ v: Double, _ d: Double, people: Set<UUID> = []) -> Pairwise.Candidate {
        Pairwise.Candidate(id: id, value: v, date: Date(timeIntervalSince1970: 1_600_000_000 + d), people: people)
    }

    func testRatingMath() {
        // A beats B twice, B beats C twice: A > B > C, B in the middle near 0.
        let t = Date()
        let votes = [PairVote(a: "A", b: "B", winner: "A", date: t), PairVote(a: "B", b: "A", winner: "A", date: t),
                     PairVote(a: "B", b: "C", winner: "B", date: t), PairVote(a: "C", b: "B", winner: "B", date: t),
                     PairVote(a: "A", b: "C", winner: nil, date: t)]                    // a skip changes nothing
        let s = Pairwise.strengths(votes)
        XCTAssertGreaterThan(s["A"]!, s["B"]!); XCTAssertGreaterThan(s["B"]!, s["C"]!)
        XCTAssertEqual(s["B"]!, 0, accuracy: 0.05)
        XCTAssertEqual(s["A"]!, -s["C"]!, accuracy: 0.05)                            // symmetric
        // No votes: nothing. A thumbs up alone is only a weak start, and a real vote outweighs it.
        XCTAssertTrue(Pairwise.strengths([]).isEmpty)
        let up = Pairwise.strengths([], starts: ["X": 1])["X"]!
        XCTAssertGreaterThan(up, 0); XCTAssertLessThan(up, 0.5)
        let overruled = Pairwise.strengths([PairVote(a: "X", b: "Y", winner: "Y", date: t),
                                            PairVote(a: "Y", b: "X", winner: "Y", date: t)], starts: ["X": 1])
        XCTAssertLessThan(overruled["X"]!, overruled["Y"]!)
        // Votes outweigh Claude where they disagree: A (Claude 6.5) picked over B (Claude 7) twice ends up above it.
        let ab = Pairwise.strengths(Array(votes.prefix(2)))
        XCTAssertGreaterThan(Pairwise.target(anchor: 6.5, strength: ab["A"]!), Pairwise.target(anchor: 7, strength: ab["B"]!))
        XCTAssertEqual(Pairwise.target(anchor: 9.5, strength: 10), 10)                // capped at 10
        XCTAssertEqual(Pairwise.chance(0, 0), 0.5, accuracy: 1e-9)
    }

    func testPairPicker() {
        let kid = UUID()
        // Close calls: 1 and 2 are a point apart; 4 is far off in score; 1b is a near-duplicate of 1 (2 minutes later).
        let pool = [cand("1", 7.0, 0, people: [kid]), cand("1b", 7.0, 120, people: [kid]), cand("2", 6.6, 5 * day, people: [kid]),
                    cand("3", 6.4, 9 * day), cand("4", 2.0, 20 * day)]
        var votes: [PairVote] = []
        var seen = Set<String>()
        var appearances: [String: Int] = [:]
        while let pair = Pairwise.next(pool, votes: votes, strengths: Pairwise.strengths(votes)) {
            let (a, b) = pair
            XCTAssertNotEqual(a.id, b.id)
            XCTAssertTrue(seen.insert(Pairwise.key(a.id, b.id)).inserted, "same pair asked twice")
            XCTAssertLessThanOrEqual(abs(a.value - b.value), 2)
            XCTAssertFalse(Set([a.id, b.id]) == ["1", "1b"], "near-duplicates paired")
            XCTAssertFalse(a.id == "4" || b.id == "4", "a photo far off in score was paired")
            appearances[a.id, default: 0] += 1; appearances[b.id, default: 0] += 1
            votes.append(PairVote(a: a.id, b: b.id, winner: a.id, date: Date()))
            XCTAssertLessThan(votes.count, 20)
        }
        // The first pair is the closest call with the same child.
        let first = Pairwise.next(pool, votes: [], strengths: [:])!
        XCTAssertEqual(Set([first.0.id, first.1.id]), ["1", "2"])
        // Every photo that can be paired was paired before any was in many pairs.
        XCTAssertEqual(Set(appearances.keys), ["1", "1b", "2", "3"])
    }
}

final class SnapScorerTests: XCTestCase {
    private func photo(turn: Double?, light: Double?, top: Double = 0.75) -> Signals {
        var f = FaceSignal(area: 0.06, quality: 0.6, smile: true, eyesClosed: false)
        f.child = 0.05
        f.box = [0.4, top - 0.2, 0.2, 0.2]
        f.turn = turn; f.light = light
        var s = Signals(); s.faces = [f]; s.sharpness = 1
        return s
    }

    func testProfilePhotoMeasurements() {
        // Looking at the camera in good light beats looking away in a shadow.
        let good = SnapScorer.value(photo(turn: 0, light: 0.9))!, away = SnapScorer.value(photo(turn: 0.8, light: 0.3))!
        XCTAssertGreaterThan(good, away)
        // Measurements a photo doesn't have are left out, not counted as zero.
        let unmeasured = SnapScorer.value(photo(turn: nil, light: nil))!
        XCTAssertGreaterThan(unmeasured, away)
        XCTAssertTrue((0...1).contains(good) && (0...1).contains(unmeasured))
        // A head cut off at the top frames worse than one with room above it.
        var cut = FaceSignal(); cut.box = [0.4, 0.8, 0.2, 0.2]
        var room = FaceSignal(); room.box = [0.4, 0.55, 0.2, 0.2]
        XCTAssertLessThan(SnapScorer.framing(cut)!, SnapScorer.framing(room)!)
        XCTAssertEqual(SnapScorer.framing(room)!, 1, accuracy: 1e-9)
        // No grown-up: no score.
        var kid = photo(turn: 0, light: 1); kid.faces[0].child = 0.9; kid.childConfidence = 0.9
        XCTAssertNil(SnapScorer.value(kid))
    }

    func testSnapVersionIsSeparate() {
        XCTAssertEqual(Scorer.version(.aww), Scorer.version)
        XCTAssertNotEqual(Scorer.version(.snap), Scorer.version)
    }
}

final class VoteShiftTests: XCTestCase {
    func testVotesMoveRankingsByAtMostTwoPoints() {
        let t = Date()
        // One vote: about three quarters of a point each way.
        let one = Pairwise.strengths([PairVote(a: "A", b: "B", winner: "A", date: t)])
        XCTAssertEqual(Pairwise.shift(one["A"]!), 0.75, accuracy: 0.05)
        XCTAssertEqual(Pairwise.shift(one["B"]!), -0.75, accuracy: 0.05)
        // Picked over five different photos: capped at 2.
        let five = Pairwise.strengths((0..<5).map { PairVote(a: "A", b: "B\($0)", winner: "A", date: t) })
        XCTAssertEqual(Pairwise.shift(five["A"]!), Pairwise.maxShift, accuracy: 1e-9)
        XCTAssertEqual(Pairwise.maxShift, 2)
    }
}

final class SnapAdultTests: XCTestCase {
    func testGrownUpsCountByTheirOwnReading() {
        var f = FaceSignal(area: 0.01, quality: 0.5, smile: true, eyesClosed: false)
        f.box = [0.45, 0.5, 0.05, 0.03]          // a small face (3% of the photo's height), as in a full-length shot
        f.child = 0.1                            // this person reads as a grown-up
        var s = Signals(); s.faces = [f]; s.sharpness = 1
        s.childConfidence = 0.6                  // even though the whole photo's "child" label fired
        XCTAssertEqual(SnapScorer.adults(s), [0])
        XCTAssertNotNil(SnapScorer.value(s))
        // The same face reading as a child isn't a grown-up.
        s.faces[0].child = 0.7
        XCTAssertTrue(SnapScorer.adults(s).isEmpty)
        // Too small to judge (under 2.5% of the height).
        s.faces[0].child = 0.1; s.faces[0].box = [0.45, 0.5, 0.03, 0.02]
        XCTAssertTrue(SnapScorer.adults(s).isEmpty)
        // A small face needs a clearly low reading: 0.22 is a grown-up at 4% tall, not at 3%.
        s.faces[0].box = [0.45, 0.5, 0.05, 0.03]; s.faces[0].child = 0.22
        XCTAssertTrue(SnapScorer.adults(s).isEmpty)
        s.faces[0].box = [0.45, 0.5, 0.06, 0.05]
        XCTAssertEqual(SnapScorer.adults(s), [0])
    }

    func testKidsStayKids() {
        // Siblings of similar size, cheek to cheek: the bigger one's low face-only reading isn't a grown-up.
        var sib = Signals()
        sib.faces = [FaceSignal(area: 0.08, box: [0.1, 0.4, 0.28, 0.28]), FaceSignal(area: 0.065, box: [0.4, 0.4, 0.25, 0.25])]
        sib.faces[0].child = 0.2; sib.faces[0].childTight = true; sib.faces[1].child = 0.4
        XCTAssertTrue(SnapScorer.adults(sib).isEmpty)
        // Two kids who read a bit low: nobody is a grown-up.
        var lone = Signals()
        lone.faces = [FaceSignal(area: 0.1, box: [0.1, 0.3, 0.3, 0.33]), FaceSignal(area: 0.06, box: [0.6, 0.3, 0.25, 0.25])]
        lone.faces[0].child = 0.25; lone.faces[1].child = 0.28
        XCTAssertTrue(SnapScorer.adults(lone).isEmpty)
    }
}
