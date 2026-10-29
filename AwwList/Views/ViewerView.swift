import SwiftUI
import Photos

/// Full-screen photo viewer: swipe between moments, share, or hide a photo from the list.
struct ViewerView: View {
    let moments: [Moment]
    @State var index: Int
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var shareImage: UIImage?
    @State private var sharing: UIImage?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { i, m in
                    AssetImage(id: m.best.id, contentMode: .fit, targetSide: 900)
                        .tag(i)
                        .background(Color.black)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            HStack {
                Text("\(index + 1) / \(moments.count)").foregroundStyle(.white.opacity(0.8)).font(.subheadline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title3.bold()).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("Close")
            }.padding(.horizontal, 16)
        }
        .overlay(alignment: .bottom) { caption }
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.height > 120 && abs(v.translation.width) < 60 { dismiss() }
        })
        .task(id: index) {
            shareImage = nil
            shareImage = await AssetImage.load(id: moments[index].best.id, size: CGSize(width: 2048, height: 2048), mode: .aspectFit)
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let sharing { ShareSheet(image: sharing).presentationDetents([.medium, .large]) }
        }
    }

    @ViewBuilder private var caption: some View {
        if moments.indices.contains(index) {
            let m = moments[index]
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(m.score)").font(Theme.display(34)).foregroundStyle(m.score >= 9 ? Theme.gold : Color.white)
                    Text("/10").foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    if let shareImage {
                        Button { sharing = shareImage } label: {
                            Image(systemName: "square.and.arrow.up").font(.title3).foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                    }
                    Menu {
                        Button(role: .destructive) { library.hide(m); dismiss() } label: { Label("Remove from list", systemImage: "eye.slash") }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.white).frame(width: 44, height: 44)
                    }
                }
                Text(m.caption).font(.headline).foregroundStyle(.white)
                Text(bothScores(m)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                Text(m.best.date.shortDay + (m.shots > 1 ? " · +\(m.shots - 1) similar" : "")).font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            .padding(16)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }
    }

    /// "Apple 7 · Claude 8.5" (or just Apple's when Claude hasn't seen it).
    private func bothScores(_ m: Moment) -> String {
        var s = m.apple > 0 ? "Apple \(m.apple)" : "Apple: set aside"
        func one(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        if let l = m.learnedScore { s += " · Learned " + one(l) }
        if let c = m.claudeScore { s += " · Claude " + one(c) }
        if let f = m.best.appleFlag, m.claudeScore == nil { s += " · Apple flagged: " + f.lowercased() }
        return s
    }
}

/// The system share sheet without "Save Image": Aww List only reads the photo library, it never adds to it.
struct ShareSheet: UIViewControllerRepresentable {
    let images: [UIImage]
    init(image: UIImage) { images = [image] }
    init(images: [UIImage]) { self.images = images }
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: images, applicationActivities: nil)
        // No "Save Image" and no adding to an iCloud Shared Album (both would write to the photo library).
        vc.excludedActivityTypes = [.saveToCameraRoll, UIActivity.ActivityType("com.apple.mobileslideshow.StreamShareService")]
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
