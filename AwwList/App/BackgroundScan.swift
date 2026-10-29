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

    /// Last reason a background request didn't go through (shown on the scan banner).
    @MainActor static var lastError: String?
    @MainActor private static var continuedRunning = false

    /// Asks iOS to keep the running scan going after the app is left. Called from the button and automatically
    /// whenever the app starts to close mid-scan (it has to be asked while the app is still on screen).
    @discardableResult
    @MainActor static func continueInBackground() -> Bool {
        guard #available(iOS 26.0, *), Shared.scanner.isScanning, !taskOwnsScan, !continuedRunning else { return false }
        let req = BGContinuedProcessingTaskRequest(identifier: continuedID,
                                                   title: "Finding your cutest photos",
                                                   subtitle: "Scanning your library")
        req.strategy = .queue   // if iOS can't start it this second, it starts as soon as it can
        do {
            try BGTaskScheduler.shared.submit(req)
            continuedRunning = true
            // If iOS never gets to it before the scan ends, allow asking again for the next scan.
            Shared.scanner.whenFinished { if !taskOwnsScan { continuedRunning = false } }
            lastError = nil
            return true
        } catch {
            lastError = "iOS didn't allow background scanning just now (\(error.localizedDescription)). It'll pick up overnight while charging, or when you come back."
            return false
        }
    }

    @available(iOS 26.0, *)
    @MainActor private static func runContinued(_ task: BGContinuedProcessingTask) {
        let scanner = Shared.scanner
        let done = Once()
        taskOwnsScan = true
        continuedRunning = true
        if !scanner.isScanning { scanner.start(library: Shared.library) }
        // Progress is reported every second from the photo-by-photo count: iOS ends a continued task whose
        // progress stops moving, and the 50-photo batches (or one slow iCloud download) used to look like a stall.
        // A follow-up scan (photos added meanwhile) starts its count over, so totals are carried across.
        let ticker = Task { @MainActor in
            var base: Int64 = 0, lastLive: Int64 = 0, lastTotal: Int64 = 0
            while !Task.isCancelled && scanner.isScanning {
                let live = Int64(scanner.live.value), total = Int64(scanner.total)
                if live < lastLive { base += lastTotal }          // a new pass started
                lastLive = live; lastTotal = max(total, live)
                task.progress.totalUnitCount = max(1, base + lastTotal + 1)   // +1: finishing up still to come
                task.progress.completedUnitCount = min(base + live, task.progress.totalUnitCount - 1)
                task.updateTitle("Finding your cutest photos",
                                 subtitle: "\(live.formatted()) of \(total.formatted()) photos")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        func finish(_ ok: Bool) {
            if done.claim() { taskOwnsScan = false; continuedRunning = false; task.setTaskCompleted(success: ok) }
        }
        task.expirationHandler = {
            Task { @MainActor in
                ticker.cancel(); scanner.stop(); Shared.library.flush()
                finish(false)
            }
        }
        scanner.whenFinished {
            ticker.cancel()
            Shared.library.flush()
            task.progress.completedUnitCount = task.progress.totalUnitCount
            finish(true)
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
            // Runs on the main thread: queue the save, and end the task as soon as that write finishes.
            MainActor.assumeIsolated {
                if !taskOwnsScan { scanner.stop() }
                Shared.library.save { if done.claim() { UIApplication.shared.endBackgroundTask(id) } }
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
