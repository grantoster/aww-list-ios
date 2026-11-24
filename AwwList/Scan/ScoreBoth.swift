import Foundation
import UIKit

/// One trigger scores both apps. Opening the app (or coming back to it), a photo check finishing, or tapping Score
/// all land here: Awwbum's waiting photos are scored, then AwwSnap's, with nothing to tap and no switching apps.
/// Each app keeps its own photo list, key, model, speed, "Photos to send" choice and instructions to Claude, so every
/// photo is still scored by its own app's rubric, and only one photo check runs at a time.
@MainActor
final class ScoreBoth {
    static let shared = ScoreBoth()

    /// Settings (shared by both apps): score when the app opens, and score both apps together. Both default on.
    static let onOpenKey = "autoScoreOnOpen"
    static let bothKey = "scoreBothApps"
    static var onOpen: Bool { UserDefaults.standard.object(forKey: onOpenKey) as? Bool ?? true }
    static var both: Bool { UserDefaults.standard.object(forKey: bothKey) as? Bool ?? true }

    /// The apps one run covers: the one showing, then the other when scoring both together is on.
    static func modes(for focus: AppMode) -> [AppMode] { both ? [focus, focus.other] : [focus] }

    /// The app can pay for scoring: its own key, or Awwbum Plus (Awwbum only). An app with neither is never touched,
    /// so someone who never set up AwwSnap's key has nothing of AwwSnap's sent.
    static func canPay(_ m: AppMode) -> Bool { Claude.hasKey(m) || (m == .aww && ClaudeService.viaPlus) }

    /// The other app, when it is to be scored along with `m` (used to wait for its saved photos to load).
    func otherToScore(_ m: AppMode) -> AppMode? { Self.both && Self.canPay(m.other) ? m.other : nil }

    /// The other app is ready to be scored along with `m` right now: it can pay, its photos are loaded and listed.
    func otherReady(_ m: AppMode) -> Bool {
        guard let o = otherToScore(m) else { return false }
        let lib = Shared.library(o)
        return lib.ready && !lib.photos.isEmpty
    }

    private var task: Task<Void, Never>?
    private var again = false
    private var armNext = false
    private var launched = false
    /// Bumped by Stop: a run started before it ends, and can't switch scoring back on afterwards.
    private var epoch = 0
    private var foreground: Bool { UIApplication.shared.applicationState == .active }

    /// True the first time it's asked in a launch (so opening the app scores once, not on every screen rebuild).
    func firstOpen() -> Bool {
        if launched { return false }
        launched = true
        return true
    }

    /// The app was opened, or came back after being away: score whatever is waiting (unless turned off in Settings).
    func appOpened() { start(arming: Self.onOpen) }

    /// Starts (or carries on) scoring in every app that is switched on. Safe to call often: a run already going
    /// just looks again when it finishes. `arming` first switches scoring on in each app that has used Claude before
    /// (so opening the app, or tapping Score, doesn't need a separate tap per app).
    func start(arming: Bool = false) {
        if arming { armNext = true }
        if task != nil { again = true; return }
        task = Task { @MainActor [self] in
            repeat {
                again = false
                let e = epoch
                let arm = armNext
                armNext = false
                for m in Self.modes(for: AppMode.current) {
                    if e != epoch { break }
                    await score(m, arm: arm, epoch: e)
                }
            } while again
            task = nil
        }
    }

    /// Stop scoring in both apps: photos already out come back, and nothing restarts by itself until the app is
    /// opened again (or Score is tapped).
    func stop() {
        epoch += 1; armNext = false; again = false
        for m in AppMode.allCases {
            UserDefaults.standard.set(false, forKey: m.key("autoClaude"))
            if m == .aww || Shared.snapOpened { Shared.claude(m).stop() }
        }
    }

    // MARK: One app

    private func score(_ m: AppMode, arm: Bool, epoch e: Int) async {
        let d = UserDefaults.standard, flag = m.key("autoClaude")
        guard Self.canPay(m) else { return }
        let lib = Shared.library(m), claude = Shared.claude(m)
        await whenReady(Shared.library)   // AwwSnap shares Who's Who with Awwbum's library
        await whenReady(lib)
        // Never opened (nothing was ever listed): nothing to score, and nothing is started for it.
        guard !lib.photos.isEmpty, e == epoch else { return }
        if m == .snap { Shared.snapOpened = true }   // its library follows Who's Who changes from here on
        // Only an app that has had Claude score photos before starts by itself: the first scoring is always your tap.
        if arm && lib.claudeScored > 0 { d.set(0, forKey: m.key("autoClaudeTries")); d.set(true, forKey: flag) }
        var passes = 0
        // In the foreground only: once you leave, the background task (Work) carries on, so the two never fight.
        while e == epoch, foreground, d.bool(forKey: flag), passes < 4 {
            guard await photosChecked(m, epoch: e) else { return }
            while claude.busy && e == epoch && d.bool(forKey: flag) { try? await Task.sleep(for: .seconds(1)) }
            guard e == epoch, foreground, d.bool(forKey: flag) else { return }
            // Nothing waiting after the photo check: done, without redrawing the whole list for nothing.
            if lib.claudeToSend == 0 { d.set(false, forKey: flag); return }
            passes += 1
            await ClaudeService.runAndTrack(lib)
            switch claude.lastOutcome {
            case .paused: continue                                  // the library changed: check it, then go on
            case .notStarted: try? await Task.sleep(for: .seconds(2)); continue   // an earlier upload or a photo check came first
            case .done, .retryLater, .keyRejected: return           // runAndTrack already decided whether to keep going
            }
        }
    }

    /// This app's photos are checked (new ones too) before anything is sent, one app's photo check at a time.
    /// False when scoring was switched off meanwhile.
    private func photosChecked(_ m: AppMode, epoch e: Int) async -> Bool {
        let d = UserDefaults.standard, flag = m.key("autoClaude")
        let lib = Shared.library(m), scanner = Shared.scanner(m)
        while e == epoch, foreground, d.bool(forKey: flag) {
            if scanner.isScanning {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in scanner.whenFinished { c.resume() } }
                continue
            }
            // One photo check at a time: the other app's goes first when it's running, and the app showing gets
            // its own checked before this one's (leaving an app stops its check; it picks up again after).
            let cur = AppMode.current
            let other = (m == .snap || Shared.snapOpened) && Shared.scanner(m.other).isScanning
            let showingFirst = m != cur && (Shared.scanner(cur).isScanning || Shared.scanner(cur).needsScan)
            if other || showingFirst {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            if scanner.needsScan {
                scanner.startIfNeeded(library: lib)
                if scanner.isScanning { continue }
            }
            return true
        }
        return false
    }

    private func whenReady(_ lib: Library) async {
        guard !lib.ready else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lib.whenReady { c.resume() } }
    }
}
