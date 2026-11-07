import SwiftUI

/// Which app is showing (Awwbum or the hidden AwwSnap). Switching rebuilds the screens for the other app.
@MainActor
final class ModeSwitch: ObservableObject {
    static let shared = ModeSwitch()
    @Published private(set) var mode = AppMode.current

    /// Away 4 hours or more: back in Awwbum when you return (a fresh start always opens there too).
    private static let awayKey = "leftAppAt"
    private var observers: [NSObjectProtocol] = []
    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: ModeSwitch.awayKey)
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let left = UserDefaults.standard.double(forKey: ModeSwitch.awayKey)
                if left > 0, Date().timeIntervalSince1970 - left >= 4 * 3600, ModeSwitch.shared.mode == .snap {
                    ModeSwitch.shared.switchTo(.aww)
                }
            }
        })
    }
    func switchTo(_ m: AppMode) {
        guard m != mode else { return }
        Shared.scanner(mode).stop()    // one scan at a time: the app being left stops checking photos
        Shared.library(mode).flush()   // nothing lost from the app being left
        AppMode.current = m
        if m == .snap { Shared.snapOpened = true }
        Theme.styleNavigationBars()
        mode = m
        // Who's Who may have changed in the other app: this one works out its faces again.
        let lib = Shared.library(m)
        if lib.ready { lib.learnPeople() }
    }
}

@main
struct AwwListApp: App {
    @StateObject private var modes = ModeSwitch.shared
    @StateObject private var plus = Shared.plus

    init() {
        // Always opens in Awwbum: AwwSnap is reached only from the logo, each time.
        AppMode.current = .aww
        BackgroundScan.register(); Theme.styleNavigationBars()
    }

    var body: some Scene {
        WindowGroup {
            let m = modes.mode
            RootView()
                .environmentObject(Shared.library(m))
                .environmentObject(Shared.scanner(m))
                .environmentObject(Shared.claude(m))
                .environmentObject(plus)
                .tint(Theme.grapeInk)   // text and icons: readable in light and dark (filled buttons use Theme.accent)
                .id(m)   // a fresh set of screens (and colors) for the other app
        }
    }
}
