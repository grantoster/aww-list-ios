import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ListScope: Hashable { case all, year(Int) }

struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var scanner: PhotoScanner
    @State private var scope: ListScope = .all
    @State private var age: AgeGroup?
    @State private var shot: ShotKind?
    @State private var person: UUID?
    @State private var showWho = false
    @State private var sortByDate = false
    @State private var viewer: ViewerState?
    @State private var showSettings = false
    @State private var shown = 60
    /// Picking photos to send: hold any photo to start, then tap more. Best-photo ids, in the order picked.
    @State private var selecting = false
    @State private var picked: [String] = []
    @State private var preparing = false
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

    private var pool: [Moment] {
        library.moments.filter { m in
            if case .year(let y) = scope, m.year != y { return false }
            if let age, !m.ages.contains(age) { return false }
            if let shot, m.shot != shot { return false }
            if let person, !m.people.contains(person) { return false }
            return true
        }
    }
    private var top: [Moment] { Array(pool.prefix(30)) }
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
                    shotBar
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
            .navigationTitle(selecting ? "\(picked.count) selected" : "Aww List")
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
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
            .fullScreenCover(item: $viewer) { v in ViewerView(moments: v.list, index: v.index) }
            .onChange(of: scope) { shown = 60; if !preparing { endSelecting() } }
            .onChange(of: age) { shown = 60; if !preparing { endSelecting() } }
            .onChange(of: shot) { shown = 60; if !preparing { endSelecting() } }
            .onChange(of: person) { shown = 60; if !preparing { endSelecting() } }
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

    /// Just kids (close-ups and kids together) or family and groups (grown-ups in the shot, or a crowd).
    private var shotBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Shots").font(.subheadline).foregroundStyle(.secondary)
                Pill(title: "All", on: shot == nil, small: true) { shot = nil }
                ForEach(ShotKind.allCases) { k in Pill(title: k.label, on: shot == k, small: true) { shot = k } }
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
            Text(scopeTitle + " top 30").font(Theme.display(26)).lineLimit(1).minimumScaleFactor(0.7)
            Text("\(pool.count.formatted()) moments ranked").font(.subheadline).foregroundStyle(.secondary)
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
                .buttonStyle(.bordered).controlSize(.regular).disabled(preparing || top.isEmpty || selecting)
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Array(top.dropFirst(5).enumerated()), id: \.element.id) { i, m in
                    Tile(moment: m, rank: i + 6, picked: pickState(m), onHold: { hold(m) }) { tap(top, i + 5) }
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
                    Tile(moment: m, rank: nil, picked: pickState(m), onHold: { hold(m) }) { tap(listed, i) }
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
        .disabled(picked.isEmpty || preparing)
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
                if let img = await AssetImage.load(id: id, size: CGSize(width: 1600, height: 1600), mode: .aspectFit),
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
            Text(moment.caption).font(.subheadline.bold()).lineLimit(2, reservesSpace: true)
            Text(moment.best.date.shortDay).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .scaleEffect(pressing ? 0.97 : 1)
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
    let moment: Moment
    let rank: Int?
    var picked: Bool? = nil
    var onHold: () -> Void = {}
    let action: () -> Void
    @State private var pressing = false
    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay(AssetImage(id: moment.best.id, targetSide: 200))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) { if let rank { RankBadge(rank: rank).scaleEffect(0.8).padding(2) } }
            .overlay(alignment: .bottomTrailing) { if picked == nil { ScoreBadge(score: moment.score).scaleEffect(0.85).padding(3) } }
            .overlay { PickMark(picked: picked) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(pressing ? 0.95 : 1)
            .animation(.easeOut(duration: 0.15), value: pressing)
            .onTapGesture(perform: action)
            .onLongPressGesture(minimumDuration: 0.4, perform: onHold, onPressingChanged: { pressing = $0 })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Score \(moment.score), \(moment.caption), \(moment.best.date.shortDay)")
            .accessibilityAddTraits(picked == true ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
            .accessibilityAction(named: picked == nil ? "Pick photos to send" : "Pick or unpick", onHold)
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
