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
    /// The current photo is zoomed in (swipe-down-to-close is off while panning).
    @State private var zoomed = false
    @State private var showSimilar = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { i, m in
                    ZoomablePhoto(id: m.best.id, zoomed: i == index ? $zoomed : .constant(false))
                        .accessibilityLabel("\(m.caption), score \(m.score) of 10, \(m.best.date.shortDay)")
                        .tag(i)
                        .background(Color.black)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(zoomed)   // panning a zoomed photo doesn't flip to the next one
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
        .overlay(alignment: .bottom) { if !zoomed { caption } }
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
            if !zoomed && v.translation.height > 120 && abs(v.translation.width) < 60 { dismiss() }
        }, including: zoomed ? .subviews : .all)
        .onChange(of: index) { zoomed = false }
        .sheet(isPresented: $showSimilar) {
            if moments.indices.contains(index) {
                NavigationStack {
                    PhotoGroupView(title: "Similar shots", ids: moments[index].similar)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSimilar = false } } }
                }
            }
        }
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
            // The moment as it stands now (a thumbs up or down changes its score while you're looking at it).
            let m = library.everyMoment.first { $0.id == moments[index].id }.map { now in
                var n = now; n.similar = moments[index].similar; return n
            } ?? moments[index]
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(m.score)").font(Theme.display(38)).foregroundStyle(m.score >= 9 ? Theme.sunny : Color.white)
                    Text("/10").foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    // Your own vote: teaches the app your taste (up lifts this moment, down sinks it).
                    let r = library.reaction(m)
                    Button { react(m, r == 1 ? 0 : 1) } label: {
                        Image(systemName: r == 1 ? "hand.thumbsup.fill" : "hand.thumbsup").font(.title3)
                            .foregroundStyle(r == 1 ? Theme.sunny : Color.white).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Thumbs up")
                    .accessibilityAddTraits(r == 1 ? .isSelected : [])
                    Button { react(m, r == -1 ? 0 : -1) } label: {
                        Image(systemName: r == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown").font(.title3)
                            .foregroundStyle(Color.white).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Thumbs down")
                    .accessibilityAddTraits(r == -1 ? .isSelected : [])
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
                HStack(spacing: 8) {
                    Text(m.best.date.shortDay + (m.shots > 1 ? " · +\(m.shots - 1) in the burst" : "")).font(.caption).foregroundStyle(.white.opacity(0.75))
                    if !m.similar.isEmpty {
                        Button("See \(m.similar.count) similar") { showSimilar = true }
                            .font(.caption.bold()).foregroundStyle(Theme.sunny)
                    }
                }
            }
            .padding(16)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func react(_ m: Moment, _ value: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        library.setReaction(m, value)
        favNote = value == 1 ? "Thumbs up: this one moves up, and it counts toward what the app learns."
            : value == -1 ? "Thumbs down: this one drops to the bottom, and it counts toward what the app learns." : nil
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

/// One photo in the viewer: pinch to zoom (up to 4×), drag to pan while zoomed, double-tap to zoom in or out.
struct ZoomablePhoto: View {
    let id: String
    @Binding var zoomed: Bool
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            AssetImage(id: id, contentMode: .fit, targetSide: 1600, cached: false)   // sharp enough to zoom into
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(MagnifyGesture()
                    .onChanged { v in
                        scale = min(4, max(1, lastScale * v.magnification))
                        if scale > 1 { zoomed = true }   // no swipe-to-close mid-pinch
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1.01 { reset() } else { zoomed = true; clamp(geo.size) }
                    })
                .simultaneousGesture(scale > 1 ? DragGesture(coordinateSpace: .global)
                    .onChanged { v in
                        offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                    }
                    .onEnded { _ in clamp(geo.size) } : nil)
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if scale > 1 { reset() } else { scale = 2.5; lastScale = 2.5; zoomed = true }
                    }
                }
        }
        .onDisappear { reset() }
        .accessibilityAction(named: "Zoom in") { scale = 2.5; lastScale = 2.5; zoomed = true }
        .accessibilityAction(named: "Zoom out") { reset() }
    }

    private func reset() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero; zoomed = false
    }
    /// Keeps the photo from being dragged off screen.
    private func clamp(_ size: CGSize) {
        let maxX = size.width * (scale - 1) / 2, maxY = size.height * (scale - 1) / 2
        withAnimation(.easeOut(duration: 0.15)) {
            offset = CGSize(width: min(maxX, max(-maxX, offset.width)), height: min(maxY, max(-maxY, offset.height)))
        }
        lastOffset = offset
    }
}
