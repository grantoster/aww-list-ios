import SwiftUI

import UIKit

/// The Awwbum look: grape purple, sunny yellow and night ink, set in Baloo 2 (bundled; SIL Open Font License).
enum Theme {
    /// Awwbum is grape purple; AwwSnap (the hidden second app) is light red. Read when the screens are built, so
    /// switching apps (which rebuilds them) changes the colors everywhere.
    private static var snap: Bool { AppMode.current == .snap }
    /// Buttons, links and tinted text: a little darker than the brand color in light mode, so text in it reads
    /// easily on the page (over 5:1), with white text on filled buttons over 5.5:1. Text and icons in dark mode use
    /// grapeInk.
    static var accent: Color { snap ? snapAccent : awwAccent }
    // Dark mode keeps the brand color: white text on filled buttons needs it (a lighter one fails there).
    private static let awwAccent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x7B / 255, green: 0x5C / 255, blue: 0xF0 / 255, alpha: 1)
        : UIColor(red: 0x6A / 255, green: 0x48 / 255, blue: 0xE8 / 255, alpha: 1) })
    private static let snapAccent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xD6 / 255, green: 0x33 / 255, blue: 0x4A / 255, alpha: 1)
        : UIColor(red: 0xC4 / 255, green: 0x2A / 255, blue: 0x40 / 255, alpha: 1) })
    static var grape: Color { snap ? snapRed : Color(red: 0x7B / 255, green: 0x5C / 255, blue: 0xF0 / 255) }
    static let snapRed = Color(red: 0xD6 / 255, green: 0x33 / 255, blue: 0x4A / 255)
    static let sunny = Color(red: 0xFF / 255, green: 0xD2 / 255, blue: 0x3F / 255)
    static let night = Color(red: 0x2A / 255, green: 0x23 / 255, blue: 0x50 / 255)
    /// Grape (or red) for text and icons (darker in light mode, lighter in dark mode) so it's easy to read; the
    /// plain accent stays for filled buttons with white text.
    static var grapeInk: Color { snap ? snapInk : awwInk }
    private static let awwInk = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xA0 / 255, green: 0x8C / 255, blue: 0xFF / 255, alpha: 1)
        : UIColor(red: 0x5B / 255, green: 0x3F / 255, blue: 0xD9 / 255, alpha: 1) })
    private static let snapInk = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xFF / 255, green: 0x8F / 255, blue: 0x9A / 255, alpha: 1)
        : UIColor(red: 0xB8 / 255, green: 0x24 / 255, blue: 0x3A / 255, alpha: 1) })
    /// Top scores: sunny yellow (with night text on it).
    static let gold = sunny
    /// Page background: soft lilac (or blush) mist in light mode, deep night in dark mode.
    static var background: Color { snap ? snapBackground : awwBackground }
    private static let awwBackground = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x15 / 255, green: 0x11 / 255, blue: 0x2B / 255, alpha: 1)
        : UIColor(red: 0xF3 / 255, green: 0xF0 / 255, blue: 0xFF / 255, alpha: 1) })
    private static let snapBackground = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x22 / 255, green: 0x12 / 255, blue: 0x16 / 255, alpha: 1)
        : UIColor(red: 0xFF / 255, green: 0xF0 / 255, blue: 0xF1 / 255, alpha: 1) })
    /// Cards and chips sitting on the background.
    static var surface: Color { snap ? snapSurface : awwSurface }
    private static let awwSurface = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x24 / 255, green: 0x1E / 255, blue: 0x45 / 255, alpha: 1) : .white })
    private static let snapSurface = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x36 / 255, green: 0x1D / 255, blue: 0x23 / 255, alpha: 1) : .white })

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

extension Theme {
    /// The app's logo: Awwbum's mark, or for AwwSnap the same mark with its purple turned red (yellow stays).
    static var logo: UIImage? { AppMode.current == .snap ? snapLogo : UIImage(named: "BrandMark") }
    static var logoImage: Image { logo.map { Image(uiImage: $0) } ?? Image("BrandMark") }

    private static let snapLogo: UIImage? = {
        guard let base = UIImage(named: "BrandMark"), let cg = base.cgImage else { return nil }
        let w = cg.width, h = cg.height, bpr = w * 4
        var px = [UInt8](repeating: 0, count: h * bpr)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]); guard a > 0 else { continue }
            let r = Double(px[i]) / a, g = Double(px[i + 1]) / a, b = Double(px[i + 2]) / a
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            guard d > 0.08 else { continue }                       // greys and whites stay
            var hue: Double
            if mx == r { hue = 60 * (((g - b) / d).truncatingRemainder(dividingBy: 6)) }
            else if mx == g { hue = 60 * ((b - r) / d + 2) } else { hue = 60 * ((r - g) / d + 4) }
            if hue < 0 { hue += 360 }
            guard hue >= 215 && hue <= 310 else { continue }       // only the purples
            // Same brightness and saturation, at AwwSnap red's hue (about 352°).
            let s = d / mx, v = mx, nh = 352.0
            let c = v * s, x = c * (1 - abs((nh / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
            let (r1, g1, b1) = (c, 0.0, x)                          // hue between 300° and 360°
            _ = x
            px[i] = UInt8(min(255, (r1 + m) * a)); px[i + 1] = UInt8(min(255, (g1 + m) * a)); px[i + 2] = UInt8(min(255, (b1 + m) * a))
        }
        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out, scale: base.scale, orientation: base.imageOrientation)
    }()
}
