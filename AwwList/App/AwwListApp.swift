import SwiftUI

@main
struct AwwListApp: App {
    @StateObject private var library = Shared.library
    @StateObject private var scanner = Shared.scanner
    @StateObject private var claude = Shared.claude
    @StateObject private var plus = Shared.plus

    init() { BackgroundScan.register(); Theme.styleNavigationBars() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(scanner)
                .environmentObject(claude)
                .environmentObject(plus)
                .tint(Theme.accent)
        }
    }
}
