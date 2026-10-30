import SwiftUI
import Photos

/// Full-screen photo viewer: swipe between moments, share, or hide a photo from the list.
struct ViewerView: View {
    let moments: [Moment]
    @State var index: Int
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var sharing: UIImage?
    @State private var preparingShare = false
    /// Whether Photos has this one as a favorite (nil while checking).
    @State private var favorite: Bool?
    @State private var favNote: String?
    @State private var favBusy = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { i, m in
                    AssetImage(id: m.best.id, contentMode: .fit, targetSide: 900, cached: false)
                        .accessibilityLabel("\(m.caption), score \(m.score) of 10, \(m.best.date.shortDay)")
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
            favorite = nil
            favNote = nil
            let id = moments[index].best.id
            favorite = await Task.detached { Favorites.isFavorite(id) }.value
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
                    Text("\(m.score)").font(Theme.display(38)).foregroundStyle(m.score >= 9 ? Theme.sunny : Color.white)
                    Text("/10").foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    // Always there (dimmed while checking), so the buttons beside it don't shift.
                    Button { if let favorite { toggleFavorite(m, to: !favorite) } } label: {
                        Image(systemName: favorite == true ? "heart.fill" : "heart").font(.title3)
                            .foregroundStyle(favorite == true ? Theme.sunny : Color.white).frame(width: 44, height: 44)
                            .opacity(favorite == nil ? 0.4 : 1)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .disabled(favorite == nil || favBusy)
                    .accessibilityLabel(favorite == true ? "Unfavorite in Photos" : "Favorite in Photos")
                    // The full-size copy is loaded only when Share is tapped (not for every photo swiped past).
                    Button { share(m) } label: {
                        Group {
                            if preparingShare { ProgressView().tint(.white) }
                            else { Image(systemName: "square.and.arrow.up").font(.title3).foregroundStyle(.white) }
                        }
                        .frame(width: 44, height: 44)
                    }
                    .disabled(preparingShare)
                    .accessibilityLabel("Share")
                    Menu {
                        // Can be undone from Home right after, so it isn't shown as destructive.
                        Button { library.hide(m); dismiss() } label: { Label("Remove from list", systemImage: "eye.slash") }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.white).frame(width: 44, height: 44)
                    }
                }
                if let favNote { Text(favNote).font(Theme.label(14)).foregroundStyle(Theme.sunny) }
                Text(m.caption).font(Theme.label(18, relativeTo: .headline)).foregroundStyle(.white)
                Text(bothScores(m)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                Text(m.best.date.shortDay + (m.shots > 1 ? " · +\(m.shots - 1) similar" : "")).font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            .padding(16)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func share(_ m: Moment) {
        preparingShare = true
        Task {
            let r = await AssetImage.load(id: m.best.id, size: CGSize(width: 2048, height: 2048), mode: .aspectFit)
            preparingShare = false
            if let img = r.image, !r.degraded { sharing = img }     // never share a blurry stand-in
            else {
                favNote = "Couldn't load this photo (it may still be downloading from iCloud)."
                AccessibilityNotification.Announcement(favNote ?? "").post()
            }
        }
    }

    /// Hearts (or un-hearts) the photo in Photos too. If Photos says no, the heart goes back and says why.
    private func toggleFavorite(_ m: Moment, to on: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        favorite = on
        favBusy = true
        Task {
            let changed = await Favorites.set([m.best.id], favorite: on)
            favBusy = false
            guard moments.indices.contains(index), moments[index].id == m.id else { return }
            if changed == nil || changed == 0 {
                favorite = !on
                favNote = changed == nil ? "Photos didn't allow that. Check Awwbum's photo access in Settings."
                                         : "This photo isn't in your library any more."
                AccessibilityNotification.Announcement(favNote ?? "").post()
            } else {
                favNote = nil
            }
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

/// The system share sheet without "Save Image": Awwbum only reads the photo library, it never adds to it.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    init(image: UIImage) { items = [image] }
    /// Photo files (JPEGs in the app's own temporary folder).
    init(items: [URL]) { self.items = items }
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // No "Save Image" and no adding to an iCloud Shared Album (both would write to the photo library).
        vc.excludedActivityTypes = [.saveToCameraRoll, UIActivity.ActivityType("com.apple.mobileslideshow.StreamShareService")]
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
