import SwiftUI
import Photos
import UIKit

/// Asks for photo access the first time, then shows the list and keeps the scan going.
struct RootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var scanner: PhotoScanner
    @EnvironmentObject var claude: ClaudeService
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Environment(\.scenePhase) private var phase
    /// First open: ask for a Claude API key before anything else (once; skipped when a key is already saved).
    @AppStorage(AppMode.current.key("askedForKey")) private var askedForKey = false
    @State private var hadKey = Claude.apiKey != nil
    /// Set when you choose "score every photo" on that screen: Claude runs by itself once the first scan is done.
    @AppStorage(AppMode.current.key("autoClaude")) private var autoClaude = false
    @AppStorage(AppMode.current.key("autoClaudeTries")) private var autoTries = 0

    var body: some View {
        Group {
            if !library.ready {
                LoadingView()   // reading the saved library, off the main thread
            } else {
            switch status {
            case .authorized, .limited:
                HomeView()
                    .task { scanner.startIfNeeded(library: library) }
            case .denied, .restricted:
                DeniedView()
            default:
                WelcomeView { request() }
            }
            }
        }
        // Existing installs (photos already checked) aren't asked again; a reinstall is (the key survives in the keychain).
        .fullScreenCover(isPresented: Binding(get: { library.ready && !askedForKey && !library.hadSavedData },
                                              set: { if !$0 { askedForKey = true } })) {
            KeySetupView(hadKey: hadKey) { askedForKey = true }
        }
        .onChange(of: scanner.isScanning) { autoScore() }
        .onReceive(Shared.plus.$signedTransaction) { _ in if library.mode == .aww { autoScore() } }   // Plus confirmed: a waiting run can start
        // While the app is open and photos are with Claude, check for their scores every couple of minutes.
        .task(id: phase == .active) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled, phase == .active, library.ready else { continue }
                if !library.claudeBatches.isEmpty && !claude.busy { await claude.collect(library) }
            }
        }
        .onChange(of: phase) {
            if phase == .inactive && scanner.isScanning {
                // Leaving the app mid-scan: ask iOS to keep it going (it must be asked while still on screen).
                BackgroundScan.continueInBackground()
            }
            if phase == .active {
                BackgroundScan.appBecameActive()
                status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status == .authorized && !library.notVisible.isEmpty { scanner.start(library: library) }   // Limited → Full
                if status == .authorized || status == .limited { scanner.startIfNeeded(library: library) }
                if !library.claudeBatches.isEmpty { Task { await library.claude.collect(library) } }
                autoScore()
            } else if phase == .background {
                // Photos may be hidden or deleted in Photos while Awwbum is away: no cached copy outlives that.
                AssetImage.clearCache()
                if library.mode == .snap {
                    // AwwSnap doesn't scan in the background: stop, and save it (and Who's Who, with Awwbum's) now.
                    scanner.stop(); library.flush(); Shared.library.flush()
                } else {
                    library.save()
                }
                BackgroundScan.wrapUpAfterClosing()
                BackgroundScan.scheduleOvernight()
            }
        }
    }

    /// Keeps a scoring run going (started with Score, or chosen on the first screen) until everything chosen is
    /// scored: it picks up again by itself when the photo check finishes and when you come back to the app. Same
    /// rules and checks as every send. It stops after a pass that finished (or was stopped), when the key is
    /// rejected, or after 6 tries in a row that sent nothing.
    private func autoScore() {
        guard autoClaude, phase == .active, status == .authorized || status == .limited,
              !scanner.isScanning, !scanner.needsScan, !claude.busy, !library.photos.isEmpty,
              Claude.apiKey(for: library.mode) != nil || claude.viaPlus else { return }
        Task { await ClaudeService.runAndTrack(library) }
    }

    private func request() {
        Task { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
    }
}

struct WelcomeView: View {
    let onStart: () -> Void
    var body: some View {
        GeometryReader { geo in
        ScrollView {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Theme.logoImage.resizable().scaledToFit().frame(width: 150, height: 150).accessibilityHidden(true)
            Text(AppMode.current.name).font(Theme.display(44, relativeTo: .largeTitle)).foregroundStyle(Theme.accent)
            Text("Finds the photos of your kids that make everyone go aww, and ranks them year by year.")
                .font(Theme.label(19, relativeTo: .title3)).multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("Scoring happens on this iPhone. Photos are only uploaded if you choose to score them with Claude.", systemImage: "lock.fill")
                Label("It never edits, adds or deletes photos. The only change it can make is a favorite, when you tap the heart.", systemImage: "hand.raised")
                Label("Screenshots and possible bath photos are left out.", systemImage: "eye.slash")
                Label("Bursts count as one moment, using the best shot.", systemImage: "square.stack")
            }
            .font(.subheadline).padding().background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
            Spacer(minLength: 0)
            Button(action: onStart) {
                Text("Find my awws").font(Theme.label(19, relativeTo: .headline)).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            Text("For the full list, allow access to all photos.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minHeight: geo.size.height)   // fills the screen, and scrolls when text is large
        }
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

struct DeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Photo access is off", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("Awwbum needs to look at your photos to rank them. Turn on access in Settings → Awwbum → Photos.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }.buttonStyle(.borderedProminent)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var scanner: PhotoScanner
    @State private var keepTick = 0
    @AppStorage(AppMode.current.key("groupSimilar")) private var groupSimilar = true
    @AppStorage(AppMode.current.key("balanceKids")) private var balanceKids = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if PlusStore.available && library.mode == .aww { PlusSection() }
                ClaudeSection()
                LikesSection()
                LearnedSection()
                if library.mode == .aww { BirthdaysSection() }
                PlacesSection()
                Section {
                    NavigationLink("Send feedback") { FeedbackView() }
                } footer: {
                    Text("Tell Grant what's working and what isn't. You choose how to send it (Messages, Mail).")
                }
                DiagnosticsSection()
                Section("Library") {
                    LabeledContent("Photos checked", value: library.photos.count.formatted())
                    LabeledContent("Moments ranked", value: library.everyMoment.count.formatted())
                    if !library.hidden.isEmpty {
                        Button("Put back \(library.hidden.count) removed photos") { library.restoreHidden() }
                    }
                    Button(scanner.isScanning ? "Scanning…" : "Rescan, including photos that couldn't load") { scanner.start(library: library, retryUnavailable: true) }
                        .disabled(scanner.isScanning)
                    if BackgroundScan.canContinueInBackground && library.mode == .aww {   // background scans are Awwbum's
                        Toggle("Keep scanning when I leave the app", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: BackgroundScan.autoKey) },
                            set: { UserDefaults.standard.set($0, forKey: BackgroundScan.autoKey); keepTick += 1 }))
                            .id(keepTick)
                    }
                }
                Section {
                    Toggle("Fold similar shots together", isOn: $groupSimilar)
                    if library.mode == .aww { Toggle("Balance kids", isOn: $balanceKids) }
                } header: {
                    Text("Home list")
                } footer: {
                    Text("Look-alike photos taken within 5 minutes of a better-ranked one are tucked under it (shown as +3 and so on), so the top lists show more different moments. Tap a photo and \"See similar\" to view them.\n\nBalance kids gives each child in Who's Who (the ones with a birthday, while they're under 13, or everyone named if no one has a birthday) a share of the top spots that matches how often they're in your photos, so the scores can't favor one of them. Photos without a named child get their share too. Each child's best photos still come first, and scores don't change. It's off while one person is picked.")
                }
                HeldBackSection()
                Section("What's left out") {
                    LabeledContent("On the list", value: "\(library.listedPhotos.formatted()) photos")
                    ForEach(library.leftOut, id: \.reason) { row in
                        // Photos can be added back from every group except ones the app can't read or see yet.
                        let fixed = row.reason.hasPrefix("Not in your Limited") || row.reason.hasPrefix("Waiting")
                            || row.reason.hasPrefix("Couldn't be loaded")
                        NavigationLink {
                            // Screenshots, documents and undated photos are never added back.
                            let ok = fixed ? [] : row.ids.filter { id in library.photos[id].map(library.canAddBack) ?? false }
                            PhotoGroupView(title: row.reason, ids: row.ids, action: ok.isEmpty ? .none : .addBack, addable: Set(ok))
                        } label: {
                            LabeledContent(row.reason, value: row.count.formatted())
                        }
                    }
                    if !library.addedBack.isEmpty {
                        NavigationLink {
                            PhotoGroupView(title: "Added back by you",
                                           ids: library.addedBack.sorted { (library.photos[$0]?.date ?? .distantPast) > (library.photos[$1]?.date ?? .distantPast) },
                                           action: .takeOff)
                        } label: {
                            LabeledContent("Added back by you", value: library.addedBack.count.formatted())
                        }
                    }
                    Text("Counts are photos, not moments; a moment's other shots in a burst count as on the list.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Left off on the phone: screenshots, documents, and photos with no face and no sign of a child. Photos with faces but no child label stay off the list but are offered to Claude, which can put them on it. Possible bath or undressed photos are listed and scored on the phone (you can keep any out above), but they, and every shot within 10 minutes of one or of any faint bath sign, are never sent to Claude.")
                        .font(.footnote)
                    Text("Everything else Apple isn't sure about stays on the list with a flag: no child spotted, water scenes, swimwear, shirtless, and files that look AI-generated, face-retouched or not from a camera. Claude makes the call on those, and once the app has learned from Claude's calls, it hides the ones it expects Claude would remove when ranking by Claude or by the learned score. Ranking by Apple shows them all.")
                        .font(.footnote)
                    Text("Awwbum reads your photo library. It never edits, adds or deletes photos; the only change it can make is a favorite, when you tap the heart. Remove from list only hides a photo inside this app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !library.flagged.isEmpty {
                    Section {
                        ForEach(library.flagged, id: \.reason) { row in
                            NavigationLink { PhotoGroupView(title: row.reason, ids: row.ids) } label: {
                                LabeledContent(row.reason, value: row.count.formatted())
                            }
                        }
                    } header: {
                        Text("On the list, but flagged")
                    } footer: {
                        Text("Apple's check wasn't sure about these, so they stay on the list with a flag. Claude makes the final call on the ones it sees; possible swimwear and shirtless photos are sent to Claude only if you turn that on.")
                    }
                }
                Section("How scores work") {
                    Text("Shots less than a minute apart (two at most) count as one moment, and only its best shot is ranked.")
                        .font(.footnote)
                    Text("Each photo gets points for the main child's expression (25%: a laugh beats a smile, and a sleeping baby counts too), eyes open and looking at the camera (10%), photo quality from Apple's quality score and sharpness (12%), how big the child is in the frame (10%), how clearly a child is the subject (10%), action and play (5%), a special moment or outing like a birthday cake, costume, snow or the zoo (5%), pure \"aww\" like a sleeping baby (5%), pure joy like a real laugh or arms up (5%), candid moments caught mid-action or looking away (5%), the best smile, grin or mischief, a big grin or a cheeky smirk (5%), and unposed fun, kids clearly having fun and not posing for the camera, messy or not (3%). A second person earns nothing extra, and crowds count a little less.")
                        .font(.footnote)
                    Text("Those points become 1–10 by rank across your whole library: about 1 in 20 moments a year is a 9 or 10 (the top 1% are 10s), the next 10% are 8s and the next 15% are 7s. Every year counts equally, so a huge year can't crowd out the others, and a photo needs real quality for a high score, not just being the best of a weak bunch.")
                        .font(.footnote)
                    Text("Photos are analyzed with Apple's on-device Vision framework. Nothing is uploaded unless you score with Claude.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The children's birthdays: they sort photos into Baby (under 1), Toddler (1–3) and Kid (4+).
struct BirthdaysSection: View {
    struct Child: Identifiable { let id = UUID(); var date: Date }
    @EnvironmentObject var library: Library
    @State private var kids: [Child] = []
    @State private var loaded = false
    var body: some View {
        Section {
            ForEach($kids) { $kid in
                DatePicker("Child \((kids.firstIndex { $0.id == kid.id } ?? 0) + 1)", selection: $kid.date,
                           in: ...Date(), displayedComponents: .date)
            }
            .onDelete { kids.remove(atOffsets: $0) }
            Button("Add a child's birthday") {
                let start = Calendar.current.startOfDay(for: Date())
                kids.append(Child(date: Calendar.current.date(byAdding: .year, value: -1, to: start) ?? start))
            }
        } header: {
            Text("Your kids' birthdays")
        } footer: {
            Text("Used only on this iPhone to sort photos into Baby (under 1), Toddler (1–3) and Kid (4 and up). Swipe left to remove one.")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            kids = library.birthdays.map { Child(date: $0) }
        }
        // Saved a moment after the last change, so picking a date doesn't re-sort the library on every tap
        // and nothing is lost if the app is closed with Settings open.
        .onDisappear { apply() }
        .task(id: kids.map(\.date)) {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            apply()
        }
    }

    private func apply() {
        guard loaded else { return }
        let dates = kids.map { Calendar.current.startOfDay(for: $0.date) }
        if dates.sorted() != library.birthdays { library.setBirthdays(dates) }
    }
}

/// Optional: Claude gives the final score, description and checks for the photos you choose.
struct ClaudeSection: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var claude: ClaudeService
    @EnvironmentObject var scanner: PhotoScanner
    @EnvironmentObject var plus: PlusStore
    @State private var key = ""
    @State private var hasKey = Claude.apiKey != nil
    /// Photos can be scored: with Awwbum Plus, or your own API key.
    private var canScore: Bool { hasKey || onPlus }
    /// Scoring goes through Awwbum Plus (no charges to an Anthropic account, no batches).
    private var onPlus: Bool { library.mode == .aww && PlusStore.available && plus.isActive }
    @AppStorage(AppMode.current.key("autoClaude")) private var autoClaude = false
    @AppStorage(AppMode.current.key("autoClaudeTries")) private var autoTries = 0
    @AppStorage(AppMode.current.key("claudeFast")) private var fast = true

    @ViewBuilder private var keyRows: some View {
        if hasKey {
            LabeledContent("API key", value: "Saved on this iPhone")
            Button("Remove key", role: .destructive) { Claude.apiKey = nil; hasKey = false }
        } else {
            SecureField("Paste your Claude API key", text: $key)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save key") { Claude.apiKey = key; key = ""; hasKey = Claude.apiKey != nil }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Starts scoring and keeps going until everything chosen is scored: if the photo check is running, or new
    /// photos arrive mid-way, it picks up again by itself when the check finishes and when you come back to the app.
    private func start() {
        autoTries = 0
        autoClaude = true
        ClaudeService.askToNotify()   // so a run that finishes while you're away can tell you
        Task { await ClaudeService.runAndTrack(library) }
    }

    var body: some View {
        Section {
            if PlusStore.available {
                // With Awwbum Plus, no key is needed; your own key stays an advanced option.
                DisclosureGroup(hasKey ? "Your own API key (saved)" : "Use your own Anthropic API key") { keyRows }
            } else {
                keyRows
            }
            Picker("Model", selection: Binding(get: { library.claudeModel }, set: { library.setClaude(model: $0) })) {
                ForEach(Claude.models, id: \.id) { m in Text(m.name).tag(m.id) }
            }
            Picker("Photos to send", selection: Binding(get: { library.claudeScope }, set: { library.setClaude(scope: $0) })) {
                ForEach(Claude.scopes, id: \.n) { s in Text(s.name).tag(s.n) }
            }
            let n = library.claudeToSend
            LabeledContent("Not sent yet", value: n == 0 ? "None" : "\(n.formatted()) photos")
            if !library.claudeBatches.isEmpty {
                LabeledContent("Being scored", value: "\(library.claudeBatches.reduce(0) { $0 + $1.photos.count }.formatted()) photos")
            }
            if !onPlus {
            Picker("Speed", selection: $fast) {
                Text("Fast").tag(true)
                Text("Half price").tag(false)
            }
            Text(fast ? "Fast: scores come back as each photo is sent, usually seconds apart. Full price."
                      : "Half price: photos go in batches and Claude's scores usually arrive within an hour.")
                .font(.footnote).foregroundStyle(.secondary)
            }
            if n > 0 && !onPlus {
                Text("Estimated cost: about \(Claude.dollars(micros: Claude.costMicros(photos: n, model: library.claudeModel, fast: fast))) for \(n.formatted()) photos. This is an estimate (about 1,200 tokens in and about 300 out a photo); your Anthropic bill shows the actual.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if hasKey {
                Button("Test connection") { Task { await claude.testConnection() } }.disabled(claude.busy)
            }
            Toggle("Also send possible swimwear or shirtless photos",
                   isOn: Binding(get: { library.claudeSensitive }, set: { library.setClaudeSensitive($0) }))
            if claude.busy || autoClaude {
                Button("Stop scoring") { autoClaude = false; claude.stop() }
                if !claude.busy {
                    Text("Scoring continues by itself once the photo check finishes or when you come back to the app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Button(scanner.isScanning ? "Score with Claude (starts after the photo check)" : "Score \(n.formatted()) photos with Claude") { start() }
                    .disabled(!canScore || (n == 0 && !scanner.isScanning))
            }
            let rc = library.claudeRecheckable
            if library.claudeScored > 0 {
                Button(onPlus ? "Check Claude's consistency (re-score \(rc.formatted()) photos)"
                       : "Check Claude's consistency (re-score \(rc.formatted()) photos, about \(Claude.dollars(micros: Claude.costMicros(photos: rc, model: library.claudeModel, fast: fast))))") {
                    Task { await claude.send(library, recheck: true) }
                }
                .disabled(!canScore || claude.busy || rc == 0 || scanner.isScanning)
                if let c = library.consistency {
                    let pts = String(format: "%.1f", (c.gap * 10 + 1e-9).rounded(.toNearestOrAwayFromZero) / 10)
                    let pct = Int((c.withinHalf * 100 + 1e-9).rounded(.toNearestOrAwayFromZero))
                    LabeledContent("Claude vs. itself", value: "\(pts) points apart · \(pct)% within half a point")
                    Text("On \(c.n.formatted()) photos Claude scored twice. That's how much Claude's own scores wobble; the learned score can't reliably beat that noise. The learning uses the average of the two scores (so its accuracy above is measured against those averages too). The cost is an estimate; your Anthropic bill shows the actual.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Re-sends photos Claude already scored (spread across the years) to see how much its scores vary, and to give the learning steadier targets. Same privacy rules as scoring.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !library.claudeBatches.isEmpty {
                Button("Check for Claude's scores") { Task { await claude.collect(library) } }.disabled(claude.busy)
            }
            if !claude.status.isEmpty { Text(claude.status).font(.footnote).foregroundStyle(.secondary) }
            if library.claudeScored > 0 {
                LabeledContent("Scored by Claude", value: library.claudeScored.formatted())
                Button("Go back to on-device scores only", role: .destructive) {
                    autoClaude = false; claude.stop()   // so nothing is re-sent by itself afterward
                    library.clearClaude()
                }
                    .disabled(claude.busy || !library.claudeBatches.isEmpty)   // not while photos are out being scored
            }
        } header: {
            Text("Score with Claude")
        } footer: {
            if onPlus {
                Text("With Awwbum Plus, photos are scored through Awwbum's server; nothing is charged to an Anthropic account. Claude decides what comes off the list. Photos flagged as possible bath or undressed, and every shot within 10 minutes of one, are never sent. Photos are sent at most 768 pixels on the long side, without location or file details. Anthropic's terms say it doesn't train on what's sent; it normally deletes it within 30 days, and can keep anything its safety checks flag for up to 2 years.")
            } else {
            Text("Optional. Claude decides what comes off the list. Your phone scores every photo first and only flags what it isn't sure about (no child spotted, water, swimwear, shirtless, AI or edited files); flagged photos stay listed. Each year's best photos, flagged or not, plus a spread of lower-ranked ones and photos with faces but no child label, are sent to Anthropic's Claude for the final 1–10 score, a description, and the call on whether a photo belongs (bath, undressed or shirtless outside swimwear, AI or edited, no child). Swimsuits at the beach or pool are fine and stay on the list. Photos flagged as possible bath or undressed (by Apple's check or Claude's), and every shot within 10 minutes of one, are never sent, even if you put them back. The check is automatic and can miss some photos. Right before sending, the phone re-reads every photo taken within 10 minutes of each one; if any isn't checked yet (still downloading from iCloud, or new), it waits. With Limited photo access, photos outside your selection can't be checked. Possible swimwear and shirtless photos (and the shots right around them) are sent only if you turn that on above; otherwise they stay listed and Claude just doesn't see them (so when ranking by Claude, they can't rank above Claude's top-scored photos). Photos are sent at most 768 pixels on the long side, without location or file details. It uses your own API key from console.anthropic.com; charges go to your Anthropic account. Anthropic's terms say it doesn't train on what's sent; it normally deletes it within 30 days, and can keep anything its safety checks flag for up to 2 years. When ranking by Claude, photos Claude hasn't seen are held at 6 or below (8 or below once there's a learned score).")
            }
        }
    }
}

/// The app's learned score: what it picked up from Claude's scores, and how close it gets.
struct LearnedSection: View {
    @EnvironmentObject var library: Library
    @State private var copied = false
    @State private var askShare = false
    @State private var preparingShare = false
    @State private var shareFile: ShareFile?
    var body: some View {
        Section {
            if let m = library.learned {
                LabeledContent("Learned from", value: "\(m.trainedOn.formatted()) " + (library.pairVotes.isEmpty ? "Claude scores" : "photos (Claude scores and your votes)"))
                let pct = { (v: Double) in "\(Int((v * 100 + 1e-9).rounded(.toNearestOrAwayFromZero)))%" }
                let pts = { (v: Double) in String(format: "%.1f", (v * 10).rounded(.toNearestOrAwayFromZero) / 10) + " points" }
                LabeledContent("Within 1 point of Claude", value: pct(m.within1))
                LabeledContent("Average gap", value: pts(m.meanGap))
                if let o = m.topOverlap {
                    LabeledContent("Also picks Claude's top fifth", value: pct(o))
                }
                if let lg = m.linearGap, (m.blend ?? 0) > 0 {
                    LabeledContent("Without the neural net", value: pts(lg))
                }
                if let a = m.averaged, a > 0 {
                    LabeledContent("Scores averaged from two Claude passes", value: a.formatted())
                }
                if let bw = m.baselineWithin1, let bg = m.baselineGap {
                    LabeledContent("Just guessing the average", value: "\(pct(bw)) · \(pts(bg))")
                }
                Text("Checked on \(m.tested.formatted()) photos from days it didn't learn from, among the photos Claude scored (each year's top picks), so it may be less exact on photos further down the list.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Last trained", value: m.date.formatted(date: .abbreviated, time: .shortened))
            } else {
                let n = library.learnableCount
                Text(n == 0 ? "Once Claude has scored some of your photos, the app learns from those scores and uses them to score every photo on this iPhone."
                            : "Learning starts once there are roughly 80–100 Claude scores (spread over enough days to test it fairly). You have \(n.formatted()) so far.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let f = library.learnedFilter {
                let pct = { (v: Double) in "\(Int((v * 100 + 1e-9).rounded(.toNearestOrAwayFromZero)))%" }
                LabeledContent("Removals learned from", value: "\(f.removals.formatted()) of \(f.trainedOn.formatted())")
                LabeledContent("Agrees with Claude on keep or remove", value: pct(f.accuracy))
                LabeledContent("Just keeping everything", value: pct(f.baselineAccuracy))
                if let c = f.caught { LabeledContent("Catches Claude's removals", value: pct(c)) }
                if let w = f.wronglyRemoved { LabeledContent("Would wrongly remove", value: pct(w) + " of keepers") }
                Text(!f.useful
                     ? "Checked on \(f.tested.formatted()) photos from days it didn't learn from. It isn't clearly better than keeping everything yet (it needs at least \(Learner.minimumTestRemovals) of Claude's removals in that check, too), so it isn't hiding anything."
                     : library.rankBy == "apple" || (library.rankBy == "learned" && library.learned == nil)
                     ? "Checked on \(f.tested.formatted()) photos from days it didn't learn from. It hides photos only when ranking by Claude, by the learned score or by Consolidated; ranking by Apple shows everything."
                     : "Checked on \(f.tested.formatted()) photos from days it didn't learn from. It's hiding \(library.filteredOut.formatted()) photos Claude hasn't seen.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if library.learned != nil {
                Text("Learning Claude's removals starts once Claude has removed at least \(Learner.minimumRemovals) photos (from enough days to test it fairly).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if library.learnedIsBuiltIn || library.filterIsBuiltIn {
                Text("Using the learning built into the app (from \(library.builtInScores.formatted()) Claude scores). This phone's own learning takes over once it has learned from at least as many, or right away if you turn off the built-in learning below (with no learning of its own yet, that means no learned score).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if library.hasBuiltIn {
                Toggle("Use the built-in learning", isOn: Binding(get: { library.useBuiltInLearning },
                                                                   set: { library.setUseBuiltInLearning($0) }))
            }
            if library.ownModel != nil || library.ownFilter != nil {
                let n = max(library.ownModel?.trainedOn ?? 0, library.ownFilter?.trainedOn ?? 0)
                LabeledContent("This phone's own learning", value: "\(n.formatted()) Claude verdicts")
            }
            Button("Start learning over") { library.relearn(); copied = false }
                .disabled(library.training)
            Text("Throws away this phone's own learning and learns again from every Claude score on this iPhone (\(library.learnableCount.formatted()) so far). The built-in learning isn't affected.")
                .font(.footnote).foregroundStyle(.secondary)
            if let text = library.learningText {
                Button(copied ? "Copied" : "Copy learning") {
                    UIPasteboard.general.string = text
                    copied = true
                }
                Text("Copies this phone's own learning (numbers only, no photos) so it can be built into the app as the starting point for new installs.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Copy learning appears once this phone has learned from its own Claude scores (about 80–100 of them, spread over enough days).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            let shareable = library.shareableLearningCount
            if shareable > 0 {
                Button(preparingShare ? "Getting it ready…" : "Send my learning data to Grant") { askShare = true }
                    .disabled(preparingShare)
                    .confirmationDialog("Send your learning data?", isPresented: $askShare, titleVisibility: .visible) {
                        Button("Send learning data") {
                            preparingShare = true
                            Task {
                                let url = await library.writeLearningData()
                                try? await Task.sleep(for: .milliseconds(500))   // let the dialog finish closing
                                preparingShare = false
                                if let url { shareFile = ShareFile(url: url) }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("For each photo Claude judged, this sends numbers the phone measured (like smiles, sharpness and the kind of scene), Claude's score, and whether Claude removed it. It leaves out the photos themselves, photo names, captions, names, face prints and face-shape measurements, locations and dates, and never includes bath or undressed photos. The numbers can't practically be turned back into pictures, though someone who already had one of your photos could tell it matches. Grant uses this only to improve the learning built into Awwbum.")
                    }
                    .sheet(item: $shareFile, onDismiss: {
                        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Awwbum learning data.json"))
                    }) { f in ShareSheet(items: [f.url]) }
                Text("Optional. Sends the numbers behind your \(shareable.formatted()) Claude results so the learning built into the app can learn from more families. No photos, names, faces, captions, places or dates. You choose how to send it (Messages, Mail, AirDrop).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if library.training { HStack { ProgressView(); Text("Learning…").foregroundStyle(.secondary) } }
        } header: {
            Text("Learned score")
        } footer: {
            Text("The app studies Claude's scores alongside what it measures on the phone (smiles, closeness, face size, sharpness and the scene), then predicts a Claude-style score for every photo, privately and for free. It also learns which photos Claude takes off the list, so removals follow Claude's judgment instead of Apple's. Both are checked on a fifth of Claude's verdicts it didn't learn from. Claude's own score and removals always win where they exist; with Rank by Claude, photos Claude hasn't seen use the learned score.")
        }
    }
}

/// A file ready to hand to the share sheet.
struct ShareFile: Identifiable { let id = UUID(); let url: URL }

/// Possible bath or undressed photos Apple held back, with a way to put any of them back on the list.
struct HeldBackSection: View {
    @EnvironmentObject var library: Library
    var body: some View {
        let held = library.heldBackPhotos
        if !held.isEmpty {
            Section {
                NavigationLink {
                    HeldBackView()
                } label: {
                    LabeledContent("Review", value: "\(held.count.formatted()) photos")
                }
            } header: {
                Text("Possible bath photos")
            } footer: {
                Text("Apple's check thinks these may be bath or undressed photos. They're on your list with on-device scores (Apple and learned) unless you keep one out. They, and every shot within 10 minutes of them, are never sent to Claude.")
            }
        }
    }
}

struct HeldBackView: View {
    @EnvironmentObject var library: Library
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(library.heldBackPhotos) { p in
                    let back = !library.keptOut.contains(p.id)
                    VStack(spacing: 6) {
                        AssetImage(id: p.id, targetSide: 120)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(p.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                        if p.soft == nil {
                            Text("Can't be scored").font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Button(back ? "Keep out" : "Put back") { library.setPutBack(p.id, !back) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Possible bath photos")
    }
}

/// Every photo in one group (a reason it's left out, or a flag), newest first. Tap one to see it larger.
struct PhotoGroupView: View {
    let title: String
    let ids: [String]
    /// What you can do with these photos: add them back to the list, take ones you added back off, or nothing.
    enum Action { case none, addBack, takeOff }
    var action: Action = .none
    /// With add back: the photos that may be added back (nil means all of them).
    var addable: Set<String>? = nil
    private func can(_ id: String) -> Bool { action != .none && (addable?.contains(id) ?? true) }
    @EnvironmentObject var library: Library
    @State private var shown = 90
    @State private var open: OpenPhoto?
    @State private var selecting = false
    @State private var picked = Set<String>()
    /// Done this visit (the group itself updates when you go back).
    @State private var done = Set<String>()
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 6)]
    struct OpenPhoto: Identifiable { let id: String }

    private var verb: String { action == .takeOff ? "Take off my list" : "Add back to my list" }
    private func apply(_ list: [String]) {
        guard !list.isEmpty else { return }
        if action == .takeOff { library.takeBack(list) } else { library.addBack(list) }
        done.formUnion(list); picked.subtract(list)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("\(ids.count.formatted()) photos" + (action == .addBack ? ". Tap one to see it larger; add back any you want on your list." : ""))
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(ids.prefix(shown), id: \.self) { id in
                        let on = picked.contains(id), isDone = done.contains(id)
                        Button {
                            if selecting && !isDone && can(id) { if on { picked.remove(id) } else { picked.insert(id) } }
                            else { open = OpenPhoto(id: id) }
                        } label: {
                            AssetImage(id: id, targetSide: 120)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay { if on { RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, lineWidth: 4) } }
                                .overlay(alignment: .topTrailing) {
                                    if on || isDone {
                                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle.inset.filled")
                                            .font(.title3).foregroundStyle(.white, Theme.accent).padding(4)
                                    }
                                }
                                .opacity(isDone && action == .takeOff ? 0.4 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isDone ? (action == .takeOff ? "Photo, taken off" : "Photo, added back") : "Photo")
                        .accessibilityHint(selecting ? (on ? "Picked" : "Not picked") : "Opens it larger")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                if ids.count > shown {
                    Button("See more") { shown += 90 }.buttonStyle(.bordered).tint(Theme.grapeInk)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if action != .none && !ids.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(selecting ? "Cancel" : "Select") { selecting.toggle(); picked = [] }
                }
            }
            if selecting {
                ToolbarItem(placement: .bottomBar) {
                    Button(picked.isEmpty ? verb : (action == .takeOff ? "Take \(picked.count) off" : "Add \(picked.count) back")) {
                        apply(Array(picked))
                    }
                    .buttonStyle(.borderedProminent).disabled(picked.isEmpty)
                }
            }
        }
        .sheet(item: $open) { p in
            NavigationStack {
                AssetImage(id: p.id, contentMode: .fit, targetSide: 1000, cached: false)
                    .background(Color.black)
                    .ignoresSafeArea(edges: .bottom)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { open = nil } }
                        if can(p.id) && !done.contains(p.id) {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(verb) { apply([p.id]); open = nil }
                            }
                        }
                    }
            }
        }
    }
}

/// Shown the first time the app opens: add a Claude API key, and choose to have every photo scored automatically.
struct KeySetupView: View {
    let hadKey: Bool
    @EnvironmentObject var library: Library
    @AppStorage(AppMode.current.key("autoClaude")) private var autoClaude = false
    @State private var key = ""
    @State private var scoreAll = true
    @State private var failed = false
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Theme.logoImage.resizable().scaledToFit().frame(width: 96, height: 96).accessibilityHidden(true)
                Text(AppMode.current.name).font(Theme.display(40, relativeTo: .largeTitle)).foregroundStyle(Theme.accent)
                Text(hadKey ? "Score with Claude" : "Add your Claude API key").font(Theme.label(22, relativeTo: .title2))
                Text("Claude gives each photo its final score and a description, and your phone learns from it. The key is from console.anthropic.com and is saved only in this iPhone's keychain; charges go to your Anthropic account.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if hadKey {
                    Label("Your API key is already saved on this iPhone", systemImage: "key.fill").font(.subheadline)
                } else {
                    SecureField("Paste your Claude API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                Toggle("Score every photo with Claude when the first scan finishes", isOn: $scoreAll)
                    .font(.subheadline)
                Text("Estimated cost with \(Claude.models.first { $0.id == library.claudeModel }?.name ?? "the chosen model"): about \(Claude.dollars(micros: Claude.costMicros(photos: 1_000, model: library.claudeModel, fast: Claude.fast))) per 1,000 photos (an estimate; your Anthropic bill shows the actual). Photos are sent at most 768 pixels on the long side, without location or file details. You can change all of this in Settings.")
                    .font(.footnote).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    Label("The bath filter can miss photos", systemImage: "exclamationmark.triangle").font(.subheadline.bold())
                    Text("Awwbum holds back photos it thinks may show a child in the bath or undressed, and every shot within 10 minutes of one. It's an automatic guess, not a guarantee, so some of those photos could still be sent to Claude. If that's a worry, turn off scoring every photo above and send fewer photos from Settings, or skip Claude scoring.")
                    Text("Photos you send go to Anthropic (the company behind Claude), including other people and other families' kids in them. Anthropic's terms say it doesn't train its models on them. It normally deletes them within 30 days, but can keep anything its safety checks flag for up to 2 years.")
                }
                .font(.footnote).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                if failed { Text("That key couldn't be saved. Check it and try again.").font(.footnote).foregroundStyle(.secondary) }
                Button {
                    if !hadKey {
                        Claude.apiKey = key
                        guard Claude.apiKey != nil else { failed = true; return }
                        key = ""
                    }
                    if scoreAll { library.setClaude(scope: 0); autoClaude = true }
                    onDone()
                } label: {
                    Text(hadKey ? "Continue" : "Save key").font(Theme.label(19, relativeTo: .headline)).frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hadKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Not now") { onDone() }
            }
            .padding(24)
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

/// Shown for a moment at launch while the saved library is read.
struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Theme.logoImage.resizable().scaledToFit().frame(width: 96, height: 96).accessibilityHidden(true)
            ProgressView("Opening your awws…")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}

/// How long opening, ranking and saving took, and memory use, so a slow or closing app can be looked into.
struct DiagnosticsSection: View {
    @EnvironmentObject var library: Library
    @State private var copied = false
    var body: some View {
        Section {
            ForEach(library.diagnostics) { d in LabeledContent(d.label, value: d.value) }
            let bg = BackgroundScan.log
            if !bg.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background scanning").font(.subheadline)
                    ForEach(Array(bg.reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button(copied ? "Copied" : "Copy diagnostics") {
                library.noteMemory()
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                UIPasteboard.general.string = (["Awwbum build \(build)"] + library.diagnostics.map { "\($0.label): \($0.value)" }
                                               + ["Background scanning:"] + BackgroundScan.log)
                    .joined(separator: "\n")
                copied = true
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Timings and memory from this session, to help find what makes the app slow. Nothing here is sent anywhere unless you copy it.")
        }
    }
}


/// Awwbum Plus: Claude scoring without an API key, by subscription.
struct PlusSection: View {
    @EnvironmentObject var plus: PlusStore
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacy = URL(string: "https://claude.ai/artifact/Ly3jgLyTEJ1JV3QB1EJjzB")!

    var body: some View {
        Section {
            if plus.isActive {
                LabeledContent("Status", value: "Active")
                if let e = plus.expires {
                    LabeledContent("Renews or ends", value: e.formatted(date: .abbreviated, time: .omitted))
                }
                if let q = plus.quota {
                    LabeledContent("Photos scored this month", value: "\(q.used.formatted()) of \(q.limit.formatted())")
                }
                Link("Manage subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
            } else if plus.products.isEmpty {
                if plus.loadFailed {
                    Text("Couldn't load the subscription options. Check your connection.").foregroundStyle(.secondary)
                    Button("Try again") { Task { await plus.load() } }
                } else {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                }
            } else {
                ForEach(plus.products, id: \.id) { p in
                    Button {
                        Task { await plus.buy(p) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.displayName).foregroundStyle(.primary)
                                Text(p.description).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(p.displayPrice + (p.subscription?.subscriptionPeriod.unit == .year ? "/year" : "/month"))
                                .font(.subheadline.bold())
                        }
                    }
                    .disabled(plus.busy)
                }
            }
            Button("Restore Purchases") { Task { await plus.restore() } }.disabled(plus.busy)
            if let m = plus.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Awwbum Plus")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude scores your photos with no API key to set up: the photos you send go through Awwbum's server to Anthropic (the company behind Claude) and aren't kept on the server. Same privacy rules as scoring with your own key: photos are sent at most 768 pixels on the long side, without location or file details, and possible bath or undressed photos are never sent. Up to \((plus.quota?.limit ?? 5_000).formatted()) photos a month. Payment is charged to your Apple ID; the subscription renews automatically unless canceled at least 24 hours before the end of the period, and can be managed in your App Store account settings.")
                HStack(spacing: 16) {
                    Link("Terms of Use", destination: Self.terms)
                    Link("Privacy Policy", destination: Self.privacy)
                }
            }
        }
        .task { await plus.load() }
    }
}


/// Send feedback: your note, plus (if you leave it on) the build number and the Diagnostics below, handed to the share
/// sheet so you pick how to send it. No photos are included.
struct FeedbackView: View {
    @EnvironmentObject var library: Library
    @State private var note = ""
    @State private var includeDiagnostics = true
    @State private var sharing: SharedText?
    struct SharedText: Identifiable { let id = UUID(); let text: String }

    private var message: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var lines = ["Awwbum feedback (build \(build))", "", note.trimmingCharacters(in: .whitespacesAndNewlines)]
        if includeDiagnostics {
            library.noteMemory()
            lines += ["", "Diagnostics:"] + library.diagnostics.map { "\($0.label): \($0.value)" }
            let bg = BackgroundScan.log
            if !bg.isEmpty { lines += ["", "Background scanning:"] + bg }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $note).frame(minHeight: 160)
                    .overlay(alignment: .topLeading) {
                        if note.isEmpty {
                            Text("What happened, or what would make it better?").foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } footer: {
                Text("No photos are included. Screenshots help: you can attach them in Messages or Mail.")
            }
            Section {
                Toggle("Include diagnostics", isOn: $includeDiagnostics)
            } footer: {
                Text("Timings, memory, photo counts and background-scanning notes from this iPhone. No photos, names or Claude key.")
            }
            Section {
                Button("Send…") { sharing = SharedText(text: message) }
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Send feedback").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharing) { t in ShareSheet(text: t.text).presentationDetents([.medium, .large]) }
    }
}

/// Settings: places you save (a home, by address) for the Place filter, and naming towns from photo locations.
struct PlacesSection: View {
    @ObservedObject private var places = Shared.places
    @State private var adding = false
    var body: some View {
        Section {
            ForEach(places.saved) { p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
                    Text(p.address).font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { idx in idx.map { places.saved[$0].id }.forEach(places.remove) }
            Button { adding = true } label: { Label("Add a place", systemImage: "mappin.and.ellipse") }
            Toggle("Name towns from photo locations", isOn: $places.lookUpTowns)
            if places.naming { HStack { ProgressView(); Text("Naming towns…").foregroundStyle(.secondary) } }
        } header: {
            Text("Places")
        } footer: {
            Text("Add a home by its address (Grandma's house, say) and Home's Place filter shows every photo taken within about 650 feet of it. The address is looked up with Apple's location service. With naming towns on, towns like Gulf Shores, AL come from each photo's own location: Apple's location service gets a rough location (to about half a mile) for each area your photos are from, never the photos. Swipe left on a place to remove it.")
        }
        .sheet(isPresented: $adding) { AddPlaceSheet() }
    }
}

struct AddPlaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var busy = false
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (for example, Grandma's house)", text: $name).textInputAutocapitalization(.words)
                    TextField("Address", text: $address, axis: .vertical).textContentType(.fullStreetAddress)
                } footer: {
                    if let problem { Text(problem) }
                }
            }
            .navigationTitle("Add a place").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Save") {
                            busy = true
                            Task {
                                problem = await Shared.places.add(name: name, address: address)
                                busy = false
                                if problem == nil { dismiss() }
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
