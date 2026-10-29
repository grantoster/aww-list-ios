import Foundation
import BackgroundTasks
import Photos
import UIKit

/// The one library and scanner, shared by the app and its background tasks.
@MainActor
enum Shared {
    static let library = Library()
    static let scanner = PhotoScanner()
}

/// Keeps the scan going when the app isn't open:
/// - after you leave the app, iOS gives it about 30 seconds to wrap up;
/// - iOS 26 and later: a scan you started keeps running in the background, with its progress shown by
///   the system, until it finishes (or iOS needs the resources back);
/// - overnight: iOS runs the scan while the phone is charging and idle, so new photos are ranked by morning.
enum BackgroundScan {
    static var bundle: String { Bundle.main.bundleIdentifier ?? "com.awwlist.app" }
    static var overnightID: String { bundle + ".scan" }
    static var continuedID: String { bundle + ".continued.scan" }

    /// Called once at launch, before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: overnightID, using: nil) { task in
            Task { @MainActor in runOvernight(task) }
        }
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedID, using: nil) { task in
                Task { @MainActor in
                    if let t = task as? BGContinuedProcessingTask { runContinued(t) } else { task.setTaskCompleted(success: false) }
                }
            }
        }
    }

    private static var hasAccess: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    /// Asks iOS for an overnight run (charging, idle). Safe to call often.
    static func scheduleOvernight() {
        let req = BGProcessingTaskRequest(identifier: overnightID)
        req.requiresExternalPower = true
        req.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(req)
    }

    @MainActor private static func runOvernight(_ task: BGTask) {
        scheduleOvernight()
        guard hasAccess else { task.setTaskCompleted(success: true); return }
        let scanner = Shared.scanner
        task.expirationHandler = { Task { @MainActor in scanner.stop() } }
        scanner.start(library: Shared.library)
        scanner.whenFinished { task.setTaskCompleted(success: true) }
    }

    /// iOS 26+: lets a running scan continue after the app is closed, with system progress.
    /// Started while the app is open (the scan you kicked off by opening it); does nothing on older iOS.
    @MainActor static func continueInBackground() {
        guard #available(iOS 26.0, *), Shared.scanner.isScanning else { return }
        let req = BGContinuedProcessingTaskRequest(identifier: continuedID,
                                                   title: "Finding your cutest photos",
                                                   subtitle: "Scanning your library")
        req.strategy = .fail
        try? BGTaskScheduler.shared.submit(req)
    }

    @available(iOS 26.0, *)
    @MainActor private static func runContinued(_ task: BGContinuedProcessingTask) {
        let scanner = Shared.scanner
        if !scanner.isScanning { scanner.start(library: Shared.library) }
        task.expirationHandler = { Task { @MainActor in scanner.stop() } }
        let ticker = Task { @MainActor in
            while !Task.isCancelled && scanner.isScanning {
                task.progress.totalUnitCount = Int64(max(1, scanner.total))
                task.progress.completedUnitCount = Int64(min(scanner.done, max(1, scanner.total)))
                task.updateTitle("Finding your cutest photos",
                                 subtitle: "\(scanner.done.formatted()) of \(scanner.total.formatted()) photos")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        scanner.whenFinished {
            ticker.cancel()
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
        }
    }

    /// The ~30 seconds iOS allows after the app is closed: let the current batch finish and save.
    @MainActor static func wrapUpAfterClosing() {
        let scanner = Shared.scanner
        guard scanner.isScanning else { return }
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "Aww List scan") {
            scanner.stop()
            UIApplication.shared.endBackgroundTask(id)
        }
        scanner.whenFinished { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
    }
}
