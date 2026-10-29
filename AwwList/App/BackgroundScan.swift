import Foundation
import BackgroundTasks
import Photos
import UIKit

/// The one library and scanner, shared by the app and its background tasks.
@MainActor
enum Shared {
    static let library = Library()
    static let scanner = PhotoScanner()
    static let claude = ClaudeService()
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

    /// True while an overnight or continued background task owns the scan (the 30-second wrap-up then stays out of it).
    @MainActor static var taskOwnsScan = false

    @MainActor private static func runOvernight(_ task: BGTask) {
        scheduleOvernight()
        guard hasAccess else { task.setTaskCompleted(success: true); return }
        let scanner = Shared.scanner
        let done = Once()
        taskOwnsScan = true
        // When iOS needs the time back: stop, save what's done, and report right away (not after the current photo).
        task.expirationHandler = {
            Task { @MainActor in
                scanner.stop(); Shared.library.flush()
                if done.claim() { taskOwnsScan = false; task.setTaskCompleted(success: false) }
            }
        }
        scanner.start(library: Shared.library)
        scanner.whenFinished {
            Shared.library.flush()
            if done.claim() { taskOwnsScan = false; task.setTaskCompleted(success: true) }
        }
    }

    /// iOS 26+: when you tap "Keep scanning in the background", the running scan continues after you leave the app,
    /// with its progress shown by iOS. Does nothing on older iOS or when nothing is scanning.
    static var canContinueInBackground: Bool {
        if #available(iOS 26.0, *) { return true } else { return false }
    }

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
        let done = Once()
        taskOwnsScan = true
        if !scanner.isScanning { scanner.start(library: Shared.library) }
        let ticker = Task { @MainActor in
            var shown: Int64 = 0
            while !Task.isCancelled && scanner.isScanning {
                task.progress.totalUnitCount = Int64(max(1, scanner.total))
                shown = max(shown, Int64(min(scanner.done, max(1, scanner.total))))   // never goes backwards
                task.progress.completedUnitCount = shown
                task.updateTitle("Finding your cutest photos",
                                 subtitle: "\(scanner.done.formatted()) of \(scanner.total.formatted()) photos")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        task.expirationHandler = {
            Task { @MainActor in
                ticker.cancel(); scanner.stop(); Shared.library.flush()
                if done.claim() { taskOwnsScan = false; task.setTaskCompleted(success: false) }
            }
        }
        scanner.whenFinished {
            ticker.cancel()
            Shared.library.flush()
            task.progress.completedUnitCount = task.progress.totalUnitCount
            if done.claim() { taskOwnsScan = false; task.setTaskCompleted(success: true) }
        }
    }

    /// The ~30 seconds iOS allows after the app is closed: save, and let the current batch finish.
    /// Stays out of the way when a background task already owns the scan.
    @MainActor static func wrapUpAfterClosing() {
        Shared.library.flush()
        let scanner = Shared.scanner
        guard scanner.isScanning, !taskOwnsScan else { return }
        let done = Once()
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "Aww List scan") {
            // Runs on the main thread: end the task right away (iOS is waiting), then save in the background queue.
            MainActor.assumeIsolated {
                if !taskOwnsScan { scanner.stop() }
                if done.claim() { UIApplication.shared.endBackgroundTask(id) }
                Shared.library.save()
            }
        }
        scanner.whenFinished {
            Shared.library.flush()
            if id != .invalid, done.claim() { UIApplication.shared.endBackgroundTask(id) }
        }
    }
}

/// True the first time `claim()` is called, false after; so a task is completed exactly once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
