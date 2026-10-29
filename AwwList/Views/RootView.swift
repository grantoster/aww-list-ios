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
                Label("Everything happens on this iPhone. Photos are never uploaded.", systemImage: "lock.fill")
                Label("Screenshots, bath and swim photos are left out.", systemImage: "eye.slash")
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
                Section("What's left out") {
                    Text("Screenshots, documents and photos without a child. Bath, pool, beach and swimwear photos, and every shot within 10 minutes of one. Shirtless kids past the baby stage (babies in a diaper are fine). Confident lake, ocean, river and sprinkler scenes. Photos that are clearly AI-generated (tagged by the AI tool, or saved from ChatGPT, Gemini and similar), retouched in face apps like FaceApp or Facetune or in Photoshop, or not made by a camera at all. Light edits in Photos, Lightroom or Snapseed, and AI clean-ups of real photos (removing a stranger in the background), are fine.")
                        .font(.footnote)
                }
                Section("How scores work") {
                    Text("Shots less than a minute apart (two at most) count as one moment, and only its best shot is ranked.")
                        .font(.footnote)
                    Text("Each photo gets points for the main child's expression (a smile counts most; a sleeping baby counts too), for a second person close by, for how big the face is in the frame, and for how clearly a child is the subject. Blur scales the total down, and crowds count a little less.")
                        .font(.footnote)
                    Text("Those points become 1–10 by rank across your whole library: the top 1% are 9s and 10s, the next 4% are 8s, the next 10% are 7s. Every year counts equally, so a huge year can't crowd out the others, and a photo needs real quality for a high score, not just being the best of a weak bunch.")
                        .font(.footnote)
                    Text("Photos are analyzed with Apple's on-device Vision framework. Nothing is uploaded.")
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
            Toggle("Also let Claude check possible swimwear or shirtless photos",
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
            Text("Optional. Your phone still checks every photo first; the photos you choose are then sent to Anthropic's Claude for the final 1–10 score, a description, and a second check for bath, swimwear, shirtless and AI or edited photos. Each year's top photos are chosen by Apple's score, plus up to a fifth more that Apple's check set aside (no child spotted, water scenes, and, only if you turn it on above, possible swimwear or shirtless), so Claude can decide; any Claude clears join the list when ranking by Claude. Photos Apple flags as possible bath or undressed are never sent. Photos are sent at 768 px without location or file details. Photos the phone's own check missed are sent too, so Claude can catch them. It uses your own API key from console.anthropic.com; charges go to your Anthropic account. When ranking by Claude, photos Claude hasn't seen are held at 6 or below.")
        }
    }
}

/// The app's learned score: what it picked up from Claude's scores, and how close it gets.
struct LearnedSection: View {
    @EnvironmentObject var library: Library
    var body: some View {
        Section {
            if let m = library.learned {
                LabeledContent("Learned from", value: "\(m.trainedOn.formatted()) Claude scores")
                let pct = { (v: Double) in "\(Int((v * 100).rounded(.toNearestOrAwayFromZero)))%" }
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
            if library.training { HStack { ProgressView(); Text("Learning…").foregroundStyle(.secondary) } }
        } header: {
            Text("Learned score")
        } footer: {
            Text("The app studies Claude's scores alongside what it measures on the phone (smiles, closeness, face size, sharpness and the scene), then predicts a Claude-style score for every photo, privately and for free. Its accuracy is checked on a fifth of Claude's scores it didn't learn from. Claude's own score always wins where it exists; with Rank by Claude, photos Claude hasn't seen use the learned score.")
        }
    }
}
