import SwiftUI

/// Which app is showing (Awwbum or the hidden AwwSnap). Switching rebuilds the screens for the other app.
@MainActor
final class ModeSwitch: ObservableObject {
    static let shared = ModeSwitch()
    @Published private(set) var mode = AppMode.current
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
        BackgroundScan.register(); Theme.styleNavigationBars()
        if AppMode.current == .snap { Shared.snapOpened = true }
    }

    var body: some Scene {
        WindowGroup {
            let m = modes.mode
            RootView()
                .environmentObject(Shared.library(m))
                .environmentObject(Shared.scanner(m))
                .environmentObject(Shared.claude(m))
                .environmentObject(plus)
                .tint(Theme.accent)
                .id(m)   // a fresh set of screens (and colors) for the other app
        }
    }
}
