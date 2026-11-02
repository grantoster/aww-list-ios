import SwiftUI

/// Settings: Learn my Likes — what it has learned from your votes, and the button to vote on more.
struct LikesSection: View {
    @EnvironmentObject var library: Library
    @State private var voting = false
    var body: some View {
        Section {
            Button { voting = true } label: { Label("Learn my Likes", systemImage: "hand.thumbsup") }
                .fullScreenCover(isPresented: $voting) { LikesView() }
            let pct = { (v: Double) in "\(Int((v * 100 + 1e-9).rounded(.toNearestOrAwayFromZero)))%" }
            if let t = library.taste {
                LabeledContent("Learned from", value: "\(t.votes.formatted()) votes (\(t.ups.formatted()) up)")
                LabeledContent("Agrees with your votes", value: pct(t.agreement))
                LabeledContent("Always guessing your usual vote", value: pct(t.baseline))
            }
        } header: {
            Text("Learn my Likes")
        } footer: {
            footer
        }
    }

    private var footer: Text {
        let n = library.votesCount
        let base = Text("Shows you 100 random photos to vote up or down, then nudges every photo's learned score (by up to \(String(format: "%.1f", Learner.maxTasteNudge)) points) toward what you like. Every thumbs up or down you give counts, here or on any photo. ")
        if library.training { return base + Text("Learning from your votes now…") }
        guard let t = library.taste else {
            return base + Text("It starts once you've voted on at least \(Learner.minimumVotes) photos, with at least \(Learner.minimumEachWay) up and \(Learner.minimumEachWay) down (\(n.formatted()) votes so far).")
        }
        if !t.useful {
            return base + Text("Checked on each quarter of your voting days, learning from the rest: it doesn't yet clearly beat always guessing your usual vote, so it isn't changing scores. More votes, with a mix of up and down, help.")
        }
        return base + Text("Checked on each quarter of your voting days, learning from the rest. It's nudging scores now.")
    }
}

/// One photo at a time, chosen at random from your list: thumbs up, thumbs down, or skip.
struct LikesView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [Moment] = []
    @State private var index = 0
    /// Your answers, newest last, for Undo (skips are 0).
    @State private var answers: [Int] = []
    static let sessionSize = 100

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if queue.isEmpty {
                    Spacer()
                    Text("There are no photos left that you haven't voted on.").foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else if index < queue.count {
                    let m = queue[index]
                    Text("\(index + 1) of \(queue.count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    AssetImage(id: m.best.id, contentMode: .fit, targetSide: 900, cached: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .id(m.best.id)
                        .accessibilityLabel(m.caption)
                    HStack(spacing: 12) {
                        voteButton("Not for me", "hand.thumbsdown.fill", -1)
                        voteButton("Love it", "hand.thumbsup.fill", 1)
                    }
                    HStack {
                        Button("Undo") { undo() }.disabled(answers.isEmpty).frame(minWidth: 44, minHeight: 44)
                        Spacer()
                        Button("Skip") { answer(0) }.frame(minWidth: 44, minHeight: 44)
                    }
                } else {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.grapeInk)
                    let n = answers.filter { $0 != 0 }.count
                    Text("Thanks! \(n.formatted()) vote\(n == 1 ? "" : "s").").font(Theme.label(22, relativeTo: .title2))
                    Text("Awwbum learns from them when you tap Done. Settings shows how well it predicts your votes.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    HStack(spacing: 24) {
                        Button("Undo last") { undo() }.disabled(answers.isEmpty).frame(minHeight: 44)
                        Button("Do another 100") { start() }.frame(minHeight: 44)
                    }
                    Spacer()
                }
            }
            .padding(16)
            .navigationTitle("Learn my Likes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if queue.isEmpty && answers.isEmpty { start() } }
            // Learns once, when you leave (not after every tap).
            .onDisappear { library.retrain() }
        }
    }

    private func voteButton(_ title: String, _ icon: String, _ value: Int) -> some View {
        Button { answer(value) } label: {
            Label(title, systemImage: icon).font(.headline).frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(value > 0 ? Theme.grapeInk : Color.secondary)
    }

    private func start() {
        queue = Array(library.everyMoment.filter { library.reaction($0) == 0 }.shuffled().prefix(Self.sessionSize))
        index = 0; answers = []
    }
    private func answer(_ v: Int) {
        guard index < queue.count else { return }
        if v != 0 { library.setReaction(queue[index], v, learnSoon: false) }
        answers.append(v); index += 1
    }
    private func undo() {
        guard let last = answers.popLast(), index > 0 else { return }
        index -= 1
        if last != 0 { library.setReaction(queue[index], 0, learnSoon: false) }
    }
}
