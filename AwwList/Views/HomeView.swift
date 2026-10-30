import SwiftUI
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Combine

enum ListScope: Hashable { case all, year(Int) }

struct HomeView: View {
    @EnvironmentObject var library: Library
    @AppStorage("faceConsent") private var faceConsent = false
    @Environment(\.displayScale) private var displayScale
    @State private var scope: ListScope = .all
    @State private var age: AgeGroup?
    @State private var shot: ShotKind?
    @State private var person: UUID?
    @State private var showWho = false
    @State private var viewer: ViewerState?
    @State private var showSettings = false
    @State private var showSearch = false
    /// How many of the ranked photos are showing: the top 30, then 30 more each time "See more" is tapped.
    @State private var shown = 30
    /// Picking photos to send: hold any photo to start, then tap more. Best-photo ids, in the order picked.
    @State private var selecting = false
    @State private var picked: [String] = []
    @State private var preparing = false
    @State private var favoriting = false
    @State private var progress = (done: 0, of: 0)
    @State private var sendTask: Task<Void, Never>?
    @State private var sharing: SharePayload?
    @State private var note: (id: UUID, text: String)?
    /// Most photos you can pick at once (each is a full-size photo in memory while it's copied or shared).
    private let maxPick = 20

    struct SharePayload: Identifiable {
        let id = UUID()
        let files: [URL]
    }

    /// The filtered list, worked out only when the moments or a filter change (not on every redraw: the screen
    /// redraws often while scanning, and filtering thousands of moments each time made it feel sluggish).
    @State private var pool: [Moment] = []
    private var top: [Moment] { Array(pool.prefix(shown)) }

    private func refreshLists(_ moments: [Moment]? = nil) {
        let filtered = (moments ?? library.moments).filter { m in
            if case .year(let y) = scope, m.year != y { return false }
            if let age, !m.ages.contains(age) { return false }
            if let shot, m.shot != shot { return false }
            if let person, !m.people.contains(person) { return false }
            return true
        }
        pool = filtered
        prefetchImages()
    }

    /// Gets the next photos ready before they scroll into view: the small tiles showing now and the next 30.
    private func prefetchImages() {
        let ids = Array(pool.prefix(shown + 30).dropFirst(5)).map(\.best.id)
        AssetImage.prefetch(ids, side: 180 * displayScale)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ScanBannerSlot()
                    LimitedAccessBanner()
                    ClaudeKeyNote()
                    scopeBar
                    filterBar
                    if age == .toddler && library.birthdays.isEmpty && !library.people.contains(where: { $0.birthday != nil }) {
                        ContentUnavailableView {
                            Label("Add your kids' birthdays", systemImage: "birthday.cake")
                        } description: {
                            Text("Photos can tell a baby from an older child, but not a toddler from a kid. With birthdays, each photo is sorted by how old your kids were that day.")
                        } actions: {
                            Button("Add birthdays") { showSettings = true }.buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 24)
                    } else if rankChoice == "claude" && library.claudeScored == 0 {
                        rankMenu
                        ClaudeNotRunView(openSettings: { showSettings = true }).padding(.top, 24)
                    } else if pool.isEmpty {
                        rankMenu
                        EmptyListView(filtersOn: age != nil || shot != nil || person != nil,
                                      clear: { age = nil; shot = nil; person = nil }).padding(.top, 40)
                    } else {
                        topSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(selecting ? "\(picked.count) picked" : "Awwbum")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
            .overlay(alignment: .bottom) { UndoRemoveBar().padding(.bottom, selecting ? 90 : 24) }
            .overlay(alignment: .bottom) {
                if let note {
                    Text(note.text).font(.subheadline.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.black.opacity(0.85), in: Capsule())
                        .padding(.bottom, selecting ? 90 : 24)
                        .transition(.opacity)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .sheet(item: $sharing) { p in ShareSheet(items: p.files).presentationDetents([.medium, .large]) }
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { sendTask?.cancel(); endSelecting() }
                    }
                } else {
                    // Small logo and the name, top left (an empty center keeps the title from showing twice).
                    ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(spacing: 8) {
                            Image("BrandMark").resizable().scaledToFit().frame(width: 30, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            Text("awwbum").font(Theme.display(26, relativeTo: .title2)).foregroundStyle(Theme.accent)
                        }
                        .fixedSize()
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)   // stays inside the bar at large text sizes
                        .accessibilityElement(children: .ignore).accessibilityLabel("Awwbum").accessibilityAddTraits(.isHeader)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showWho = true } label: { Image(systemName: "person.2.crop.square.stack") }
                        .accessibilityLabel("Who's Who")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showWho) { WhoView() }
            .sheet(isPresented: $showSearch) { SearchView() }
            .fullScreenCover(item: $viewer) { v in ViewerView(moments: v.list, index: v.index) }
            .onChange(of: scope) { shown = 30; if !preparing { endSelecting() } }
            .onChange(of: age) { shown = 30; if !preparing { endSelecting() } }
            .onChange(of: shot) { shown = 30; if !preparing { endSelecting() } }
            .onChange(of: person) { shown = 30; if !preparing { endSelecting() } }
            .onChange(of: scope) { refreshLists() }
            .onChange(of: age) { refreshLists() }
            .onChange(of: shot) { refreshLists() }
            .onChange(of: person) { refreshLists() }
            // Coalesced: a burst of changes re-filters once.
            .onReceive(library.$moments.debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)) { refreshLists($0) }
            .onAppear { refreshLists() }
            .onChange(of: faceConsent) { if !faceConsent { person = nil } }
            .onChange(of: library.people) {
                if let p = person, !library.people.contains(where: { $0.id == p }) { person = nil }
            }
        }
    }

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Pill(title: "All", on: scope == .all) { scope = .all }
                ForEach(library.years, id: \.self) { y in
                    Pill(title: String(y), on: scope == .year(y)) { scope = .year(y) }
                }
            }
        }
    }

    /// Age, kind of shot and person, each a compact dropdown on one row (a chip turns purple when it's set).
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Age", selection: $age) {
                        Text("All ages").tag(AgeGroup?.none)
                        ForEach(AgeGroup.allCases) { g in Text(g.label).tag(AgeGroup?.some(g)) }
                    }
                } label: { DropChip(title: age?.label ?? "All ages", on: age != nil) }
                // Solo, kids together, or family and groups (grown-ups in the shot, or three or more faces).
                Menu {
                    Picker("Shots", selection: $shot) {
                        Text("All shots").tag(ShotKind?.none)
                        ForEach(ShotKind.allCases) { k in Text(k.label).tag(ShotKind?.some(k)) }
                    }
                } label: { DropChip(title: shot?.label ?? "All shots", on: shot != nil) }
                if library.people.isEmpty || !faceConsent {
                    Button { showWho = true } label: {
                        DropChip(title: library.people.isEmpty ? "Who's Who…" : "Turn on Who's Who…", on: false, chevron: false)
                    }.buttonStyle(.plain)
                } else {
                    Menu {
                        Picker("Who", selection: $person) {
                            Text("Everyone").tag(UUID?.none)
                            ForEach(library.people) { p in Text(p.name).tag(UUID?.some(p.id)) }
                        }
                        Divider()
                        Button("Who's Who…") { showWho = true }
                    } label: {
                        DropChip(title: person.flatMap { id in library.people.first { $0.id == id }?.name } ?? "Everyone",
                                 on: person != nil)
                    }
                }
            }
        }
    }

    /// Once Claude has scored photos: order the lists by Claude's score, the learned score, Apple's on-device score,
    /// or Consolidated (each year's top 100 from each, combined). Sits beside the count under the title.
    @ViewBuilder private var rankMenu: some View {
        if library.claudeScored > 0 || library.learned != nil || library.rankBy == "consolidated" || rankChoice == "claude" {
            Menu {
                Picker("Rank by", selection: Binding(get: { rankChoice }, set: { library.setRankBy($0) })) {
                    Text("Claude").tag("claude")
                    if library.learned != nil { Text("Learned").tag("learned") }
                    Text("Apple").tag("apple")
                    Text("Consolidated").tag("consolidated")
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Ranked by").foregroundStyle(.secondary)
                    Text(rankLabel).foregroundStyle(Theme.grapeInk)
                    Image(systemName: "chevron.down").font(.caption2.bold()).foregroundStyle(Theme.grapeInk)
                }
                .font(Theme.label(15))
            }
            .accessibilityLabel("Ranked by \(rankLabel)")
        }
    }
    private var rankChoice: String { library.rankBy == "learned" && library.learned == nil ? "apple" : library.rankBy }
    private var rankLabel: String {
        switch rankChoice { case "learned": "Learned"; case "apple": "Apple"; case "consolidated": "Consolidated"; default: "Claude" }
    }

    private var topSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(scopeTitle + " top 30").font(Theme.display(26)).lineLimit(1).minimumScaleFactor(0.7)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("\(pool.count.formatted()) moments").font(Theme.label(15)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    rankMenu
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(pool.count.formatted()) moments").font(Theme.label(15)).foregroundStyle(.secondary)
                    rankMenu
                }
            }
            // While picking, this row stays (blank) so the photos don't jump under your finger.
            Group {
                let n = min(maxPick, top.count)
                HStack(spacing: 8) {
                    Button { send(Array(top.prefix(maxPick)).map(\.best.id), copy: true) } label: {
                        Label("Copy top \(n)", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    Button { send(Array(top.prefix(maxPick)).map(\.best.id), copy: false) } label: {
                        Label("Share top \(n)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered).controlSize(.regular).tint(Theme.grapeInk).disabled(preparing || top.isEmpty || selecting)
                .overlay {
                    if preparing && !selecting {
                        Text("Getting \(progress.done) of \(progress.of)…").font(.subheadline.bold())
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .opacity(selecting ? 0 : 1)
                .accessibilityHidden(selecting)
                Text(selecting ? "Tap photos to pick up to \(maxPick)." : "Tip: hold any photo to pick several to send.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let first = top.first {
                Card(moment: first, rank: 1, height: 380, picked: pickState(first), onHold: { hold(first) }) { tap(top, 0) }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(top.dropFirst().prefix(4).enumerated()), id: \.element.id) { i, m in
                    Card(moment: m, rank: i + 2, height: 190, picked: pickState(m), onHold: { hold(m) }) { tap(top, i + 1) }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Array(top.dropFirst(5).enumerated()), id: \.element.id) { i, m in
                    Tile(moment: m, rank: i + 6, picked: pickState(m), onHold: { hold(m) }) { tap(top, i + 5) }
                }
            }
            if pool.count > shown {
                Button {
                    shown += 30
                    prefetchImages()
                } label: {
                    Label("See more", systemImage: "chevron.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large).tint(Theme.grapeInk)
                .accessibilityHint("Shows the next 30 photos, \(shown + 1) to \(min(pool.count, shown + 30)).")
                .padding(.top, 4)
            }
        }
    }

    private var scopeTitle: String {
        let who = person.flatMap { id in library.people.first { $0.id == id }?.name }
        if case .year(let y) = scope { return who.map { "\($0)'s \(y)" } ?? String(y) }
        return who.map { "\($0)'s" } ?? "Overall"
    }

    private func open(_ list: [Moment], _ i: Int) { viewer = ViewerState(list: list, index: i) }

    // MARK: Picking photos to send

    /// nil when not picking; otherwise whether this one is picked.
    private func pickState(_ m: Moment) -> Bool? { selecting ? picked.contains(m.best.id) : nil }

    private func tap(_ list: [Moment], _ i: Int) {
        if selecting { toggle(list[i]) } else { open(list, i) }
    }

    /// Holding a photo starts picking (with that photo picked), or toggles it if already picking.
    private func hold(_ m: Moment) {
        guard !preparing else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if selecting { toggle(m) } else { selecting = true; picked = [m.best.id] }
    }

    private func toggle(_ m: Moment) {
        guard !preparing else { return }
        if let i = picked.firstIndex(of: m.best.id) { picked.remove(at: i) }
        else if picked.count >= maxPick { flash("You can pick up to \(maxPick) photos at a time") }
        else { picked.append(m.best.id) }
    }

    private func endSelecting() { selecting = false; picked = []; preparing = false }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Button { favoritePicked() } label: {
                Image(systemName: "heart").frame(minWidth: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Favorite in Photos")
            Button { send(picked, copy: true) } label: {
                Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button { send(picked, copy: false) } label: {
                Label(preparing ? "Getting \(progress.done) of \(progress.of)…" : "Share \(picked.count)",
                      systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .disabled(picked.isEmpty || preparing || favoriting)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    /// Loads the photos (read only, never changed), turns them into JPEGs off the main thread, and either copies them
    /// for pasting into a text or opens the share sheet. Nothing is written to the photo library.
    private func send(_ ids: [String], copy: Bool) {
        let ids = Array(ids.prefix(maxPick))
        guard !ids.isEmpty, !preparing else { return }
        preparing = true
        progress = (0, ids.count)
        let wasPicking = selecting, session = picked
        sendTask = Task {
            var jpegs: [Data] = []
            for id in ids {
                if Task.isCancelled { break }
                if let img = await AssetImage.load(id: id, size: CGSize(width: 1600, height: 1600), mode: .aspectFit).image,
                   let data = await Task.detached(priority: .userInitiated, operation: { img.jpegData(compressionQuality: 0.85) }).value {
                    jpegs.append(data)
                }
                progress.done += 1
            }
            preparing = false
            guard !Task.isCancelled else { return }
            guard !jpegs.isEmpty else { flash("Couldn't load those photos"); return }
            let missing = ids.count - jpegs.count
            let n = jpegs.count
            let gap = missing > 0 ? " (\(missing) couldn't load)" : ""
            if copy {
                UIPasteboard.general.setItems(jpegs.map { [UTType.jpeg.identifier: $0] })
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                flash("Copied \(n) photo\(n == 1 ? "" : "s"). Paste into a text." + gap)
            } else {
                let files = await Task.detached(priority: .userInitiated) { Self.writeTemp(jpegs) }.value
                guard !files.isEmpty else { flash("Couldn't get those photos ready"); return }
                if missing > 0 { flash("Sharing \(n)" + gap) }
                sharing = SharePayload(files: files)
            }
            // End picking only if it's still the same pick (not a new one started meanwhile).
            if wasPicking && selecting && picked == session { endSelecting() }
        }
    }

    /// Writes the JPEGs to this app's own temporary folder (replacing the last batch) for the share sheet.
    nonisolated private static func writeTemp(_ jpegs: [Data]) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AwwShare", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return jpegs.enumerated().compactMap { i, d in
            let url = dir.appendingPathComponent("Aww \(i + 1).jpg")
            return (try? d.write(to: url)) != nil ? url : nil
        }
    }

    /// Favorites every picked photo in Photos too (the one change Awwbum can make to the library).
    private func favoritePicked() {
        let ids = picked
        guard !ids.isEmpty, !preparing, !favoriting else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        favoriting = true
        Task {
            let changed = await Favorites.set(ids, favorite: true)
            favoriting = false
            switch changed {
            case nil: flash("Photos didn't allow that. Check photo access in Settings.")
            case 0: flash("Those photos aren't in your library any more.")
            case let n?: flash("Favorited \(n) in Photos" + (n < ids.count ? " (\(ids.count - n) not found)" : ""))
            }
            if (changed ?? 0) > 0 && selecting && picked == ids { endSelecting() }
        }
    }

    private func flash(_ text: String) {
        let id = UUID()
        withAnimation { note = (id, text) }
        AccessibilityNotification.Announcement(text).post()
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { if note?.id == id { note = nil } }
        }
    }
}

struct ViewerState: Identifiable {
    let id = UUID()
    let list: [Moment]
    let index: Int
}

struct Pill: View {
    let title: String
    let on: Bool
    var small = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.label(small ? 15 : 17))
                .padding(.horizontal, small ? 12 : 16).frame(minHeight: 44)
                .background(on ? Theme.accent : Theme.surface, in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct Card: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let moment: Moment
    let rank: Int
    let height: CGFloat
    var picked: Bool? = nil
    var onHold: () -> Void = {}
    let action: () -> Void
    @State private var pressing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AssetImage(id: moment.best.id, targetSide: height * 1.4)
                .frame(height: height).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay { PickMark(picked: picked, cornerRadius: 16) }
                .overlay(alignment: .topLeading) { RankBadge(rank: rank).padding(8) }
                .overlay(alignment: .topTrailing) { ScoreBadge(score: moment.score).padding(8) }
            Text(moment.caption).font(Theme.label(16)).lineLimit(2, reservesSpace: true)
            Text(moment.best.date.shortDay).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .scaleEffect(pressing && !reduceMotion ? 0.97 : 1)
        .animation(.easeOut(duration: 0.15), value: pressing)
        .onTapGesture(perform: action)
        .onLongPressGesture(minimumDuration: 0.4, perform: onHold, onPressingChanged: { pressing = $0 })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked == true ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
        .accessibilityAction(named: picked == nil ? "Pick photos to send" : "Pick or unpick", onHold)
    }
}

/// While picking photos: a dimmed check when picked, an empty circle when not.
struct PickMark: View {
    let picked: Bool?
    var cornerRadius: CGFloat = 10
    var body: some View {
        if let picked {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(picked ? Color.black.opacity(0.3) : Color.clear)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(picked ? Theme.accent : Color.clear, lineWidth: 3)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title2.bold())
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, picked ? Theme.accent : Color.black.opacity(0.25))
                    .shadow(radius: 2)
                    .padding(6)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct Tile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let moment: Moment
    let rank: Int?
    var picked: Bool? = nil
    var onHold: () -> Void = {}
    let action: () -> Void
    @State private var pressing = false
    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay(AssetImage(id: moment.best.id, targetSide: 180))   // tiles are about 120 points wide
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) { if let rank { RankBadge(rank: rank).scaleEffect(0.8).padding(2) } }
            .overlay(alignment: .bottomTrailing) { if picked == nil { ScoreBadge(score: moment.score).scaleEffect(0.85).padding(3) } }
            .overlay { PickMark(picked: picked) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(pressing && !reduceMotion ? 0.95 : 1)
            .animation(.easeOut(duration: 0.15), value: pressing)
            .onTapGesture(perform: action)
            .onLongPressGesture(minimumDuration: 0.4, perform: onHold, onPressingChanged: { pressing = $0 })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((rank.map { "Number \($0), " } ?? "") + "score \(moment.score), \(moment.caption), \(moment.best.date.shortDay)")
            .accessibilityAddTraits(picked == true ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
            .accessibilityAction(named: picked == nil ? "Pick photos to send" : "Pick or unpick", onHold)
    }
}

struct ScanBanner: View {
    @EnvironmentObject var scanner: PhotoScanner
    @State private var asked = BackgroundScan.autoContinue
    @State private var failed: String?
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One slim line; tap for the details.
            Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Text("Checking photos… \(scanner.done.formatted()) of \(scanner.total.formatted())")
                        .font(.footnote.bold()).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "info.circle").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the details" : "Shows the details")
            ProgressView(value: Double(scanner.done), total: Double(max(1, scanner.total))).controlSize(.mini)
            if expanded {
            Text("If you leave, it keeps going in the background (iOS shows its progress), and otherwise picks up overnight while your phone charges, or when you come back.")
                .font(.caption).foregroundStyle(.secondary)
            if BackgroundScan.canContinueInBackground {
                Button(asked ? "It'll keep going after you leave" : "Keep scanning in the background") {
                    asked = BackgroundScan.continueInBackground(userTapped: true)
                    if !asked { failed = BackgroundScan.lastError }
                }
                .buttonStyle(.bordered).font(.subheadline).disabled(asked)
                if let failed { Text(failed).font(.caption).foregroundStyle(.secondary) }
            }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Shown on Home when Claude turned down the API key, so a failed automatic scoring doesn't go unnoticed.
struct ClaudeKeyNote: View {
    @EnvironmentObject var claude: ClaudeService
    var body: some View {
        if claude.lastOutcome == .keyRejected {
            Label("Claude couldn't use your API key, so nothing was sent. Check it in Settings.", systemImage: "key.fill")
                .font(.subheadline).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// The scan progress banner, on its own so scan progress redraws only the banner, not the whole list.
struct ScanBannerSlot: View {
    @EnvironmentObject var scanner: PhotoScanner
    var body: some View {
        if scanner.isScanning && scanner.total > 0 { ScanBanner() }
    }
}

struct EmptyListView: View {
    @EnvironmentObject var scanner: PhotoScanner
    var filtersOn = false
    var clear: () -> Void = {}
    var body: some View {
        if filtersOn {
            ContentUnavailableView {
                Label("No matches", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No moments match these filters.")
            } actions: {
                Button("Clear filters", action: clear).buttonStyle(.borderedProminent)
            }
        } else if scanner.isScanning {
            ContentUnavailableView("Finding your awws", systemImage: "heart.circle",
                                   description: Text("Still looking through your photos. The good ones show up here as they're found."))
        } else {
            ContentUnavailableView("No awws here yet", systemImage: "heart.circle",
                                   description: Text(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
                                                     ? "No photos of kids were found in the photos you picked. Tap Add photos above to include more."
                                                     : "No photos of kids were found here yet."))
        }
    }
}

/// A compact filter chip that opens a menu (purple when a filter is set).
struct DropChip: View {
    let title: String
    let on: Bool
    var chevron = true
    var body: some View {
        HStack(spacing: 5) {
            Text(title).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(.caption2.bold()) }
        }
        .font(Theme.label(15))
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(on ? Theme.accent : Theme.surface, in: Capsule())
        .foregroundStyle(on ? Color.white : Color.primary)
        .contentShape(Capsule())
    }
}

/// Ranking by Claude before Claude has scored anything: say so plainly instead of showing a list ranked by
/// something else.
struct ClaudeNotRunView: View {
    @EnvironmentObject var library: Library
    let openSettings: () -> Void
    var body: some View {
        let pending = library.claudeBatches.reduce(0) { $0 + $1.photos.count }
        ContentUnavailableView {
            Label(pending > 0 ? "Claude is scoring your photos" : "Claude hasn't scored any photos yet",
                  systemImage: "sparkles")
        } description: {
            Text(pending > 0
                 ? "\(pending.formatted()) photos are with Claude. Scores usually come back within an hour and show up here. Meanwhile, rank by \(library.learned != nil ? "Learned or Apple" : "Apple") from the menu above."
                 : "Score your photos with Claude in Settings, or rank by \(library.learned != nil ? "Learned or Apple" : "Apple") from the menu above.")
        } actions: {
            if pending == 0 { Button("Score with Claude") { openSettings() }.buttonStyle(.borderedProminent) }
        }
    }
}

/// "Removed from list · Undo", for a few seconds after a photo is removed in the viewer.
struct UndoRemoveBar: View {
    @EnvironmentObject var library: Library
    var body: some View {
        if !library.lastHidden.isEmpty {
            HStack(spacing: 12) {
                Text("Removed from list").font(.subheadline.bold()).foregroundStyle(.white)
                Button("Undo") { library.unhide(library.lastHidden) }
                    .font(.subheadline.bold()).foregroundStyle(Theme.sunny)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.black.opacity(0.85), in: Capsule())
            .transition(.opacity)
            .task(id: library.lastHidden) {
                try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 15 : 6))
                if !Task.isCancelled { library.forgetLastHidden() }
            }
        }
    }
}

/// With Limited photo access: say so, and let the user add photos (Apple's own picker; nothing is changed).
struct LimitedAccessBanner: View {
    @Environment(\.scenePhase) private var phase   // read in body: re-checked whenever the app comes back
    var body: some View {
        let _ = phase
        Group {
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled").foregroundStyle(Theme.grapeInk)
                    Text("Awwbum can only see the photos you picked.").font(.footnote)
                    Spacer(minLength: 4)
                    Button("Add photos") { Self.showPicker() }.font(.footnote.bold()).tint(Theme.grapeInk)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    static func showPicker() {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first
        else { return }
        var top = root
        while let next = top.presentedViewController { top = next }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { _ in
            Task { @MainActor in Shared.scanner.start(library: Shared.library) }   // check the newly added photos
        }
    }
}
