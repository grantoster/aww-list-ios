import SwiftUI
import Photos

/// Asks for photo access the first time, then shows the list and keeps the scan going.
struct RootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var scanner: PhotoScanner
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
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
        .onChange(of: phase) {
            if phase == .inactive && scanner.isScanning {
                // Leaving the app mid-scan: ask iOS to keep it going (it must be asked while still on screen).
                BackgroundScan.continueInBackground()
            }
            if phase == .active {
                status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status == .authorized || status == .limited { scanner.startIfNeeded(library: library) }
                if !library.claudeBatches.isEmpty { Task { await Shared.claude.collect(library) } }
            } else if phase == .background {
                library.save()
                BackgroundScan.wrapUpAfterClosing()
                BackgroundScan.scheduleOvernight()
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
            Image(systemName: "heart.text.square.fill").font(.system(size: 72)).foregroundStyle(Theme.accent)
            Text("Aww List").font(Theme.display(40))
            Text("Finds the cutest photos of your kids and ranks them, year by year.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("Scoring happens on this iPhone. Photos are only uploaded if you choose to score them with Claude.", systemImage: "lock.fill")
                Label("Read only: it never changes or deletes anything in your library.", systemImage: "hand.raised")
                Label("Screenshots and possible bath photos are left out.", systemImage: "eye.slash")
                Label("Bursts count as one moment, using the best shot.", systemImage: "square.stack")
            }
            .font(.subheadline).padding().background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 0)
            Button(action: onStart) {
                Text("Choose photos to scan").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            Text("For the full list, allow access to all photos.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minHeight: geo.size.height)   // fills the screen, and scrolls when text is large
        }
        }
    }
}

struct DeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Photo access is off", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("Aww List needs to look at your photos to rank them. Turn on access in Settings → Aww List → Photos.")
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
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ClaudeSection()
                LearnedSection()
                BirthdaysSection()
                Section("Library") {
                    LabeledContent("Photos checked", value: library.photos.count.formatted())
                    LabeledContent("Moments ranked", value: library.moments.count.formatted())
                    if !library.hidden.isEmpty {
                        Button("Put back \(library.hidden.count) removed photos") { library.restoreHidden() }
                    }
                    Button(scanner.isScanning ? "Scanning…" : "Rescan, including photos that couldn't load") { scanner.start(library: library, retryUnavailable: true) }
                        .disabled(scanner.isScanning)
                }
                HeldBackSection()
                Section("What's left out") {
                    Text("On the phone: screenshots, documents, photos with no sign of a child at all, and possible bath or undressed photos plus every shot within 10 minutes of one. You can put a held-back photo itself back above; the shots around it then come back too, but none of them is ever sent to Claude.")
                        .font(.footnote)
                    Text("Everything else Apple isn't sure about stays on the list with a flag: no child spotted, water scenes, swimwear, shirtless, and files that look AI-generated, face-retouched or not from a camera. Claude makes the call on those, and once the app has learned from Claude's calls, it hides the ones it expects Claude would remove when ranking by Claude or by the learned score. Ranking by Apple shows them all.")
                        .font(.footnote)
                    Text("Aww List only reads your photo library. It never changes, adds to or deletes anything in it; Remove from list only hides a photo inside this app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("How scores work") {
                    Text("Shots less than a minute apart (two at most) count as one moment, and only its best shot is ranked.")
                        .font(.footnote)
                    Text("Each photo gets points for the main child's expression (a smile counts most; a sleeping baby counts too), for a second person close by, for how big the face is in the frame, and for how clearly a child is the subject. Blur scales the total down, and crowds count a little less.")
                        .font(.footnote)
                    Text("Those points become 1–10 by rank across your whole library: the top 1% are 9s and 10s, the next 4% are 8s, the next 10% are 7s. Every year counts equally, so a huge year can't crowd out the others, and a photo needs real quality for a high score, not just being the best of a weak bunch.")
                        .font(.footnote)
                    Text("Photos are analyzed with Apple's on-device Vision framework. Nothing is uploaded unless you score with Claude.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
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
    @State private var key = ""
    @State private var hasKey = Claude.apiKey != nil
    @State private var agreed = false

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
            Toggle("Send these photos to Claude", isOn: $agreed)
            Button(claude.busy ? "Working…" : "Score with Claude") { Task { await claude.send(library) } }
                .disabled(!hasKey || !agreed || claude.busy || n == 0)
            if !library.claudeBatches.isEmpty {
                Button("Check for Claude's scores") { Task { await claude.collect(library) } }.disabled(claude.busy)
            }
            if !claude.status.isEmpty { Text(claude.status).font(.footnote).foregroundStyle(.secondary) }
            if library.claudeScored > 0 {
                LabeledContent("Scored by Claude", value: library.claudeScored.formatted())
                Button("Go back to on-device scores only", role: .destructive) { library.clearClaude() }
            }
        } header: {
            Text("Score with Claude")
        } footer: {
            Text("Optional. Claude decides what comes off the list. Your phone scores every photo first and only flags what it isn't sure about (no child spotted, water, swimwear, shirtless, AI or edited files); flagged photos stay listed. Each year's best photos, flagged or not, are sent to Anthropic's Claude for the final 1–10 score, a description, and the call on whether a photo belongs (bath, swimwear, shirtless, AI or edited, no child). Possible bath or undressed photos, and every shot within 10 minutes of one, are never sent, even if you put them back. Possible swimwear and shirtless photos (and the shots right around them) are sent only if you turn that on above; otherwise they stay listed and Claude just doesn't see them. Photos are sent at 768 px without location or file details. It uses your own API key from console.anthropic.com; charges go to your Anthropic account. When ranking by Claude, photos Claude hasn't seen are held at 6 or below (8 or below once there's a learned score).")
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
                     ? "Checked on \(f.tested.formatted()) photos from days it didn't learn from. It hides photos only when ranking by Claude or by the learned score; ranking by Apple shows everything."
                     : "Checked on \(f.tested.formatted()) photos from days it didn't learn from. It's hiding \(library.filteredOut.formatted()) photos Claude hasn't seen.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if library.learned != nil {
                Text("Learning Claude's removals starts once Claude has removed at least \(Learner.minimumRemovals) photos (from enough days to test it fairly).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if library.learnedIsBuiltIn || library.filterIsBuiltIn {
                Text("Using the learning built into the app for now. Your own Claude scores take over once there are enough of them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let text = library.learningText {
                Button(copied ? "Copied" : "Copy learning") {
                    UIPasteboard.general.string = text
                    copied = true
                }
                Text("Copies this phone's learning (numbers only, no photos) so it can be built into the app as the starting point for new installs.")
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
                Text("Held back for privacy")
            } footer: {
                Text("Apple's check thinks these may be bath or undressed photos. They stay off the list unless you put them back, and they're never sent to Claude either way.")
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
                    let back = library.putBack.contains(p.id)
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
        .navigationTitle("Held back")
    }
}
