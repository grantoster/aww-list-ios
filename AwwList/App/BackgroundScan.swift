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

    /// A short record of what background scanning did (last 12 events), shown under Diagnostics, so it's clear
    /// whether iOS accepted the request, started it, and how it ended.
    static let logKey = "backgroundScanLog"
    static var log: [String] { UserDefaults.standard.stringArray(forKey: logKey) ?? [] }
    static func note(_ event: String) {
        let f = DateFormatter(); f.dateFormat = "MMM d h:mm:ss a"
        var l = log
        l.append("\(f.string(from: Date())): \(event)")
        UserDefaults.standard.set(Array(l.suffix(12)), forKey: logKey)
    }
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

    /// iOS often starts a background task by launching the app cold: wait until the saved library is read
    /// (a few seconds), ending the task cleanly if iOS wants the time back first.
    @MainActor private static func whenLibraryReady(_ task: BGTask, _ run: @escaping @MainActor () -> Void) -> Bool {
        if Shared.library.ready { return true }
        let gaveUp = Once()
        task.expirationHandler = { @Sendable in if gaveUp.claim() { task.setTaskCompleted(success: false) } }
        Shared.library.whenReady { if gaveUp.claim() { run() } }
        return false
    }

    @MainActor private static func runOvernight(_ task: BGTask) {
        scheduleOvernight()   // first, so the next night is asked for even if this one ends early
        guard whenLibraryReady(task, { runOvernight(task) }) else { return }
        note("Overnight scan started by iOS")
        guard hasAccess else { task.setTaskCompleted(success: true); return }
        let scanner = Shared.scanner
        let done = Once()
        taskOwnsScan = true
        // When iOS needs the time back: stop, save what's done, and report right away (not after the current photo).
        task.expirationHandler = {
            Task { @MainActor in
                note("Overnight scan stopped by iOS (\(scanner.done.formatted()) photos checked)")
                scanner.stop(); Shared.library.flush()
                if done.claim() { taskOwnsScan = false; task.setTaskCompleted(success: false) }
            }
        }
        scanner.start(library: Shared.library)
        scanner.whenFinished {
            Shared.library.flush()
            if done.claim() { note("Overnight scan finished"); taskOwnsScan = false; task.setTaskCompleted(success: true) }
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

    /// Once you've tapped "Keep scanning in the background" (or turned it on in Settings), later scans keep going
    /// on their own when you leave. It can be turned off in Settings.
    static let autoKey = "keepScanningWhenLeaving"
    @MainActor static var autoContinue: Bool { UserDefaults.standard.bool(forKey: autoKey) }
    @MainActor private static var continuedStarted = false
    @MainActor private static var watching = false

    /// Asks iOS to keep the running scan going after the app is left. Called from the button and automatically
    /// whenever the app starts to close mid-scan (it has to be asked while the app is still on screen).

    @discardableResult
    @MainActor static func continueInBackground(userTapped: Bool = false) -> Bool {
        guard #available(iOS 26.0, *), Shared.scanner.isScanning else { return false }
        if userTapped { UserDefaults.standard.set(true, forKey: autoKey) } else if !autoContinue { return false }
        if taskOwnsScan || continuedRunning { return true }    // already running or waiting to start
        let req = BGContinuedProcessingTaskRequest(identifier: continuedID,
                                                   title: "Finding your cutest photos",
                                                   subtitle: "Scanning your library")
        req.strategy = .queue   // if iOS can't start it this second, it starts as soon as it can
        do {
            try BGTaskScheduler.shared.submit(req)
            note(userTapped ? "Asked iOS to keep scanning (you tapped)" : "Asked iOS to keep scanning (leaving the app)")
            continuedRunning = true
            // If iOS never got to it before the scan ended, withdraw the request (so it can't start a scan out of the
            // blue later) and allow asking again for the next scan. One watcher at a time.
            guard !watching else { return true }
            watching = true
            Shared.scanner.whenFinished {
                watching = false
                // Only when the scan really finished: one stopped by the 30-second wrap-up is waiting for iOS to
                // take it over, so the request must stay in place.
                if !continuedStarted && !Shared.scanner.stoppedEarly {
                    note("iOS hadn't started background scanning before the scan ended")
                    continuedRunning = false
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedID)
                }
            }
            lastError = nil
            return true
        } catch {
            note("iOS refused background scanning: \(error.localizedDescription)")
            lastError = "iOS didn't allow background scanning just now (\(error.localizedDescription)). It'll pick up overnight while charging, or when you come back."
            return false
        }
    }

    /// Back in the app: a background request iOS never started is withdrawn, so leaving again can ask afresh.
    @MainActor static func appBecameActive() {
        guard #available(iOS 26.0, *), continuedRunning, !continuedStarted else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedID)
        continuedRunning = false
    }

    @available(iOS 26.0, *)
    @MainActor private static func runContinued(_ task: BGContinuedProcessingTask) {
        guard whenLibraryReady(task, { runContinued(task) }) else { return }
        note("iOS started background scanning")
        let scanner = Shared.scanner
        let done = Once()
        taskOwnsScan = true
        continuedRunning = true
        continuedStarted = true
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
            if done.claim() { taskOwnsScan = false; continuedRunning = false; continuedStarted = false; task.setTaskCompleted(success: ok) }
        }
        let expired = Once()
        task.expirationHandler = {
            Task { @MainActor in
                _ = expired.claim()
                note("iOS stopped background scanning (\(scanner.done.formatted()) photos checked)")
                ticker.cancel(); scanner.stop(); Shared.library.flush()
                finish(false)
            }
        }
        // If this task started just as the 30-second wrap-up was stopping the scan, that scan ends "stopped early":
        // start it again rather than reporting done with photos left (a few tries at most).
        var restarts = 0
        func attach() {
            scanner.whenFinished {
                if scanner.stoppedEarly && !expired.used && restarts < 3 {
                    restarts += 1
                    scanner.start(library: Shared.library)
                    attach()
                    return
                }
                ticker.cancel()
                Shared.library.flush()
                if !expired.used { note("Background scanning finished") }
                task.progress.completedUnitCount = task.progress.totalUnitCount
                finish(true)
            }
        }
        attach()
    }

    /// The ~30 seconds iOS allows after the app is closed: save, and let the current batch finish.
    /// Stays out of the way when a background task already owns the scan.
    @MainActor static func wrapUpAfterClosing() {
        Shared.library.flush()
        let scanner = Shared.scanner
        guard scanner.isScanning, !taskOwnsScan else { return }
        note("Left the app mid-scan: 30-second wrap-up" + (continuedRunning ? " (waiting for iOS to take over)" : ""))
        let done = Once()
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "Aww List scan") {
            // Runs on the main thread: end the task right away (iOS is waiting), then save in the background queue.
            // Runs on the main thread: queue the save, and end the task as soon as that write finishes.
            MainActor.assumeIsolated {
                // Waiting for iOS to start background scanning: leave the scan as it is (iOS pauses the app and the
                // background task carries on from there); otherwise stop it cleanly.
                if !taskOwnsScan && !continuedRunning { scanner.stop() }
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
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    var used: Bool { lock.lock(); defer { lock.unlock() }; return done }
}
