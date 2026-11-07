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
    /// Setting filter (a SceneKind id) and Place filter ("s:" + saved place id, or "t:" + town name).
    @State private var scene: String?
    @State private var place: String?
    @State private var sceneMenu: [(kind: SceneKind, count: Int)] = []
    @State private var placeMenu: [(id: String, name: String, count: Int, saved: Bool)] = []
    private let places = Shared.places
    @State private var askTowns = false
    @State private var showWho = false
    @State private var viewer: ViewerState?
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showLikes = false
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
    @State private var makingCollage = false
    @State private var collage: CollageImage?
    struct CollageImage: Identifiable { let id = UUID(); let image: UIImage }
    @State private var note: (id: UUID, text: String)?
    /// Most photos you can pick at once (each is a full-size photo in memory while it's copied or shared).
    private let maxPick = 20
    /// "Copy" and "Share" offer the top 20 or the top 40 (only the sizes the list has room for).
    private var shareSizes: [Int] { pool.count >= 30 ? [20, 40] : [20] }

    struct SharePayload: Identifiable {
        let id = UUID()
        let files: [URL]
    }

    /// The filtered list, worked out only when the moments or a filter change (not on every redraw: the screen
    /// redraws often while scanning, and filtering thousands of moments each time made it feel sluggish).
    @State private var pool: [Moment] = []
    /// The best moments from today's date in earlier years (shown at the top of the Overall list).
    @State private var onThisDay: [Moment] = []
    /// Fold lower-ranked look-alike shots from the same few minutes under the best one (Settings → Home list).
    @AppStorage(AppMode.current.key("groupSimilar")) private var groupSimilar = true
    /// Give each named child a fair share of the top spots (Settings → Home list).
    @AppStorage(AppMode.current.key("balanceKids")) private var balanceKids = false
    /// With someone picked: rank by how they look in each photo (true) or by the whole photo.
    @AppStorage(AppMode.current.key("personFocus")) private var personFocus = true
    private var top: [Moment] { Array(pool.prefix(shown)) }
    private var balancing: Bool { balanceKids && person == nil }
    private func inPlace(_ p: PhotoScore, _ choice: String) -> Bool {
        if choice.hasPrefix("s:") { return places.savedPlace(p).map { "s:" + $0.id.uuidString } == choice }
        if choice.hasPrefix("t:") { return places.town(p).map { "t:" + $0 } == choice }
        return true
    }
    /// The Place menu: your saved places, then towns by how many photos (3 or more), up to 20.
    private func placeChoices(_ ms: [Moment]) -> [(id: String, name: String, count: Int, saved: Bool)] {
        var saved: [UUID: Int] = [:], towns: [String: Int] = [:]
        for m in ms {
            if let s = places.savedPlace(m.best) { saved[s.id, default: 0] += 1 }
            if let t = places.town(m.best) { towns[t, default: 0] += 1 }
        }
        let a = places.saved.map { (id: "s:" + $0.id.uuidString, name: $0.name, count: saved[$0.id] ?? 0, saved: true) }
        let b = towns.filter { $0.value >= 3 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(20)
            .map { (id: "t:" + $0.key, name: $0.key, count: $0.value, saved: false) }
        return a + b
    }

    /// The Who menu: Daniel and Natalie first, then everyone else A to Z.
    private var peopleOrder: [Person] {
        let first = ["daniel", "natalie"]
        return library.people.sorted { a, b in
            let ia = first.firstIndex(of: a.name.lowercased()) ?? first.count, ib = first.firstIndex(of: b.name.lowercased()) ?? first.count
            return ia != ib ? ia < ib : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
    /// The Home list settings, watched together (one change handler keeps the body quick to type-check).
    private var listSettings: String { "\(groupSimilar)|\(balanceKids)|\(personFocus)|\(scene ?? "")|\(place ?? "")" }
    private var filtersOn: Bool { age != nil || shot != nil || person != nil || scene != nil || place != nil }
    private var sceneTitle: String { scene.flatMap { id in sceneMenu.first { $0.kind.id == id }?.kind.name } ?? "Any setting" }
    private var placeTitle: String { place.flatMap { id in placeMenu.first { $0.id == id }?.name } ?? "Anywhere" }

    /// The person the list is ranked around, if any (for the viewer's score and "Why it's here").
    private var focusPerson: Person? { personFocus ? person.flatMap { id in library.people.first { $0.id == id } } : nil }

    /// One person's photos ranked by how they look in each (see Library.personScore), with that as the score shown.
    /// Photos where their face isn't known yet count it as middling (see Library.personScore).
    static func focused(_ list: [Moment], on person: UUID, _ library: Library) -> [Moment] {
        let scored = list.enumerated().map { (n, m) -> (m: Moment, v: Double, n: Int) in
            var m = m
            let v = library.personScore(m, person)
            m.score = max(1, min(10, Int(v.rounded(.toNearestOrAwayFromZero))))
            // Ties settled by how the photo was taken (AwwSnap only; never changes the score shown).
            return (m, v + (library.mode == .snap ? 0.004 * Library.craft(m.best, main: library.face(of: person, in: m)) : 0), n)
        }
        return scored.sorted { $0.v != $1.v ? $0.v > $1.v : $0.n < $1.n }.map(\.m)
    }

    private func refreshLists(_ moments: [Moment]? = nil) {
        let all = moments ?? library.moments
        let kind = scene.flatMap { id in sceneMenu.first { $0.kind.id == id }?.kind ?? Surroundings.builtIn.first { $0.id == id } }
        let filtered = all.filter { m in
            if let kind, !Surroundings.matches(m.best, kind) { return false }
            if let place, !inPlace(m.best, place) { return false }
            if case .year(let y) = scope, m.year != y { return false }
            if let age, !m.ages.contains(age) { return false }
            if let shot, m.shot != shot { return false }
            if let person, !m.people.contains(person) { return false }
            return true
        }
        // Ranking one person: ranked first, so each group of look-alikes is headed by the shot where they look best.
        let ranked = person.map { p in personFocus ? Self.focused(filtered, on: p, library) : filtered } ?? filtered
        let folded = groupSimilar ? SimilarShots.fold(ranked) : ranked
        // Not when one person is picked: then every photo is theirs anyway.
        pool = balancing && person == nil ? KidBalance.order(folded, kids: KidBalance.kids(library.people)) : folded
        sceneMenu = Surroundings.menu(all)
        placeMenu = placeChoices(all)
        // A choice that's gone (a removed place, a learned kind that dropped off) stops filtering.
        if let s = scene, !sceneMenu.contains(where: { $0.kind.id == s }) { scene = nil }
        if let p = place, !placeMenu.contains(where: { $0.id == p }) { place = nil }
        // On this day: same month and day in earlier years, best first, from the same (filtered, folded) list.
        // Only shown on the Overall list. A Feb 29 photo shows on Feb 29 only.
        if case .all = scope {
            let cal = Calendar.current, today = cal.dateComponents([.year, .month, .day], from: Date())
            onThisDay = Array(folded.lazy.filter { m in   // best first, not balanced
                let c = cal.dateComponents([.year, .month, .day], from: m.best.date)
                return c.month == today.month && c.day == today.day && (c.year ?? 0) < (today.year ?? 0)
            }.prefix(12))
        } else { onThisDay = [] }
        prefetchImages()
    }

    /// Gets the next photos ready before they scroll into view: the small tiles showing now and the next 30.
    private func prefetchImages() {
        let ids = Array(pool.prefix(shown + 30).dropFirst(5)).map(\.best.id)
        AssetImage.prefetch(ids, side: 180 * displayScale)
    }

    @ToolbarContentBuilder private var homeToolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { sendTask?.cancel(); endSelecting() }
            }
        } else {
            // Small logo and the name, top left (an empty center keeps the title from showing twice).
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
            ToolbarItem(placement: .topBarLeading) { BrandSwitch() }
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

    /// The scope, age, kind of shot and person picked, as one value to watch.
    private var filterKey: String { "\(scope)|\(String(describing: age))|\(String(describing: shot))|\(person?.uuidString ?? "")" }

    private var content: some View {
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
                    Button("Add birthdays") { showSettings = true }.buttonStyle(.borderedProminent).tint(Theme.accent)
                }
                .padding(.top, 24)
            } else if rankChoice == "claude" && library.claudeScored == 0 {
                rankMenu
                ClaudeNotRunView(openSettings: { showSettings = true }).padding(.top, 24)
            } else if pool.isEmpty {
                rankMenu
                EmptyListView(filtersOn: filtersOn,
                              clear: { age = nil; shot = nil; person = nil; scene = nil; place = nil }).padding(.top, 40)
            } else {
                if scope == .all && !onThisDay.isEmpty { onThisDaySection }
                topSection
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(selecting ? "\(picked.count) picked" : AppMode.current.title)
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
            .toolbar { homeToolbar }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showWho) { WhoView() }
            .sheet(isPresented: $showSearch) { SearchView() }
            .fullScreenCover(item: $viewer) { v in ViewerView(moments: v.list, index: v.index, focus: focusPerson, total: v.total) }
            .sheet(item: $collage) { c in ShareSheet(image: c.image).presentationDetents([.medium, .large]) }
            .onChange(of: filterKey) { shown = 30; if !preparing { endSelecting() }; refreshLists() }
            .onChange(of: listSettings) { shown = 30; if !preparing { endSelecting() }; refreshLists() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in refreshLists() }
            // Coalesced: a burst of changes re-filters once.
            .onReceive(library.$moments.debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)) { refreshLists($0) }
            .onAppear { refreshLists(); places.nameTowns(library) }
            .onChange(of: faceConsent) { if !faceConsent { person = nil } }
            .onChange(of: library.people) {
                if let p = person, !library.people.contains(where: { $0.id == p }) { person = nil }
            }
        }
    }

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: true) {   // visible, so a mouse can drag it on a Mac
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
        ScrollView(.horizontal, showsIndicators: true) {   // visible, so a mouse can drag it on a Mac
            HStack(spacing: 8) {
                if AppMode.current == .aww {   // Baby, Toddler, Kid: Awwbum only
                    Menu {
                        Picker("Age", selection: $age) {
                            Text("All ages").tag(AgeGroup?.none)
                            ForEach(AgeGroup.allCases) { g in Text(g.label).tag(AgeGroup?.some(g)) }
                        }
                    } label: { DropChip(title: age?.label ?? "All ages", on: age != nil) }
                }
                // Solo, kids together, or family and groups (grown-ups in the shot, or three or more faces).
                Menu {
                    Picker("Shots", selection: $shot) {
                        Text("All shots").tag(ShotKind?.none)
                        ForEach(ShotKind.allCases) { k in Text(k.label).tag(ShotKind?.some(k)) }
                    }
                } label: { DropChip(title: shot?.label ?? "All shots", on: shot != nil) }
                // What kind of photo: outdoors, a party, sports... (learned from your photos too).
                if !sceneMenu.isEmpty || scene != nil {
                    Menu {
                        Picker("Setting", selection: $scene) {
                            Text("Any setting").tag(String?.none)
                            ForEach(sceneMenu, id: \.kind.id) { e in Text("\(e.kind.name) (\(e.count))").tag(String?.some(e.kind.id)) }
                        }
                    } label: { DropChip(title: sceneTitle, on: scene != nil) }
                }
                // Where: your saved places and the towns your photos are from.
                Menu {
                    Picker("Place", selection: $place) {
                        Text("Anywhere").tag(String?.none)
                        ForEach(placeMenu, id: \.id) { e in Text("\(e.name) (\(e.count))").tag(String?.some(e.id)) }
                    }
                    if !places.lookUpTowns {
                        Divider()
                        Button("Name towns from photo locations…") { askTowns = true }
                    }
                } label: { DropChip(title: placeTitle, on: place != nil) }
                .confirmationDialog("Name towns from photo locations?", isPresented: $askTowns, titleVisibility: .visible) {
                    Button("Name towns") { places.lookUpTowns = true }
                } message: {
                    Text("Apple's location service gets a rough location (to about half a mile) for each area your photos are from, never the photos, and names the town, like Gulf Shores, AL. You can turn this off in Settings → Places.")
                }
                if library.people.isEmpty || !faceConsent {
                    Button { showWho = true } label: {
                        DropChip(title: library.people.isEmpty ? "Who's Who…" : "Turn on Who's Who…", on: false, chevron: false)
                    }.buttonStyle(.plain)
                } else {
                    Menu {
                        Picker("Who", selection: $person) {
                            Text("Everyone").tag(UUID?.none)
                            ForEach(peopleOrder) { p in Text(p.name).tag(UUID?.some(p.id)) }
                        }
                        if let p = person, let name = library.people.first(where: { $0.id == p })?.name {
                            Divider()
                            Picker("Rank", selection: $personFocus) {
                                Text("Best of \(name)").tag(true)
                                Text("Best whole photo").tag(false)
                            }
                        }
                        Divider()
                        Button("Who's Who…") { showWho = true }
                    } label: {
                        DropChip(title: person.flatMap { id in library.people.first { $0.id == id }?.name }
                                    .map { personFocus ? "Best of \($0)" : $0 } ?? "Everyone",
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
                    if library.learned != nil { Text("Learned").tag("learned") }
                    Text("Claude").tag("claude")
                    Text("Apple").tag("apple")
                    Text("Consolidated").tag("consolidated")
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Ranked by").foregroundStyle(.secondary)
                    Text(rankLabel + (balancing ? " · balanced" : "")).foregroundStyle(Theme.grapeInk)
                    Image(systemName: "chevron.down").font(.caption2.bold()).foregroundStyle(Theme.grapeInk)
                }
                .font(Theme.label(15))
            }
            .accessibilityLabel("Ranked by \(rankLabel)" + (balancing ? ", kids balanced" : ""))
        }
    }
    private var rankChoice: String { library.rankBy == "learned" && library.learned == nil ? "apple" : library.rankBy }
    private var rankLabel: String {
        switch rankChoice { case "learned": "Learned"; case "apple": "Apple"; case "consolidated": "Consolidated"; default: "Claude" }
    }

    /// A row of the best photos from this date in past years. Tap one to see them all in the viewer.
    private var onThisDaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On this day").font(Theme.display(22)).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: true) {   // visible, so a mouse can drag it on a Mac
                HStack(spacing: 8) {
                    ForEach(Array(onThisDay.enumerated()), id: \.element.id) { i, m in
                        VStack(alignment: .leading, spacing: 4) {
                            Tile(moment: m, rank: nil, picked: pickState(m), onHold: { hold(m) }) { tap(onThisDay, i) }
                                .frame(width: 120, height: 120)
                            Text(yearsAgo(m)).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(yearsAgo(m))
                    }
                }
            }
            .scrollClipDisabled()
        }
        .padding(.bottom, 4)
    }
    private func yearsAgo(_ m: Moment) -> String {
        let n = Calendar.current.component(.year, from: Date()) - m.year
        return n == 1 ? "1 year ago" : "\(n) years ago"
    }

    private var topSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(scopeTitle + (focusPerson.map { ": best of \($0.name)" } ?? (pool.isEmpty ? "" : " top \(min(30, pool.count))"))).font(Theme.display(26)).lineLimit(1).minimumScaleFactor(0.7)
            // Learn my Likes, where you'll see it (it also lives in Settings).
            Button { showLikes = true } label: {
                Label(AppMode.current == .snap ? "Which is the better photo? Teach it your eye" : "Which is cuter? Teach it your taste",
                      systemImage: "rectangle.split.2x1")
                    .font(Theme.label(15)).foregroundStyle(Theme.grapeInk)
            }
            .frame(minHeight: 44, alignment: .leading)
            .fullScreenCover(isPresented: $showLikes) { LikesView() }
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
                // Top 20 or top 40 of the list as it's shown (look-alike shots folded), as photos to copy or share.
                HStack(spacing: 8) {
                    Menu {
                        ForEach(shareSizes, id: \.self) { k in
                            Button("Copy top \(min(k, bulkPool.count))") { send(Array(bulkPool.prefix(k)).map(\.best.id), copy: true, limit: k) }
                        }
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Copy top photos")
                    Menu {
                        ForEach(shareSizes, id: \.self) { k in
                            Button("Share top \(min(k, bulkPool.count))") { send(Array(bulkPool.prefix(k)).map(\.best.id), copy: false, limit: k) }
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Share top photos")
                }
                .buttonStyle(.bordered).controlSize(.regular).tint(Theme.grapeInk).disabled(preparing || top.isEmpty || selecting)
                .overlay {
                    if preparing && !selecting {
                        HStack(spacing: 12) {
                            Text("Getting \(progress.done) of \(progress.of)…").font(.subheadline.bold())
                            Button("Cancel") { sendTask?.cancel(); preparing = false }.font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .opacity(selecting ? 0 : 1)
                .accessibilityHidden(selecting)
                .overlay {   // in the same space, so nothing below moves
                    if selecting {
                        Text("Tap photos to pick up to \(maxPick).")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                Menu {
                    Button("Top 10 collage") { makeCollage(10) }
                    if bulkPool.count > 10 { Button("Top 20 collage") { makeCollage(20) } }
                } label: {
                    Label(makingCollage ? "Making the collage…" : "Share a collage", systemImage: "square.grid.2x2")
                        .font(.subheadline)
                }
                .disabled(makingCollage || top.isEmpty || selecting)
                .opacity(selecting ? 0 : 1)
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

    /// The list without possible bath or undressed photos, privacy holds and the photos around them: Copy, Share
    /// and collages take from this.
    /// Picking photos yourself, or sharing one from the viewer, is still up to you.
    private var bulkPool: [Moment] { let no = library.neverShare; return pool.filter { !$0.memberIDs.contains(where: no.contains) } }

    /// The current list's top 10 or top 20 (this year or overall, with your filters) as one picture to share. Made on the
    /// phone and handed to the share sheet; nothing is saved to Photos.
    private func makeCollage(_ count: Int) {
        let ids = Array(bulkPool.prefix(count)).map(\.best.id)
        let title = scopeTitle + " top \(ids.count)"
        makingCollage = true
        Task {
            var images: [UIImage] = [], ranks: [Int] = []
            for (n, id) in ids.enumerated() {
                if let img = await AssetImage.load(id: id, size: CGSize(width: 700, height: 700), mode: .aspectFill).image {
                    images.append(img); ranks.append(n + 1)   // keeps each photo's real rank if one can't load
                }
            }
            let imgs = images, nums = ranks
            let result = await Task.detached(priority: .userInitiated) { Collage.render(imgs, ranks: nums, title: title) }.value
            makingCollage = false
            if let result { collage = CollageImage(image: result) }
            else { note = (UUID(), "Couldn't load these photos (they may still be downloading from iCloud).") }
        }
    }

    private var scopeTitle: String {
        let who = person.flatMap { id in library.people.first { $0.id == id }?.name }
        if case .year(let y) = scope { return who.map { "\($0)'s \(y)" } ?? String(y) }
        return who.map { "\($0)'s" } ?? "Overall"
    }

    /// Opens the viewer. From the top list it gets the whole list, not just the photos shown so far, so you can keep
    /// swiping past the first 30.
    private func open(_ list: [Moment], _ i: Int) {
        let whole = list.count < pool.count && list.indices.contains(i) && pool.indices.contains(i) && pool[i].id == list[i].id
        // (Up to 500 photos, so the pages stay quick to set up.)
        viewer = ViewerState(list: whole ? Array(pool.prefix(max(500, i + 100))) : list, index: i, total: whole ? pool.count : nil)
    }

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
            .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .controlSize(.large)
        .disabled(picked.isEmpty || preparing || favoriting)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    /// Loads the photos (read only, never changed), turns them into JPEGs off the main thread, and either copies them
    /// for pasting into a text or opens the share sheet. Nothing is written to the photo library.
    private func send(_ ids: [String], copy: Bool, limit: Int? = nil) {
        let ids = Array(ids.prefix(limit ?? maxPick))
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
            case 0: flash("Those photos aren't in your library anymore.")
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
    /// How many photos the whole list has (the viewer gets at most 500 of them).
    var total: Int? = nil
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
                .overlay(alignment: .bottomLeading) { SimilarBadge(count: moment.similar.count).padding(8) }
        }
        .contentShape(Rectangle())
        .scaleEffect(pressing && !reduceMotion ? 0.97 : 1)
        .animation(.easeOut(duration: 0.15), value: pressing)
        .onTapGesture(perform: action)
        .onLongPressGesture(minimumDuration: 0.4, perform: onHold, onPressingChanged: { pressing = $0 })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Number \(rank), score \(moment.score), \(moment.caption), \(moment.best.date.shortDay)"
                            + (moment.similar.isEmpty ? "" : ", \(moment.similar.count) similar"))
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
            .overlay(alignment: .bottomLeading) { SimilarBadge(count: moment.similar.count).scaleEffect(0.85).padding(3) }
            .overlay { PickMark(picked: picked) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(pressing && !reduceMotion ? 0.95 : 1)
            .animation(.easeOut(duration: 0.15), value: pressing)
            .onTapGesture(perform: action)
            .onLongPressGesture(minimumDuration: 0.4, perform: onHold, onPressingChanged: { pressing = $0 })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((rank.map { "Number \($0), " } ?? "") + "score \(moment.score), \(moment.caption), \(moment.best.date.shortDay)"
                                + (moment.similar.isEmpty ? "" : ", \(moment.similar.count) similar"))
            .accessibilityAddTraits(picked == true ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
            .accessibilityAction(named: picked == nil ? "Pick photos to send" : "Pick or unpick", onHold)
    }
}

struct ScanBanner: View {
    @EnvironmentObject var scanner: PhotoScanner
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
            Text(BackgroundScan.canContinueInBackground
                 ? "Keeps going after you leave the app when iOS allows (it shows the progress), then Claude scoring if it's set to keep going. If iOS stops it, it picks up overnight while your phone charges, or when you come back."
                 : "If you leave, it picks up overnight while your phone charges, or when you come back.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = BackgroundScan.lastError { Text(e).font(.caption).foregroundStyle(.secondary) }
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
    @EnvironmentObject var claude: ClaudeService
    var body: some View {
        if scanner.isScanning && scanner.total > 0 { ScanBanner() }
        if claude.scoring && !claude.status.isEmpty { ClaudeBanner() }
    }
}

/// While Claude is scoring: one slim line with the progress, so it's clear it's working.
struct ClaudeBanner: View {
    @EnvironmentObject var claude: ClaudeService
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.footnote).foregroundStyle(Theme.accent).accessibilityHidden(true)
                Text(claude.status).font(.footnote.bold()).lineLimit(2)
                Spacer(minLength: 4)
                Button("Stop") {
                    UserDefaults.standard.set(false, forKey: AppMode.current.key("autoClaude"))
                    claude.stop()
                }
                .font(.footnote).buttonStyle(.bordered).controlSize(.mini)
            }
            if claude.toSend > 0 && claude.sent > 0 {
                ProgressView(value: Double(min(claude.sent, claude.toSend)), total: Double(claude.toSend)).controlSize(.mini)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
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
                Button("Clear filters", action: clear).buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        } else if scanner.isScanning {
            ContentUnavailableView(AppMode.current == .snap ? "Finding your best shots" : "Finding your awws", systemImage: "heart.circle",
                                   description: Text("Still looking through your photos. The good ones show up here as they're found."))
        } else {
            let who = AppMode.current == .snap ? "grown-ups" : "kids"
            ContentUnavailableView(AppMode.current == .snap ? "No photos here yet" : "No awws here yet", systemImage: "heart.circle",
                                   description: Text(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
                                                     ? "No photos of \(who) were found in the photos you picked. Tap Add photos above to include more."
                                                     : "No photos of \(who) were found here yet."))
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
            if pending == 0 { Button("Score with Claude") { openSettings() }.buttonStyle(.borderedProminent).tint(Theme.accent) }
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
                    Text("\(AppMode.current.title) can only see the photos you picked.").font(.footnote)
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
            Task { @MainActor in let lib = Shared.library(.current); lib.scanner.start(library: lib) }   // check the newly added photos
        }
    }
}

/// "+3" on a photo with look-alike shots folded under it.
struct SimilarBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text("+\(count)")
                .font(.caption2.bold()).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .accessibilityLabel("\(count) similar \(count == 1 ? "shot" : "shots")")
        }
    }
}

/// Folds look-alike moments: a lower-ranked moment taken within 5 minutes of a higher-ranked one, whose whole-photo
/// fingerprint is very close to it, is tucked under that one (shown as "+N", and in the viewer as "See N similar").
enum SimilarShots {
    static let window: TimeInterval = 300
    static let threshold: Float = 0.8

    static func scene(_ p: PhotoScore) -> [Float]? {
        guard let f = p.feat, f.count == Learner.featureCount else { return nil }
        let b = [UInt8](f), start = Learner.signalCount
        let v = (start..<(start + Learner.sceneDims)).map { Float(Int8(bitPattern: b[$0])) }
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : nil
    }

    /// Keeps the list's order; each moment is folded under the first (best-ranked) kept one it matches.
    /// `limit`: stop once that many are kept (the ones kept so far are exactly the same).
    static func fold(_ list: [Moment], limit: Int = .max) -> [Moment] {
        var kept: [Moment] = []
        var scenes: [[Float]?] = []
        var byBucket: [Int: [Int]] = [:]
        for m in list {
            if kept.count >= limit { break }
            let t = m.best.date.timeIntervalSince1970
            let b = Int((t / window).rounded(.down))
            let sc = scene(m.best)
            var host: Int?
            if let sc {
                for bb in (b - 1)...(b + 1) {
                    for k in byBucket[bb] ?? [] where abs(kept[k].best.date.timeIntervalSince1970 - t) <= window && k < (host ?? .max) {
                        guard let other = scenes[k] else { continue }
                        var dot: Float = 0
                        for i in 0..<min(sc.count, other.count) { dot += sc[i] * other[i] }
                        if dot >= threshold { host = k }   // the best-ranked match wins (kept is in rank order)
                    }
                }
            }
            if let host {
                kept[host].similar.append(m.best.id)
            } else {
                kept.append(m); scenes.append(sc)
                byBucket[b, default: []].append(kept.count - 1)
            }
        }
        return kept
    }
}

/// Draws a grid of photos with a title, as one image (2 columns; square, center-cropped tiles).
enum Collage {
    static func render(_ images: [UIImage], ranks: [Int] = [], title: String) -> UIImage? {
        guard !images.isEmpty else { return nil }
        // Up to 12 photos: 2 across; more (a top 20): 4 across, so it stays a shareable shape.
        let cols = images.count < 4 ? images.count : (images.count > 12 ? 4 : 2)
        let rows = Int((Double(images.count) / Double(cols)).rounded(.up))
        let tile: CGFloat = 540, gap: CGFloat = 12, margin: CGFloat = 36, header: CGFloat = 120, footer: CGFloat = 60
        let width = margin * 2 + CGFloat(cols) * tile + CGFloat(cols - 1) * gap
        let height = header + CGFloat(rows) * tile + CGFloat(rows - 1) * gap + footer + margin
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: fmt).image { ctx in
            UIColor(red: 0.99, green: 0.97, blue: 0.94, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let grape = UIColor(Theme.grape)
            let brand = { (size: CGFloat) in UIFont(name: Theme.displayFont, size: size) ?? UIFont.systemFont(ofSize: size, weight: .heavy) }
            // The app's logo and name, top right, as in the app's header.
            let logo = Theme.logo
            let mark: CGFloat = 76
            let word = AppMode.current.name as NSString
            let wordAttrs: [NSAttributedString.Key: Any] = [.font: brand(54), .foregroundColor: grape]
            let ws = word.size(withAttributes: wordAttrs)
            // On a narrow collage (one photo), just the logo up top, so the title has room.
            let showWord = width >= 900
            let brandWidth = mark + (showWord ? 12 + ws.width : 0)
            let bx = width - margin - brandWidth, by = (header - mark) / 2 - 4
            if let logo {
                ctx.cgContext.saveGState()
                UIBezierPath(roundedRect: CGRect(x: bx, y: by, width: mark, height: mark), cornerRadius: 18).addClip()
                logo.draw(in: CGRect(x: bx, y: by, width: mark, height: mark))
                ctx.cgContext.restoreGState()
            }
            if showWord { word.draw(at: CGPoint(x: bx + mark + 12, y: by + (mark - ws.height) / 2), withAttributes: wordAttrs) }
            // The title on the left, shrunk if it would run into the logo.
            var titleSize: CGFloat = 56
            var titleAttrs: [NSAttributedString.Key: Any] = [.font: brand(titleSize),
                                                              .foregroundColor: UIColor(red: 0.29, green: 0.16, blue: 0.40, alpha: 1)]
            while (title as NSString).size(withAttributes: titleAttrs).width > bx - margin - 24 && titleSize > 28 {
                titleSize -= 2; titleAttrs[.font] = brand(titleSize)
            }
            let ts = (title as NSString).size(withAttributes: titleAttrs)
            let room = bx - margin - 24
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            titleAttrs[.paragraphStyle] = style
            (title as NSString).draw(in: CGRect(x: margin, y: (header - ts.height) / 2 - 4, width: room, height: ts.height + 4),
                                     withAttributes: titleAttrs)
            for (i, img) in images.enumerated() {
                let r = CGRect(x: margin + CGFloat(i % cols) * (tile + gap),
                               y: header + CGFloat(i / cols) * (tile + gap), width: tile, height: tile)
                ctx.cgContext.saveGState()
                UIBezierPath(roundedRect: r, cornerRadius: 24).addClip()
                // Fill the square, cropping the longer side around the center.
                let k = max(tile / img.size.width, tile / img.size.height)
                let s = CGSize(width: img.size.width * k, height: img.size.height * k)
                img.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
                ctx.cgContext.restoreGState()
                let n = "\(i < ranks.count ? ranks[i] : i + 1)" as NSString
                let badge: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: UIColor.white]
                let bs = n.size(withAttributes: badge)
                let br = CGRect(x: r.minX + 14, y: r.minY + 14, width: max(bs.width + 24, 52), height: 52)
                UIColor(white: 0, alpha: 0.5).setFill()
                UIBezierPath(roundedRect: br, cornerRadius: 26).fill()
                n.draw(at: CGPoint(x: br.midX - bs.width / 2, y: br.midY - bs.height / 2), withAttributes: badge)
            }
            // "made with" and the logo and name again, bottom right.
            let small: CGFloat = 40
            let foot: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26, weight: .semibold),
                                                        .foregroundColor: UIColor(white: 0.45, alpha: 1)]
            let footWord: [NSAttributedString.Key: Any] = [.font: brand(32), .foregroundColor: grape]
            let made = "made with" as NSString, ms = made.size(withAttributes: foot), fw = word.size(withAttributes: footWord)
            let fy = height - margin - footer / 2 - small / 2 + 6
            var fx = width - margin - (ms.width + 10 + small + 8 + fw.width)
            made.draw(at: CGPoint(x: fx, y: fy + (small - ms.height) / 2), withAttributes: foot)
            fx += ms.width + 10
            if let logo {
                ctx.cgContext.saveGState()
                UIBezierPath(roundedRect: CGRect(x: fx, y: fy, width: small, height: small), cornerRadius: 10).addClip()
                logo.draw(in: CGRect(x: fx, y: fy, width: small, height: small))
                ctx.cgContext.restoreGState()
            }
            fx += small + 8
            word.draw(at: CGPoint(x: fx, y: fy + (small - fw.height) / 2), withAttributes: footWord)
        }
    }
}

/// The logo and name, top left. Tapping it offers the other app (the hidden AwwSnap, or back to Awwbum).
struct BrandSwitch: View {
    @State private var asking = false
    private let mode = AppMode.current
    var body: some View {
        Button { asking = true } label: {
            HStack(spacing: 8) {
                Theme.logoImage.resizable().scaledToFit().frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Text(mode.name).font(Theme.display(26, relativeTo: .title2)).foregroundStyle(Theme.accent)
            }
            .fixedSize()
            .dynamicTypeSize(...DynamicTypeSize.xLarge)   // stays inside the bar at large text sizes
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title).accessibilityAddTraits(.isHeader)
        .accessibilityHint(mode == .snap ? "Offers to switch back to Awwbum" : "")
        .confirmationDialog("Would you like to switch to \(mode.other.title)?", isPresented: $asking, titleVisibility: .visible) {
            Button("Switch to \(mode.other.title)") { ModeSwitch.shared.switchTo(mode.other) }
            Button("Stay in \(mode.title)", role: .cancel) {}
        } message: {
            Text(mode == .aww
                 ? "AwwSnap ranks the best photos of the grown-ups. It has its own list, scores, learning and settings; only Who's Who is shared."
                 : "Back to Awwbum's photos of the kids.")
        }
    }
}
