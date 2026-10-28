import SwiftUI

@main
struct AwwListApp: App {
    @StateObject private var library = Library()
    @StateObject private var scanner = PhotoScanner()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(scanner)
                .tint(Theme.accent)
        }
    }
}
