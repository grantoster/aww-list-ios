import SwiftUI

enum Theme {
    static let accent = Color("AccentColor")
    static let gold = Color(red: 0.96, green: 0.72, blue: 0.20)
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
}

/// Little score chip drawn on top of a photo.
struct ScoreBadge: View {
    let score: Int
    var body: some View {
        Text("\(score)")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(score >= 9 ? Theme.gold : Color.black.opacity(0.55), in: Capsule())
            .accessibilityLabel("Score \(score) out of 10")
    }
}

struct RankBadge: View {
    let rank: Int
    var body: some View {
        Text("#\(rank)")
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.white, in: Capsule())
    }
}

extension Date {
    var shortDay: String { formatted(.dateTime.month(.abbreviated).day().year()) }
}
