import SwiftUI

import UIKit

/// The Awwbum look: grape purple, sunny yellow and night ink, set in Baloo 2 (bundled; SIL Open Font License).
enum Theme {
    static let accent = Color("AccentColor")                       // grape #7B5CF0 (white text on it passes 4.5:1)
    static let grape = Color(red: 0x7B / 255, green: 0x5C / 255, blue: 0xF0 / 255)
    static let sunny = Color(red: 0xFF / 255, green: 0xD2 / 255, blue: 0x3F / 255)
    static let night = Color(red: 0x2A / 255, green: 0x23 / 255, blue: 0x50 / 255)
    /// Grape for text and icons (darker in light mode, lighter in dark mode) so it's easy to read; the plain
    /// accent stays for filled buttons with white text.
    static let grapeInk = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xA0 / 255, green: 0x8C / 255, blue: 0xFF / 255, alpha: 1)
        : UIColor(red: 0x5B / 255, green: 0x3F / 255, blue: 0xD9 / 255, alpha: 1) })
    /// Top scores: sunny yellow (with night text on it).
    static let gold = sunny
    /// Page background: soft lilac mist in light mode, deep night in dark mode.
    static let background = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x15 / 255, green: 0x11 / 255, blue: 0x2B / 255, alpha: 1)
        : UIColor(red: 0xF3 / 255, green: 0xF0 / 255, blue: 0xFF / 255, alpha: 1) })
    /// Cards and chips sitting on the background.
    static let surface = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x24 / 255, green: 0x1E / 255, blue: 0x45 / 255, alpha: 1) : .white })

    static let displayFont = "Baloo2-ExtraBold"
    static let bodyFont = "Baloo2-SemiBold"
    /// Whether the bundled fonts loaded (checked once; a unit test makes sure they do).
    static let hasBrandFonts = UIFont(name: displayFont, size: 12) != nil && UIFont(name: bodyFont, size: 12) != nil
    /// Headings and big numbers (scales with the reader's text size).
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        hasBrandFonts ? .custom(displayFont, size: size, relativeTo: style) : .system(size: size, weight: .heavy, design: .rounded)
    }
    /// Labels and chips.
    static func label(_ size: CGFloat, relativeTo style: Font.TextStyle = .subheadline) -> Font {
        hasBrandFonts ? .custom(bodyFont, size: size, relativeTo: style) : .system(size: size, weight: .bold, design: .rounded)
    }

    /// Navigation titles in Baloo 2 (call once at launch).
    static func styleNavigationBars() {
        let nav = UINavigationBar.appearance()
        if let big = UIFont(name: displayFont, size: 34) {
            nav.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: big)]
        }
        if let small = UIFont(name: displayFont, size: 19) {
            nav.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: small)]
        }
    }
}

/// Little score chip drawn on top of a photo.
struct ScoreBadge: View {
    let score: Int
    var body: some View {
        Text("\(score)")
            .font(Theme.label(14, relativeTo: .caption))
            .foregroundStyle(score >= 9 ? Theme.night : Color.white)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(score >= 9 ? Theme.sunny : Theme.night.opacity(0.75), in: Capsule())
            .accessibilityLabel("Score \(score) out of 10")
    }
}

struct RankBadge: View {
    let rank: Int
    var body: some View {
        Text("#\(rank)")
            .font(Theme.label(14, relativeTo: .caption))
            .foregroundStyle(Theme.night)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(.white, in: Capsule())
    }
}

extension Date {
    var shortDay: String { formatted(.dateTime.month(.abbreviated).day().year()) }
}
