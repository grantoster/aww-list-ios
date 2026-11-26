import SwiftUI
import Photos

enum ScanEstimate {
    /// Rough seconds per photo for the first scan, before there's a real speed to go on. These are estimates only
    /// (the scan runs several photos at once); the banner replaces them with the measured speed after a minute.
    static let fastest = 0.15
    static let slowest = 0.30

    /// "5 minutes", "about 1 hour 20 minutes": rounded so it doesn't pretend to be exact.
    static func describe(seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return minutes == 1 ? "a minute" : "\(minutes) minutes" }
        let rounded = Int((Double(minutes) / 5).rounded()) * 5
        let h = rounded / 60, m = rounded % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours"
        return m == 0 ? hours : "\(hours) \(m) minutes"
    }

    /// For example "5 to 10 minutes" or "1 to 2 hours".
    static func range(photos: Int) -> String {
        let lo = Double(photos) * fastest, hi = Double(photos) * slowest
        if hi < 90 { return "about a minute" }
        if hi < 3_600 {
            let a = max(1, Int((lo / 60).rounded())), b = max(a + 1, Int((hi / 60).rounded()))
            return "\(a) to \(b) minutes"
        }
        let a = max(1, Int((lo / 3_600).rounded())), b = Int((hi / 3_600).rounded())
        return b <= a ? (a == 1 ? "about an hour" : "about \(a) hours") : "\(a) to \(b) hours"
    }
}

/// Shown once, after photo access is allowed and before the first scan: how many photos there are and roughly how long the wait is.
struct ScanEstimateView: View {
    let onStart: () -> Void
    @State private var photoCount: Int?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Ready to check your photos").font(Theme.display(32, relativeTo: .largeTitle)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 10) {
                    if let n = photoCount {
                        Text(n.formatted()).font(Theme.display(44, relativeTo: .largeTitle)) + Text("  photos").font(Theme.label(17, relativeTo: .headline)).foregroundColor(.secondary)
                        Divider()
                        Text("Estimated first scan").font(.footnote).foregroundStyle(.secondary)
                        Text(ScanEstimate.range(photos: n)).font(Theme.display(28, relativeTo: .title)).foregroundStyle(Theme.accent)
                        Text("A guess: it depends on your iPhone and how many photos are in iCloud. After a minute or so it switches to your real speed. The first scan is the longest. After that, only new photos are checked.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ProgressView("Counting your photos…")
                    }
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 10) {
                    Label("Keep Awwbum open. It's fastest while it's on the screen, so the screen stays on during this first scan. Plugging in helps.", systemImage: "iphone")
                    Label("You can leave. It may pause, keeps what it has already checked, and carries on when you return.", systemImage: "pause.circle")
                    Label("Photos stored in iCloud take longer. They download first, so they are checked last.", systemImage: "icloud")
                }
                .font(.subheadline)
                Button(action: onStart) {
                    Text("Start checking").font(Theme.label(19, relativeTo: .headline)).frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(24)
        }
        .background(Theme.background.ignoresSafeArea())
        .task {
            // A quick count of the photos (not a scan; the Hidden album isn't included).
            let o = PHFetchOptions()
            o.includeHiddenAssets = false
            photoCount = PHAsset.fetchAssets(with: .image, options: o).count
        }
    }
}
