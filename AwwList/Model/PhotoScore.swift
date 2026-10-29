import Foundation

/// Baby (under 1), Toddler (1 to 3) or Kid (4 and up).
enum AgeGroup: String, Codable, CaseIterable, Identifiable {
    case baby, toddler, kid
    var id: String { rawValue }
    var label: String {
        switch self { case .baby: "Baby"; case .toddler: "Toddler"; case .kid: "Kid" }
    }

    /// The group a child born on `birth` is in on `date`.
    static func of(birth: Date, at date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> AgeGroup {
        // Whole days only, so a birthday-party photo counts as the new age all day long.
        let years = calendar.dateComponents([.year], from: calendar.startOfDay(for: birth),
                                            to: calendar.startOfDay(for: date)).year ?? 0
        return years < 1 ? .baby : years < 4 ? .toddler : .kid
    }

    /// Age tags for one photo. Apple doesn't tell apps who is in a photo, so this combines the children's
    /// birthdays with what the photo looks like:
    /// - no birthdays saved: Baby when the photo looks like a baby, otherwise Kid (toddlers can't be told apart);
    /// - one child old enough to be in it: that child's group;
    /// - several children, one face: Baby if it looks like a baby and one of them is a baby, otherwise the
    ///   older children's groups;
    /// - several children and at least as many faces: every child's group (they're probably together);
    ///   a baby with one other face is most likely being held by a grown-up, so just Baby;
    /// - taken before any of the children was born: no age tag (shown under All ages only).
    static func tags(date: Date, birthdays: [Date], looksLikeBaby: Bool, faces: Int,
                     calendar: Calendar = Calendar(identifier: .gregorian)) -> Set<AgeGroup> {
        if birthdays.isEmpty { return looksLikeBaby ? [.baby] : [.kid] }
        let day = calendar.startOfDay(for: date)
        let born = birthdays.filter { calendar.startOfDay(for: $0) <= day }
        let groups = Set(born.map { of(birth: $0, at: date, calendar: calendar) })
        if groups.isEmpty { return [] }
        if groups.count == 1 { return groups }
        if looksLikeBaby && groups.contains(.baby) && faces <= 2 { return [.baby] }
        // Exactly two faces and two children: probably one child with a grown-up, so tag the main subject.
        if faces >= 3 && faces >= born.count { return groups }
        let older = groups.subtracting([.baby])
        return older.isEmpty ? groups : older
    }
}

/// What the scanner learned about one photo. Stored so a photo is only analyzed once.
struct PhotoScore: Codable, Hashable, Identifiable {
    /// PHAsset.localIdentifier
    let id: String
    let date: Date
    /// Raw cuteness from the scorer (0...1). Nil when the photo was left out.
    let raw: Double?
    /// Why the photo was left out (screenshot, no child, swimwear, ...). Nil when it counts.
    let excluded: String?
    let age: AgeGroup?
    /// Short description built from the labels, e.g. "Big smile" or "Two kids together".
    let caption: String
    /// Scorer.version that produced this result; nil for results saved by the first release.
    var version: Int? = nil
    /// Number of faces found (used to tell siblings-together photos from solo ones).
    var faces: Int? = nil
    /// Face fingerprints for Who's Who (counted photos only); nil until measured.
    var faceRecords: [FaceRecord]? = nil
}

/// One moment: photos taken less than 60 seconds apart (2 minutes at most), represented by its best shot.
struct Moment: Identifiable, Hashable {
    var id: String { best.id }
    let best: PhotoScore
    let shots: Int
    /// Every shot in the burst, so removing a moment removes all of it.
    let memberIDs: [String]
    /// Calibrated 1...10 score.
    var score: Int
    /// Baby / Toddler / Kid tags (see AgeGroup.tags).
    var ages: Set<AgeGroup> = []
    /// Named people (Who's Who) recognized in the best shot.
    var people: Set<UUID> = []
    var year: Int { Calendar.current.component(.year, from: best.date) }
}
