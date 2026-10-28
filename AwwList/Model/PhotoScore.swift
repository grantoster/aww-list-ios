import Foundation

/// Which age group a photo's child looks like, from the on-device image labels.
enum AgeGroup: String, Codable, CaseIterable, Identifiable {
    case baby, kid
    var id: String { rawValue }
    var label: String { self == .baby ? "Baby" : "Kid" }
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
}

/// One moment: photos taken less than 60 seconds apart, represented by its best shot.
struct Moment: Identifiable, Hashable {
    var id: String { best.id }
    let best: PhotoScore
    let shots: Int
    /// Calibrated 1...10 score.
    var score: Int
    var year: Int { Calendar.current.component(.year, from: best.date) }
}
