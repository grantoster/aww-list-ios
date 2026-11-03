import Foundation

/// "Balance kids" (Settings → Home list): re-orders a ranked list so each named child gets a share of the top spots
/// that matches how often they appear in it, instead of whoever the scores happen to favor. Photos of nobody named
/// count as one more group. Within each child (and each group) the order stays best first; scores don't change.
enum KidBalance {
    /// Who counts: named people with a birthday (your kids), or everyone named if no one has a birthday. Each comes
    /// with their birthday: someone counts only in photos taken while they were under 13 (as for the age groups).
    static func kids(_ people: [Person]) -> [(id: UUID, birthday: Date?)] {
        let withBirthday = people.filter { $0.birthday != nil }
        return (withBirthday.isEmpty ? people : withBirthday).map { ($0.id, $0.birthday) }
    }

    private static let calendar = Calendar(identifier: .gregorian)
    static func childAt(_ birth: Date?, _ date: Date) -> Bool {
        guard let birth else { return true }
        return birth <= date && (calendar.dateComponents([.year], from: birth, to: date).year ?? 0) < 13
    }

    static func order(_ ms: [Moment], kids: [(id: UUID, birthday: Date?)]) -> [Moment] {
        guard kids.count >= 2, ms.count > 1 else { return ms }
        var index: [UUID: Int] = [:]
        for (i, k) in kids.enumerated() where index[k.id] == nil { index[k.id] = i }
        let others = kids.count, groups = kids.count + 1
        // Each moment belongs to every child in it (or to "others").
        let member: [[Int]] = ms.map { m in
            let g = Set(m.people.compactMap { id in index[id].flatMap { childAt(kids[$0].birthday, m.best.date) ? $0 : nil } }).sorted()
            return g.isEmpty ? [others] : g
        }
        var queues = Array(repeating: [Int](), count: groups)
        for (i, g) in member.enumerated() { for k in g { queues[k].append(i) } }   // already best first
        let total = Double(queues.reduce(0) { $0 + $1.count })
        let share = queues.map { Double($0.count) / total }
        let kidsInList = (0..<kids.count).filter { !queues[$0].isEmpty }.count
        guard kidsInList >= 2 else { return ms }
        var head = Array(repeating: 0, count: groups), got = Array(repeating: 0.0, count: groups)
        var used = Array(repeating: false, count: ms.count), credits = 0.0
        var out: [Moment] = []
        out.reserveCapacity(ms.count)
        while out.count < ms.count {
            // The group furthest behind its share (ties: the one whose next photo ranks higher).
            var pick = -1, pickNeed = -Double.infinity, pickRank = Int.max
            for k in 0..<groups {
                while head[k] < queues[k].count && used[queues[k][head[k]]] { head[k] += 1 }
                guard head[k] < queues[k].count else { continue }
                let need = share[k] * (credits + 1) - got[k], rank = queues[k][head[k]]
                if need > pickNeed + 1e-9 || (abs(need - pickNeed) <= 1e-9 && rank < pickRank) {
                    pick = k; pickNeed = need; pickRank = rank
                }
            }
            guard pick >= 0 else { break }
            let i = queues[pick][head[pick]]
            used[i] = true; out.append(ms[i])
            for k in member[i] { got[k] += 1; credits += 1 }
        }
        return out
    }
}
