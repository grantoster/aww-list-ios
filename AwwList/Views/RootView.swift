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
                    .onAppear { scanner.start(library: library) }
            case .denied, .restricted:
                DeniedView()
            default:
                WelcomeView { request() }
            }
        }
        .onChange(of: phase) {
            if phase == .active {
                status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status == .authorized || status == .limited { scanner.start(library: library) }
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
        VStack(spacing: 20) {
            Spacer()
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
            Spacer()
            Button(action: onStart) {
                Text("Choose photos to scan").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            Text("For the full list, allow access to all photos.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
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
                Section("Library") {
                    LabeledContent("Photos checked", value: library.photos.count.formatted())
                    LabeledContent("Moments ranked", value: library.moments.count.formatted())
                    if !library.hidden.isEmpty {
                        Button("Put back \(library.hidden.count) removed photos") { library.restoreHidden() }
                    }
                    Button(scanner.isScanning ? "Scanning…" : "Scan for new photos") { scanner.start(library: library) }
                        .disabled(scanner.isScanning)
                }
                Section("How scores work") {
                    Text("Each photo with a child in it gets a cuteness score from smiles, faces together, how big and sharp the faces are, and how clearly a child is the subject. Scores are spread across your whole library, so 9s and 10s stay rare and every year competes on the same scale.")
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
