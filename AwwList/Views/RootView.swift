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
            } else if phase == .background {
                library.save()
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
    @EnvironmentObject var library: Library
    @State private var dates: [Date] = []
    var body: some View {
        Section {
            ForEach(dates.indices, id: \.self) { i in
                DatePicker("Child \(i + 1)", selection: Binding(get: { dates[i] }, set: { dates[i] = $0; library.setBirthdays(dates) }),
                           in: ...Date(), displayedComponents: .date)
            }
            .onDelete { dates.remove(atOffsets: $0); library.setBirthdays(dates) }
            Button("Add a child's birthday") {
                dates.append(Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date())
                library.setBirthdays(dates)
            }
        } header: {
            Text("Your kids' birthdays")
        } footer: {
            Text("Used only on this iPhone to sort photos into Baby (under 1), Toddler (1–3) and Kid (4 and up). Swipe left to remove one.")
        }
        .onAppear { dates = library.birthdays }
    }
}
