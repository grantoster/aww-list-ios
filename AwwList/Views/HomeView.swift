import SwiftUI

enum ListScope: Hashable { case all, year(Int) }

struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var scanner: PhotoScanner
    @State private var scope: ListScope = .all
    @State private var age: AgeGroup?
    @State private var person: UUID?
    @State private var showWho = false
    @State private var sortByDate = false
    @State private var viewer: ViewerState?
    @State private var showSettings = false
    @State private var shown = 60

    private var pool: [Moment] {
        library.moments.filter { m in
            if case .year(let y) = scope, m.year != y { return false }
            if let age, !m.ages.contains(age) { return false }
            if let person, !m.people.contains(person) { return false }
            return true
        }
    }
    private var top: [Moment] { Array(pool.prefix(20)) }
    private var listed: [Moment] { sortByDate ? pool.sorted { $0.best.date > $1.best.date } : pool }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if scanner.isScanning && scanner.total > 0 {
                        ScanBanner()
                    }
                    scopeBar
                    ageBar
                    whoBar
                    if library.claudeScored > 0 || library.learned != nil { rankBar }
                    if age == .toddler && library.birthdays.isEmpty && !library.people.contains(where: { $0.birthday != nil }) {
                        ContentUnavailableView {
                            Label("Add your kids' birthdays", systemImage: "birthday.cake")
                        } description: {
                            Text("Photos can tell a baby from an older child, but not a toddler from a kid. With birthdays, each photo is sorted by how old your kids were that day.")
                        } actions: {
                            Button("Add birthdays") { showSettings = true }.buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 24)
                    } else if pool.isEmpty {
                        ContentUnavailableView("No moments yet", systemImage: "heart.circle",
                                               description: Text(scanner.isScanning ? "Still looking through your photos." : "Nothing matched this filter."))
                            .padding(.top, 40)
                    } else {
                        topSection
                        allSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .navigationTitle("Aww List")
            .toolbar {
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
            .fullScreenCover(item: $viewer) { v in ViewerView(moments: v.list, index: v.index) }
            .onChange(of: scope) { shown = 60 }
            .onChange(of: age) { shown = 60 }
            .onChange(of: person) { shown = 60 }
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

    private var ageBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Age").font(.subheadline).foregroundStyle(.secondary)
                Pill(title: "All ages", on: age == nil, small: true) { age = nil }
                ForEach(AgeGroup.allCases) { g in Pill(title: g.label, on: age == g, small: true) { age = g } }
            }
        }
    }

    /// Once Claude has scored photos: order the lists by Claude's score or by Apple's on-device score.
    private var rankBar: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
            Text("Rank by").font(.subheadline).foregroundStyle(.secondary)
            Pill(title: "Claude", on: library.rankBy == "claude", small: true) { library.setRankBy("claude") }
            if library.learned != nil {
                Pill(title: "Learned", on: library.rankBy == "learned", small: true) { library.setRankBy("learned") }
            }
            Pill(title: "Apple", on: library.rankBy == "apple" || (library.rankBy == "learned" && library.learned == nil),
                 small: true) { library.setRankBy("apple") }
        } }
    }

    /// Filter by someone named in Who's Who; until someone is named, a button to start.
    @ViewBuilder private var whoBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Who").font(.subheadline).foregroundStyle(.secondary)
                if library.people.isEmpty {
                    Pill(title: "Name faces…", on: false, small: true) { showWho = true }
                } else {
                    Pill(title: "Everyone", on: person == nil, small: true) { person = nil }
                    ForEach(library.people) { p in Pill(title: p.name, on: person == p.id, small: true) { person = p.id } }
                }
            }
        }
    }

    private var topSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(scopeTitle + " top 20").font(Theme.display(26)).lineLimit(1).minimumScaleFactor(0.7)
            Text("\(pool.count.formatted()) moments ranked").font(.subheadline).foregroundStyle(.secondary)
            if let first = top.first {
                Card(moment: first, rank: 1, height: 380) { open(top, 0) }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(top.dropFirst().prefix(4).enumerated()), id: \.element.id) { i, m in
                    Card(moment: m, rank: i + 2, height: 190) { open(top, i + 1) }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Array(top.dropFirst(5).enumerated()), id: \.element.id) { i, m in
                    Tile(moment: m, rank: i + 6) { open(top, i + 5) }
                }
            }
        }
    }

    private var allSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("See all").font(Theme.display(22))
                    Spacer()
                    sortPicker.frame(maxWidth: 200)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("See all").font(Theme.display(22))
                    sortPicker
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(Array(listed.prefix(shown).enumerated()), id: \.element.id) { i, m in
                    Tile(moment: m, rank: nil) { open(listed, i) }
                }
            }
            if listed.count > shown {
                Button("Show more") { shown += 60 }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
        }
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $sortByDate) {
            Text("Cutest").tag(false)
            Text("By date").tag(true)
        }.pickerStyle(.segmented)
    }

    private var scopeTitle: String {
        let who = person.flatMap { id in library.people.first { $0.id == id }?.name }
        if case .year(let y) = scope { return who.map { "\($0)'s \(y)" } ?? String(y) }
        return who.map { "\($0)'s" } ?? "Overall"
    }

    private func open(_ list: [Moment], _ i: Int) { viewer = ViewerState(list: list, index: i) }
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
                .font(.system(size: small ? 14 : 16, weight: .bold, design: .rounded))
                .padding(.horizontal, small ? 12 : 16).frame(minHeight: 40)
                .background(on ? Theme.accent : Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct Card: View {
    let moment: Moment
    let rank: Int
    let height: CGFloat
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                AssetImage(id: moment.best.id, targetSide: height * 1.4)
                    .frame(height: height).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topLeading) { RankBadge(rank: rank).padding(8) }
                    .overlay(alignment: .topTrailing) { ScoreBadge(score: moment.score).padding(8) }
                Text(moment.caption).font(.subheadline.bold()).lineLimit(2, reservesSpace: true)
                Text(moment.best.date.shortDay).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct Tile: View {
    let moment: Moment
    let rank: Int?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay(AssetImage(id: moment.best.id, targetSide: 200))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) { if let rank { RankBadge(rank: rank).scaleEffect(0.8).padding(2) } }
                .overlay(alignment: .bottomTrailing) { ScoreBadge(score: moment.score).scaleEffect(0.85).padding(3) }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Score \(moment.score), \(moment.caption), \(moment.best.date.shortDay)")
    }
}

struct ScanBanner: View {
    @EnvironmentObject var scanner: PhotoScanner
    @State private var asked = BackgroundScan.autoContinue
    @State private var failed: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Finding your cutest moments…").font(.subheadline.bold())
            ProgressView(value: Double(scanner.done), total: Double(max(1, scanner.total)))
            Text("\(scanner.done.formatted()) of \(scanner.total.formatted()) photos checked. If you leave, it keeps going in the background (iOS shows its progress), and otherwise picks up overnight while your phone charges, or when you come back.")
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
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}
