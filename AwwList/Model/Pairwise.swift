import Foundation

/// One "Which is cuter?" answer from Learn my Likes: the two photos (best-shot ids) and the one you picked, or
/// nil when you skipped the pair. Votes stay on this iPhone (they're only in the learning data you choose to send).
struct PairVote: Codable, Hashable {
    var a: String
    var b: String
    var winner: String?
    var date: Date
}

/// The math behind Learn my Likes: turning votes into a preference score for each photo (Bradley-Terry), and
/// choosing the next pair to ask about. Pure functions, so they're unit tested.
enum Pairwise {
    /// The same key for a pair whichever way round it was shown.
    static func key(_ a: String, _ b: String) -> String { a < b ? a + "|" + b : b + "|" + a }

    /// How far, in score points, one unit of Bradley-Terry strength (log odds) moves a photo.
    static let pointsPerUnit = 1.5
    /// The most votes can move a photo from where Claude (or the learning) put it, in points.
    static let maxShift = 3.0

    /// Each photo's strength (log scale; 0 = average) from the votes, by Bradley-Terry's minorize-maximize steps.
    /// Every photo also plays `prior` imaginary games against an average photo, winning half, so one vote can't
    /// send it to the top or bottom. `starts` are weak hints from earlier thumbs (+1 up, −1 down), each worth
    /// `thumbWeight` of an imaginary game won or lost against an average photo; real votes soon outweigh them.
    static func strengths(_ votes: [PairVote], starts: [String: Int] = [:], prior: Double = 1, thumbWeight: Double = 0.15,
                          iterations: Int = 200) -> [String: Double] {
        var wins: [String: Double] = [:]
        var games: [String: [String: Double]] = [:]   // photo → opponent → games played
        for v in votes {
            guard let w = v.winner, v.a != v.b, w == v.a || w == v.b else { continue }   // skips don't count
            let l = w == v.a ? v.b : v.a
            wins[w, default: 0] += 1
            games[w, default: [:]][l, default: 0] += 1
            games[l, default: [:]][w, default: 0] += 1
        }
        let ids = Set(games.keys).union(starts.keys)
        guard !ids.isEmpty else { return [:] }
        var theta = Dictionary(uniqueKeysWithValues: ids.map { ($0, 1.0) })
        for _ in 0..<iterations {
            var next = theta
            var change = 0.0
            for i in ids {
                let t = theta[i]!, s = Double(starts[i] ?? 0)
                let hint = abs(s) * thumbWeight
                // Imaginary games against an average photo (strength 1): the prior's even record plus the thumbs hint.
                var w = (wins[i] ?? 0) + prior / 2 + (s > 0 ? hint : 0)
                var denom = (prior + hint) / (t + 1)
                for (j, n) in games[i] ?? [:] { denom += n / (t + theta[j]!) }
                w = max(w, 1e-9)
                let nt = w / denom
                change = max(change, abs(log(nt) - log(t)))
                next[i] = nt
            }
            theta = next
            if change < 1e-7 { break }
        }
        return theta.mapValues { log($0) }
    }

    /// The training target for a photo: where Claude (or the learning) put it, moved by your votes. With several
    /// votes the move is big enough that a photo you keep picking ends up above one Claude scored higher.
    static func target(anchor: Double, strength: Double) -> Double {
        max(1, min(10, anchor + max(-maxShift, min(maxShift, pointsPerUnit * strength))))
    }

    /// How many photos' preference moved by at least `by` points between two sets of strengths.
    static func moved(from old: [String: Double], to new: [String: Double], by: Double = 0.25) -> Int {
        Set(old.keys).union(new.keys).filter { abs(pointsPerUnit * ((new[$0] ?? 0) - (old[$0] ?? 0))) >= by }.count
    }

    /// The chance the first photo is picked over the second, by the current strengths.
    static func chance(_ a: Double, _ b: Double) -> Double { 1 / (1 + exp(b - a)) }

    // MARK: Choosing pairs

    /// One photo to offer: its id, score (Claude's or the learned one, 1–10), date, people and age groups.
    struct Candidate {
        var id: String
        var value: Double
        var date: Date
        var people: Set<UUID> = []
        var ages: Set<AgeGroup> = []
        var similar: Set<String> = []
        var year: Int { Calendar.current.component(.year, from: date) }
    }

    /// The next pair to ask about, or nil when there's nothing left to ask. It starts from the photo in the fewest
    /// pairs so far (best-ranked first on ties), so every photo is in a few pairs before any is in many, and pairs
    /// it with the close call it's least sure about: scores within about a point (two at most), the same child,
    /// the same age group or year, and strengths that make either answer about as likely. Never a pair already
    /// asked (or skipped), the same photo twice, or two shots from the same burst or few minutes.
    static func next(_ pool: [Candidate], votes: [PairVote], strengths: [String: Double]) -> (Candidate, Candidate)? {
        guard pool.count >= 2 else { return nil }
        let asked = Set(votes.map { key($0.a, $0.b) })
        var appear: [String: Int] = [:]
        for v in votes { appear[v.a, default: 0] += 1; appear[v.b, default: 0] += 1 }
        let order = pool.indices.sorted { (appear[pool[$0].id] ?? 0, $0) < (appear[pool[$1].id] ?? 0, $1) }
        for ai in order {
            let a = pool[ai]
            var best: (c: Candidate, s: Double)? = nil
            for b in pool where b.id != a.id && !asked.contains(key(a.id, b.id)) && apart(a, b) {
                let diff = abs(a.value - b.value)
                guard diff <= 2 else { continue }
                var s = diff <= 1 ? 1 - diff : 0.3 * (2 - diff)                // close calls first
                if !a.people.isDisjoint(with: b.people) { s += 0.5 }        // the same child
                if !a.ages.isDisjoint(with: b.ages) { s += 0.25 }           // the same age group
                if a.year == b.year { s += 0.25 }                          // the same year
                let p = chance(strengths[a.id] ?? 0, strengths[b.id] ?? 0)
                s += 0.5 * (1 - 2 * abs(p - 0.5))                          // the answer the ranking is least sure of
                s -= 0.15 * Double(appear[b.id] ?? 0)                       // spread votes over many photos
                if s > (best?.s ?? -.infinity) { best = (b, s) }
            }
            if let best { return (a, best.c) }
        }
        return nil
    }

    /// Not near-duplicates: at least 10 minutes apart and not folded together as similar shots.
    static func apart(_ a: Candidate, _ b: Candidate) -> Bool {
        abs(a.date.timeIntervalSince(b.date)) >= 600 && !a.similar.contains(b.id) && !b.similar.contains(a.id)
    }
}
