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
    static let plus = PlusStore()
    static let places = PlaceBook()
    /// Who's Who (people, tags, face learning): the one thing Awwbum and AwwSnap share.
    static let who = WhoStore()
    /// AwwSnap's own library, scanner and Claude (made the first time AwwSnap is opened).
    static let snapLibrary = Library(mode: .snap)
    static let snapScanner = PhotoScanner(mode: .snap)
    static let snapClaude = ClaudeService(mode: .snap)

    static func library(_ m: AppMode) -> Library { m == .snap ? snapLibrary : library }
    static func scanner(_ m: AppMode) -> PhotoScanner { m == .snap ? snapScanner : scanner }
    static func claude(_ m: AppMode) -> ClaudeService { m == .snap ? snapClaude : claude }
    /// True once AwwSnap has been opened (so its library is in memory and should follow shared changes too).
    static var snapOpened = false
    /// Saved places or town names changed: both apps' lists follow.
    static func placesChanged() {
        library.placesChanged()
        if snapOpened { snapLibrary.placesChanged() }
    }
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
    /// AwwSnap's background events aren't recorded: this log goes into Awwbum's diagnostics and feedback.
    @MainActor static func note(_ event: String, mode: AppMode) { if mode == .aww { note(event) } }
    static func note(_ event: String) {
        let f = DateFormatter(); f.dateFormat = "MMM d h:mm:ss a"
        var l = log
        l.append("\(f.string(from: Date())): \(event)")
        UserDefaults.standard.set(Array(l.suffix(12)), forKey: logKey)
    }
    static var overnightID: String { bundle + ".scan" }
    static var continuedID: String { bundle + ".continued.scan" }
    static var resultsID: String { bundle + ".claude-results" }

    /// While photos are with Claude: ask iOS to wake the app now and then to collect the scores (a quick check, so
    /// "Claude scored your photos" can arrive while the app is closed). Asked again after each check while any wait.
    @MainActor static func scheduleResultsCheck() {
        guard !Shared.library.claudeBatches.isEmpty || (Shared.snapOpened && !Shared.snapLibrary.claudeBatches.isEmpty) else { return }
        let req = BGAppRefreshTaskRequest(identifier: resultsID)
        req.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
    @MainActor private static func runResultsCheck(_ task: BGAppRefreshTask) {
        guard whenLibraryReady(task, .aww, { runResultsCheck(task) }) else { return }
        let work = Task { @MainActor in
            await Shared.claude(.aww).collect(Shared.library)
            if Shared.snapOpened { await Shared.claude(.snap).collect(Shared.snapLibrary) }
            Shared.library.flush()
            if Shared.snapOpened { Shared.snapLibrary.flush() }
            scheduleResultsCheck()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Called once at launch, before the app finishes launching.
    static func register() {
        // Scans measure on the CPU while the app is in the background (no GPU there).
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in Analyzer.inBackground.set(true) }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in Analyzer.inBackground.set(false) }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in Analyzer.inBackground.set(false) }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: resultsID, using: nil) { task in
            Task { @MainActor in
                if let t = task as? BGAppRefreshTask { runResultsCheck(t) } else { task.setTaskCompleted(success: false) }
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: overnightID, using: nil) { task in
            Analyzer.inBackground.set(true)   // launched straight into the background: no notification says so
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
        // Wi-Fi or cellular only matters when Claude scoring is set to keep going (it scores after the photo check).
        req.requiresNetworkConnectivity = AppMode.allCases.contains { UserDefaults.standard.bool(forKey: $0.key("autoClaude")) }
        try? BGTaskScheduler.shared.submit(req)
    }

    /// True while an overnight or continued background task owns the scan (the 30-second wrap-up then stays out of it).
    @MainActor static var taskOwnsScan = false

    /// iOS often starts a background task by launching the app cold: wait until the saved library is read
    /// (a few seconds), ending the task cleanly if iOS wants the time back first.
    @MainActor private static func whenLibraryReady(_ task: BGTask, _ m: AppMode = .aww, _ run: @escaping @MainActor () -> Void) -> Bool {
        let lib = Shared.library(m)
        if lib.ready && Shared.library.ready { return true }   // AwwSnap also needs Awwbum's (shared Who's Who)
        let gaveUp = Once()
        task.expirationHandler = { @Sendable in if gaveUp.claim() { task.setTaskCompleted(success: false) } }
        let notReady = lib.ready ? Shared.library : lib
        notReady.whenReady { if gaveUp.claim() { run() } }
        return false
    }

    /// The app the background work is for (the one that was open when it was asked for).
    @MainActor private static var workMode: AppMode = .aww
    private static let workModeKey = "backgroundWorkMode"

    @MainActor private static func runOvernight(_ task: BGTask) {
        scheduleOvernight()   // first, so the next night is asked for even if this one ends early
        // The app last open (iOS may launch it cold for this): Awwbum or AwwSnap.
        let m = AppMode(rawValue: UserDefaults.standard.string(forKey: workModeKey) ?? "") ?? .aww
        if m == .snap { Shared.snapOpened = true }
        guard whenLibraryReady(task, m, { runOvernight(task) }) else { return }
        note("Overnight run started by iOS", mode: m)
        guard hasAccess else { task.setTaskCompleted(success: true); return }
        // Background work already running (started from the app): that run carries on; this one isn't needed.
        guard !taskOwnsScan else { note("Overnight run skipped: background work already running", mode: m); task.setTaskCompleted(success: true); return }
        workMode = m
        taskOwnsScan = true
        let done = Once()
        let work = Work(mode: m)
        // When iOS needs the time back: stop, save what's done, and report right away (not after the current photo).
        task.expirationHandler = {
            Task { @MainActor in
                note("Overnight run stopped by iOS (\(Shared.scanner(m).done.formatted()) photos checked)", mode: m)
                work.stop()
                if done.claim() { taskOwnsScan = false; task.setTaskCompleted(success: false) }
            }
        }
        work.run(progress: nil) {
            if done.claim() { note("Overnight run finished", mode: m); taskOwnsScan = false; task.setTaskCompleted(success: true) }
        }
    }

    /// iOS 26+: checking photos and Claude scoring carry on after you leave the app, with their progress shown by
    /// iOS, until they finish or iOS needs the resources back. Asked for by itself as soon as either starts while
    /// the app is open (iOS only takes these requests from an app on screen).
    static var canContinueInBackground: Bool {
        if #available(iOS 26.0, *) { return true } else { return false }
    }

    /// Last reason a background request didn't go through (shown on the scan banner).
    @MainActor static var lastError: String?
    @MainActor private static var continuedRunning = false
    @MainActor private static var continuedStarted = false

    /// Asks iOS to keep this app's photo check and Claude scoring going after you leave. Safe to call often: it
    /// does nothing when there's nothing to do or a request is already in. Must be called while the app is on screen.
    @discardableResult
    @MainActor static func keepWorking(_ m: AppMode) -> Bool {
        UserDefaults.standard.set(m.rawValue, forKey: workModeKey)   // the overnight run follows the app you use
        // Not in Low Power Mode: it picks up overnight while charging instead.
        guard #available(iOS 26.0, *), Work.hasWork(m), !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        if taskOwnsScan || continuedRunning { return true }    // already running or waiting to start
        workMode = m
        let req = BGContinuedProcessingTaskRequest(identifier: continuedID,
                                                   title: "Finding your best photos",
                                                   subtitle: "Checking your photos")
        req.strategy = .queue   // if iOS can't start it this second, it starts as soon as it can
        do {
            try BGTaskScheduler.shared.submit(req)
            note("Asked iOS to keep working in the background", mode: m)
            continuedRunning = true
            lastError = nil
            return true
        } catch {
            note("iOS refused background work: \(error.localizedDescription)", mode: m)
            lastError = "iOS didn't allow background work just now (\(error.localizedDescription)). It picks up overnight while charging, or when you come back."
            return false
        }
    }

    /// Back in the app: a background request iOS never started is withdrawn, so it can be asked afresh.
    @MainActor static func appBecameActive() {
        guard #available(iOS 26.0, *), continuedRunning, !continuedStarted else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedID)
        continuedRunning = false
    }

    @available(iOS 26.0, *)
    @MainActor private static func runContinued(_ task: BGContinuedProcessingTask) {
        let m = workMode
        guard whenLibraryReady(task, m, { runContinued(task) }) else { return }
        // The overnight run is already doing this work: nothing to add.
        guard !taskOwnsScan else { continuedRunning = false; task.setTaskCompleted(success: true); return }
        note("iOS started background work", mode: m)
        let done = Once()
        taskOwnsScan = true
        continuedRunning = true
        continuedStarted = true
        let work = Work(mode: m)
        func finish(_ ok: Bool) {
            if done.claim() { taskOwnsScan = false; continuedRunning = false; continuedStarted = false; task.setTaskCompleted(success: ok) }
        }
        task.expirationHandler = {
            Task { @MainActor in
                note("iOS stopped background work (\(Shared.scanner(m).done.formatted()) photos checked, \(Shared.claude(m).sent.formatted()) sent to Claude)", mode: m)
                work.stop()
                finish(false)
            }
        }
        work.run(progress: { done, total, subtitle in
            task.progress.totalUnitCount = max(1, total + 1)   // +1: finishing up still to come
            task.progress.completedUnitCount = min(done, task.progress.totalUnitCount - 1)
            task.updateTitle("Finding your best photos", subtitle: subtitle)
        }) {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            note("Background work finished", mode: m)
            finish(true)
        }
    }

    /// The ~30 seconds iOS allows after the app is closed: save, and let the current batch finish.
    /// Stays out of the way when a background task already owns the work (or iOS is about to start one).
    @MainActor static func wrapUpAfterClosing(_ m: AppMode) {
        Shared.library.flush()
        if m == .snap { Shared.snapLibrary.flush() }
        scheduleResultsCheck()
        let scanner = Shared.scanner(m)
        guard scanner.isScanning, !taskOwnsScan else { return }
        note("Left the app mid-scan: 30-second wrap-up" + (continuedRunning ? " (waiting for iOS to take over)" : ""), mode: m)
        let done = Once()
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "Aww List scan") {
            // Runs on the main thread: queue the save, and end the task as soon as that write finishes.
            MainActor.assumeIsolated {
                // Waiting for iOS to start background work: leave the scan as it is (iOS pauses the app and the
                // background task carries on from there); otherwise stop it cleanly.
                if !taskOwnsScan && !continuedRunning { scanner.stop() }
                Shared.library(m).save { if done.claim() { UIApplication.shared.endBackgroundTask(id) } }
            }
        }
        scanner.whenFinished {
            Shared.library(m).flush()
            if id != .invalid, done.claim() { UIApplication.shared.endBackgroundTask(id) }
        }
    }

    /// One background run: finish checking photos, then (when Claude scoring is on and set to keep going) score
    /// with Claude, the same way as in the app. Reports progress every second: iOS ends a continued task whose
    /// progress stops moving.
    @MainActor final class Work {
        let mode: AppMode
        private var ticker: Task<Void, Never>?
        private var stopped = false
        init(mode: AppMode) { self.mode = mode }

        /// Photos left to check, or Claude scoring running or set to start.
        static func hasWork(_ m: AppMode) -> Bool {
            let s = Shared.scanner(m), c = Shared.claude(m)
            return s.isScanning || s.needsScan || c.busy || claudeWanted(m)
        }
        /// Claude scoring set to keep going by itself (Score, or chosen on the first screen), with a key or Plus.
        static func claudeWanted(_ m: AppMode) -> Bool {
            let c = Shared.claude(m), lib = Shared.library(m)
            return UserDefaults.standard.bool(forKey: m.key("autoClaude")) && lib.claudeToSend > 0
                && (Claude.apiKey(for: m) != nil || c.viaPlus)
        }

        func run(progress: ((Int64, Int64, String) -> Void)?, done: @escaping @MainActor () -> Void) {
            let m = mode, scanner = Shared.scanner(m), claude = Shared.claude(m), lib = Shared.library(m)
            scanner.startIfNeeded(library: lib)
            var claudeTries = 0
            ticker = Task { @MainActor [weak self] in
                var base: Int64 = 0, lastLive: Int64 = 0, lastTotal: Int64 = 0
                // Never reported lower than before (iOS reads a drop or a standstill as stuck): earlier Claude
                // passes' photos are kept, and a small step each second covers a long upload or a pause.
                var shownDone: Int64 = 0, shownTotal: Int64 = 1, sentBefore: Int64 = 0, lastSent: Int64 = 0
                var subtitle = "Checking your photos"
                func report(_ d: Int64, _ t: Int64, _ s: String) {
                    subtitle = s
                    shownTotal = max(shownTotal, t, shownDone + 2)
                    shownDone = min(max(shownDone, d), shownTotal - 1)
                    progress?(shownDone, shownTotal, subtitle)
                }
                while !Task.isCancelled, let self, !self.stopped {
                    // You switched to the other app (its own work takes over): this one's run ends here.
                    if UIApplication.shared.applicationState == .active && AppMode.current != m { break }
                    if scanner.isScanning {
                        let live = Int64(scanner.live.value), total = Int64(scanner.total)
                        if live < lastLive { base += lastTotal }          // a new pass started
                        lastLive = live; lastTotal = max(total, live)
                        let d = base + live + sentBefore + lastSent
                        report(max(d, shownDone + (d <= shownDone ? 1 : 0)), base + lastTotal + sentBefore + lastSent + 1,
                               "\(live.formatted()) of \(total.formatted()) photos checked")
                    } else if scanner.needsScan {
                        scanner.startIfNeeded(library: lib)                // photos added meanwhile
                        report(shownDone + 1, shownTotal + 1, subtitle)
                    } else if claude.busy {
                        let photos = base + lastTotal, s = Int64(claude.sent)
                        if s < lastSent { sentBefore += lastSent }          // a new pass started its count over
                        lastSent = s
                        let moved = shownDone >= photos + sentBefore + s ? 1 : 0   // a long upload still shows movement
                        report(max(photos + sentBefore + s, shownDone + Int64(moved)),
                               photos + sentBefore + Int64(max(claude.toSend, claude.sent)) + 1,
                               "Claude: \(claude.sent.formatted()) of \(claude.toSend.formatted()) photos sent")
                    } else if Work.claudeWanted(m) && claudeTries < 2 {
                        claudeTries += 1                                     // a pass; at most twice per run
                        sentBefore += lastSent; lastSent = 0
                        Task { await ClaudeService.runAndTrack(lib) }
                        report(shownDone + 1, shownTotal + 1, "Scoring with Claude")
                        try? await Task.sleep(for: .seconds(1))             // let it get going
                        continue
                    } else {
                        break                                                // nothing left
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                lib.flush()
                if !(self?.stopped ?? true) { done() }
            }
        }

        /// iOS wants the time back: stop checking, let photos already sent to Claude come back, save.
        func stop() {
            stopped = true
            ticker?.cancel()
            Shared.scanner(mode).stop()
            Shared.claude(mode).pause()
            Shared.library(mode).flush()
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
