import SwiftUI

/// Search the ranked photos by what's in them: Claude's descriptions, the phone's own descriptions, and the
/// names of people recognized in Who's Who. Runs on this iPhone only; results keep the current ranking.
struct SearchView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Moment] = []
    @State private var viewer: ViewerState?
    @State private var shown = 60

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView("Search your awws", systemImage: "magnifyingglass",
                                               description: Text("Try \"beach\", \"birthday cake\", \"laughing\" or a name from Who's Who."))
                            .padding(.top, 40)
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: query).padding(.top, 40)
                    } else {
                        Text("\(results.count.formatted()) photo\(results.count == 1 ? "" : "s")")
                            .font(Theme.label(15)).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(Array(results.prefix(shown).enumerated()), id: \.element.id) { i, m in
                                Tile(moment: m, rank: nil) { viewer = ViewerState(list: results, index: i) }
                            }
                        }
                        if results.count > shown {
                            Button("Show more") { shown += 60 }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Describe a photo")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: query) {
                // A short pause so typing doesn't search on every letter.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                shown = 60
                results = PhotoSearch.matches(query, in: library.everyMoment, names: Dictionary(
                    library.people.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
            }
            .fullScreenCover(item: $viewer) { v in ViewerView(moments: v.list, index: v.index) }
        }
    }
}

/// Word matching for search: ignores capitals and accents, treats plurals and -ing forms alike, matches the start
/// of words ("birth" finds "birthday"), knows a few everyday synonyms, and needs every word typed to match.
enum PhotoSearch {
    static func matches(_ query: String, in moments: [Moment], names: [UUID: String]) -> [Moment] {
        let wanted = words(query)
        guard !wanted.isEmpty else { return [] }
        return moments.filter { m in
            var text = m.caption + " " + m.best.caption
            for id in m.people { if let n = names[id] { text += " " + n } }
            let have = words(text)
            return wanted.allSatisfy { q in have.contains { w in same(q, w) } }
        }
    }

    static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { stem(String($0)) }
    }

    static func stem(_ w: String) -> String {
        var w = w
        if w.count > 5, w.hasSuffix("ing") {                                     // dancing → danc, riding → rid
            w.removeLast(3)
            // hugging → hug, napping → nap, grinning → grin
            if w.count > 2, let last = w.last, w.dropLast().last == last, !"aeiouls".contains(last) { w.removeLast() }
        }
        else if w.count > 4, w.hasSuffix("ies") { w.removeLast(3); w += "y" }  // puppies → puppy
        else if w.count > 4, ["ches", "shes", "xes", "zes", "sses"].contains(where: w.hasSuffix) { w.removeLast(2) }
        else if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }   // cakes → cake
        if w.count > 3, w.hasSuffix("e") { w.removeLast() }                     // cake → cak, dance → danc (matches the -ing forms)
        return synonyms[w] ?? w
    }

    /// The query word matches a word in the photo's description exactly or as its beginning.
    static func same(_ q: String, _ w: String) -> Bool { w == q || (q.count >= 3 && w.hasPrefix(q)) }

    private static let synonyms: [String: String] = {
        let groups: [[String]] = [
            ["kid", "child", "children", "toddler"], ["mom", "mother", "mommy", "mum", "mama"],
            ["dad", "father", "daddy", "papa"], ["grandma", "grandmother", "nana", "granny"],
            ["grandpa", "grandfather", "papaw", "grandad"], ["baby", "infant", "newborn"],
            ["dog", "puppy", "pup"], ["cat", "kitten", "kitty"], ["smil", "grin"],
            ["laugh", "giggl", "laughter"], ["hug", "cuddl", "snuggl"], ["sleep", "nap", "asleep"],
        ]
        var out: [String: String] = [:]
        for g in groups { for w in g { out[w] = g[0] } }
        return out
    }()
}
