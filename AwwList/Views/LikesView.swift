import SwiftUI

/// Settings: Learn my Likes — "Which is cuter?" votes, what they've done, and the button to vote on more.
struct LikesSection: View {
    @EnvironmentObject var library: Library
    @State private var voting = false
    var body: some View {
        Section {
            Button { voting = true } label: { Label("Learn my Likes", systemImage: "rectangle.split.2x1") }
                .fullScreenCover(isPresented: $voting) { LikesView() }
            let picked = library.pairVotes.filter { $0.winner != nil }
            if !picked.isEmpty {
                LabeledContent("Votes so far", value: picked.count.formatted())
                LabeledContent("Photos you've compared", value: Set(picked.flatMap { [$0.a, $0.b] }).count.formatted())
            }
        } header: {
            Text("Learn my Likes")
        } footer: {
            Text("Shows two photos from your list at a time; tap the \(AppMode.current == .snap ? "better one" : "cuter one"). Pairs are close calls the ranking is least sure about, so every vote counts. Your votes give each photo a preference, and the learning aims for it, ahead of Claude's score where the two disagree. \(library.training ? "Learning from your votes now…" : "It learns when you tap Done.") Thumbs up and down given before this count as a light starting hint; thumbs no longer teach the learning. Votes stay on this iPhone; they're only in the learning data if you choose to send it.")
        }
    }
}

/// "Which is cuter?": two photos at a time, side by side (stacked on a narrow screen). Tap one, or Skip.
struct LikesView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pair: (Moment, Moment)?
    @State private var started = false
    /// Votes (and skips) this session, for the counter and Undo.
    @State private var session = 0
    @State private var picks = 0
    /// Preferences when the session began, to show how far the ranking has moved.
    @State private var startStrengths: [String: Double] = [:]
    @State private var moved = 0

    private var question: String { AppMode.current == .snap ? "Which is the better photo?" : "Which is cuter?" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let p = pair {
                    let a = p.0, b = p.1
                    Text(question).font(Theme.display(26, relativeTo: .title2))
                    GeometryReader { geo in
                        // Side by side on iPad, Mac and a phone on its side; stacked on a phone held upright.
                        let wide = sizeClass == .regular || geo.size.width > geo.size.height
                        let layout = wide ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
                        layout {
                            choice(a, other: b)
                            choice(b, other: a)
                        }
                    }
                    HStack {
                        Button("Undo") { undo() }.disabled(session == 0).frame(minWidth: 44, minHeight: 44)
                        Spacer()
                        Button("Skip") { vote(a, b, winner: nil) }.frame(minWidth: 44, minHeight: 44)
                            .accessibilityHint("Too close to call, or one of them shouldn't be on the list")
                    }
                    progress
                } else if started {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.grapeInk)
                    Text(picks == 0 ? "No close calls left to ask about." : "Thanks! \(picks.formatted()) vote\(picks == 1 ? "" : "s").")
                        .font(Theme.label(22, relativeTo: .title2)).multilineTextAlignment(.center)
                    Text("New pairs show up as more photos are scored. \(AppMode.current.title) learns from your votes when you tap Done.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ProgressView()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Learn my Likes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                guard !started else { return }
                startStrengths = library.voteStrengths
                pair = library.nextPair(); started = true
            }
            // Learns once, when you leave (not after every tap).
            .onDisappear { library.retrain() }
        }
    }

    private func choice(_ m: Moment, other: Moment) -> some View {
        Button { vote(m, other, winner: m) } label: {
            AssetImage(id: m.best.id, contentMode: .fit, targetSide: 700, cached: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(m.caption), \(m.best.date.formatted(date: .abbreviated, time: .omitted))")
        .accessibilityHint("Picks this one")
    }

    private var progress: some View {
        VStack(spacing: 2) {
            Text(session == 0 ? "Tap the one you like more." : "\(picks.formatted()) vote\(picks == 1 ? "" : "s") this session")
                .font(.subheadline.bold())
            if moved > 0 {
                Text("Your votes have moved \(moved.formatted()) photo\(moved == 1 ? "" : "s") so far")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func vote(_ a: Moment, _ b: Moment, winner: Moment?) {
        library.recordVote(a.best.id, b.best.id, winner: winner?.best.id)
        session += 1
        if winner != nil { picks += 1 }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        moved = Pairwise.moved(from: startStrengths, to: library.voteStrengths)
        pair = library.nextPair()
    }

    private func undo() {
        guard session > 0, let last = library.pairVotes.last else { return }
        library.undoVote()
        session -= 1
        if last.winner != nil { picks -= 1 }
        moved = Pairwise.moved(from: startStrengths, to: library.voteStrengths)
        // Show that pair again.
        let byID = Dictionary(library.moments.map { ($0.best.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let a = byID[last.a], let b = byID[last.b] { pair = (a, b) } else { pair = library.nextPair() }
    }
}
