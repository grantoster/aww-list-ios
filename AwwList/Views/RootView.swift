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
    @AppStorage("askedForKey") private var askedForKey = false
    @State private var hadKey = Claude.apiKey != nil
    /// Set when you choose "score every photo" on that screen: Claude runs by itself once the first scan is done.
    @AppStorage("autoClaude") private var autoClaude = false
    @AppStorage("autoClaudeTries") private var autoTries = 0

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
        .onChange(of: phase) {
            if phase == .inactive && scanner.isScanning {
                // Leaving the app mid-scan: ask iOS to keep it going (it must be asked while still on screen).
                BackgroundScan.continueInBackground()
            }
            if phase == .active {
                status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status == .authorized || status == .limited { scanner.startIfNeeded(library: library) }
                if !library.claudeBatches.isEmpty { Task { await Shared.claude.collect(library) } }
                autoScore()
            } else if phase == .background {
                library.save()
                BackgroundScan.wrapUpAfterClosing()
                BackgroundScan.scheduleOvernight()
            }
        }
    }

    /// Sends the photos to Claude by itself after the first scan, when you chose that on the first screen. Same
    /// rules and checks as tapping Score with Claude (it only runs once the scan is finished). It runs once: it
    /// turns itself off after a pass that wasn't interrupted (or after 3 tries), so later photos are only sent
    /// when you tap Score with Claude.
    private func autoScore() {
        guard autoClaude, phase == .active, status == .authorized || status == .limited,
              !scanner.isScanning, !scanner.needsScan, !claude.busy, !library.photos.isEmpty,
              Claude.apiKey != nil else { return }
        Task {
            await claude.send(library)
            switch claude.lastOutcome {
            case .notStarted: break                       // something else was sending, or new photos to check first
            case .done, .keyRejected: autoClaude = false   // one full pass (later photos are sent when you tap Score)
            case .paused, .retryLater:
                autoTries += 1
                if autoTries >= 3 { autoClaude = false }
            }
        }
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
            Image("BrandMark").resizable().scaledToFit().frame(width: 150, height: 150).accessibilityHidden(true)
            Text("awwbum").font(Theme.display(44, relativeTo: .largeTitle)).foregroundStyle(Theme.accent)
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
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ClaudeSection()
                LearnedSection()
                BirthdaysSection()
                DiagnosticsSection()
                Section("Library") {
                    LabeledContent("Photos checked", value: library.photos.count.formatted())
                    LabeledContent("Moments ranked", value: library.everyMoment.count.formatted())
                    if !library.hidden.isEmpty {
                        Button("Put back \(library.hidden.count) removed photos") { library.restoreHidden() }
                    }
                    Button(scanner.isScanning ? "Scanning…" : "Rescan, including photos that couldn't load") { scanner.start(library: library, retryUnavailable: true) }
                        .disabled(scanner.isScanning)
                    if BackgroundScan.canContinueInBackground {
                        Toggle("Keep scanning when I leave the app", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: BackgroundScan.autoKey) },
                            set: { UserDefaults.standard.set($0, forKey: BackgroundScan.autoKey); keepTick += 1 }))
                            .id(keepTick)
                    }
                }
                HeldBackSection()
                Section("What's left out") {
                    LabeledContent("On the list", value: "\(library.listedPhotos.formatted()) photos")
                    ForEach(library.leftOut, id: \.reason) { row in
                        LabeledContent(row.reason, value: row.count.formatted())
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
                Section("How scores work") {
                    Text("Shots less than a minute apart (two at most) count as one moment, and only its best shot is ranked.")
                        .font(.footnote)
                    Text("Each photo gets points for the main child's expression (25%: a laugh beats a smile, and a sleeping baby counts too), eyes open and looking at the camera (10%), photo quality from Apple's quality score and sharpness (15%), how big the child is in the frame (10%), how clearly a child is the subject (10%), action and play (5%), a special moment or outing like a birthday cake, costume, snow or the zoo (5%), pure \"aww\" like a sleeping baby (5%), pure joy like a real laugh or arms up (5%), candid moments caught mid-action or looking away (5%), and the best smile, grin or mischief, a big grin or a cheeky smirk (5%). A second person earns nothing extra, and crowds count a little less.")
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
    @State private var key = ""
    @State private var hasKey = Claude.apiKey != nil
    @State private var agreed = false
    @AppStorage("autoClaude") private var autoClaude = false

    var body: some View {
        Section {
            if hasKey {
                LabeledContent("API key", value: "Saved on this iPhone")
                Button("Remove key", role: .destructive) { Claude.apiKey = nil; hasKey = false }
            } else {
                SecureField("Paste your Claude API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save key") { Claude.apiKey = key; key = ""; hasKey = Claude.apiKey != nil }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Model", selection: Binding(get: { library.claudeModel }, set: { library.setClaude(model: $0) })) {
                ForEach(Claude.models, id: \.id) { m in Text(m.name).tag(m.id) }
            }
            Picker("Photos to send", selection: Binding(get: { library.claudeScope }, set: { library.setClaude(scope: $0) })) {
                ForEach(Claude.scopes, id: \.n) { s in Text(s.name).tag(s.n) }
            }
            let n = claude.candidates(library).count
            LabeledContent("Not sent yet", value: n == 0 ? "None" : "\(n.formatted()) photos")
            if !library.claudeBatches.isEmpty {
                LabeledContent("Being scored", value: "\(library.claudeBatches.reduce(0) { $0 + $1.photos.count }.formatted()) photos")
            }
            if n > 0 {
                Text("Estimated cost: about \(Claude.dollars(micros: Claude.costMicros(photos: n, model: library.claudeModel))) at batch prices. This is an estimate (about 1,200 tokens in and about 300 out a photo); your Anthropic bill shows the actual.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if hasKey {
                Button("Test connection") { Task { await claude.testConnection() } }.disabled(claude.busy)
            }
            Toggle("Also send possible swimwear or shirtless photos",
                   isOn: Binding(get: { library.claudeSensitive }, set: { library.setClaudeSensitive($0) }))
            if autoClaude {
                // The automatic first scoring chosen on the first screen; it can be turned off here (not back on).
                Toggle("Automatic first scoring (runs once the scan finishes)", isOn: $autoClaude)
            }
            Toggle("Send these photos to Claude", isOn: $agreed)
            Button(claude.busy ? "Working…" : scanner.isScanning ? "Score with Claude (after the scan)" : "Score with Claude") { Task { await claude.send(library) } }
                .disabled(!hasKey || !agreed || claude.busy || n == 0 || scanner.isScanning)
            let rc = claude.recheckCandidates(library).count
            if library.claudeScored > 0 {
                Button("Check Claude's consistency (re-score \(rc.formatted()) photos, about \(Claude.dollars(micros: Claude.costMicros(photos: rc, model: library.claudeModel))))") {
                    Task { await claude.send(library, recheck: true) }
                }
                .disabled(!hasKey || !agreed || claude.busy || rc == 0 || scanner.isScanning)
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
                Button("Go back to on-device scores only", role: .destructive) { library.clearClaude() }
                    .disabled(claude.busy || !library.claudeBatches.isEmpty)   // not while photos are out being scored
            }
        } header: {
            Text("Score with Claude")
        } footer: {
            Text("Optional. Claude decides what comes off the list. Your phone scores every photo first and only flags what it isn't sure about (no child spotted, water, swimwear, shirtless, AI or edited files); flagged photos stay listed. Each year's best photos, flagged or not, plus a spread of lower-ranked ones and photos with faces but no child label, are sent to Anthropic's Claude for the final 1–10 score, a description, and the call on whether a photo belongs (bath, swimwear, shirtless, AI or edited, no child). Photos flagged as possible bath or undressed (by Apple's check or Claude's), and every shot within 10 minutes of one, are never sent, even if you put them back. The check is automatic and can miss some photos. Right before sending, the phone re-reads every photo taken within 10 minutes of each one; if any isn't checked yet (still downloading from iCloud, or new), it waits. With Limited photo access, photos outside your selection can't be checked. Possible swimwear and shirtless photos (and the shots right around them) are sent only if you turn that on above; otherwise they stay listed and Claude just doesn't see them. Photos are sent at most 768 pixels on the long side, without location or file details. It uses your own API key from console.anthropic.com; charges go to your Anthropic account. Anthropic's terms say it doesn't train on what's sent; it normally deletes it within 29–30 days, and can keep anything its safety checks flag for up to 2 years. When ranking by Claude, photos Claude hasn't seen are held at 6 or below (8 or below once there's a learned score).")
        }
    }
}

/// The app's learned score: what it picked up from Claude's scores, and how close it gets.
struct LearnedSection: View {
    @EnvironmentObject var library: Library
    @State private var copied = false
    var body: some View {
        Section {
            if let m = library.learned {
                LabeledContent("Learned from", value: "\(m.trainedOn.formatted()) Claude scores")
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
                     : library.rankBy == "apple"
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
            if library.training { HStack { ProgressView(); Text("Learning…").foregroundStyle(.secondary) } }
        } header: {
            Text("Learned score")
        } footer: {
            Text("The app studies Claude's scores alongside what it measures on the phone (smiles, closeness, face size, sharpness and the scene), then predicts a Claude-style score for every photo, privately and for free. It also learns which photos Claude takes off the list, so removals follow Claude's judgment instead of Apple's. Both are checked on a fifth of Claude's verdicts it didn't learn from. Claude's own score and removals always win where they exist; with Rank by Claude, photos Claude hasn't seen use the learned score.")
        }
    }
}

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

/// Shown the first time the app opens: add a Claude API key, and choose to have every photo scored automatically.
struct KeySetupView: View {
    let hadKey: Bool
    @EnvironmentObject var library: Library
    @AppStorage("autoClaude") private var autoClaude = false
    @State private var key = ""
    @State private var scoreAll = true
    @State private var failed = false
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("BrandMark").resizable().scaledToFit().frame(width: 96, height: 96).accessibilityHidden(true)
                Text("awwbum").font(Theme.display(40, relativeTo: .largeTitle)).foregroundStyle(Theme.accent)
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
                Text("Estimated cost with \(Claude.models.first { $0.id == library.claudeModel }?.name ?? "the chosen model"): about \(Claude.dollars(micros: Claude.costMicros(photos: 1_000, model: library.claudeModel))) per 1,000 photos at batch prices (an estimate; your Anthropic bill shows the actual). Photos are sent at most 768 pixels on the long side, without location or file details. You can change all of this in Settings.")
                    .font(.footnote).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    Label("The bath filter can miss photos", systemImage: "exclamationmark.triangle").font(.subheadline.bold())
                    Text("Awwbum holds back photos it thinks may show a child in the bath or undressed, and every shot within 10 minutes of one. It's an automatic guess, not a guarantee, so some of those photos could still be sent to Claude. If that's a worry, turn off scoring every photo above and send fewer photos from Settings, or skip Claude scoring.")
                    Text("Photos you send go to Anthropic (the company behind Claude), including other people and other families' kids in them. Anthropic's terms say it doesn't train its models on them. It normally deletes them within 30 days (batch jobs, which Awwbum uses, within 29 days), but can keep anything its safety checks flag for up to 2 years.")
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
            Image("BrandMark").resizable().scaledToFit().frame(width: 96, height: 96).accessibilityHidden(true)
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
            Button(copied ? "Copied" : "Copy diagnostics") {
                library.noteMemory()
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                UIPasteboard.general.string = (["Awwbum build \(build)"] + library.diagnostics.map { "\($0.label): \($0.value)" })
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
