import SwiftUI

/// "How to use Awwbum": a short tour, opened from the first row in Settings. Never shown on its own.
struct WalkthroughView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let lead: String?
        let notes: [(String, String)]
    }

    private let pages: [Page] = [
        Page(symbol: "heart.circle.fill", title: "Welcome to Awwbum",
             lead: "It finds the photos of your kids that make everyone go aww, and ranks them year by year. Here's a quick tour of how to use it.",
             notes: [("On your iPhone.", "Photos are scored on this iPhone."),
                     ("Read-only.", "It never edits, adds or deletes photos."),
                     ("Ranked by year.", "Your best moments come first.")]),
        Page(symbol: "square.grid.2x2", title: "Browse your list", lead: nil,
             notes: [("Pick a year.", "Choose All or a single year, then narrow it by age, kind of shot, setting, place or person."),
                     ("Search.", "Tap the magnifier to search by what's in a photo, like \"birthday cake\".")]),
        Page(symbol: "photo", title: "Open a photo", lead: nil,
             notes: [("Move around.", "Tap a photo to open it. Swipe for the next one, pinch to zoom, swipe down to close."),
                     ("The heart.", "It also favorites the photo in your Photos app."),
                     ("The three dots.", "Tag people, or remove a photo from the list.")]),
        Page(symbol: "checkmark.circle", title: "Pick and share", lead: nil,
             notes: [("Pick.", "Press and hold any photo to start picking, then tap more, up to 20."),
                     ("Send.", "Favorite them, copy them to paste into a text, or share them."),
                     ("Top photos.", "Above the list, Copy and Share send your top 20 or 40, and Share a collage makes one picture of your top 10 or 20.")]),
        Page(symbol: "wand.and.stars", title: "Teach it your taste", lead: "Awwbum works on its own, and three things make it better.",
             notes: [("Score with Claude.", "Claude can score the photos you choose if you add an API key in Settings."),
                     ("Which is cuter?", "Your votes help it learn what you like."),
                     ("Who's Who.", "Once you turn it on, name people and see each one's best photos.")]),
        Page(symbol: "sparkles", title: "Score with Claude", lead: "In Settings, under Score with Claude.",
             notes: [("API key.", "Optional. Get one at console.anthropic.com. It stays on this iPhone, and Claude charges your Anthropic account."),
                     ("Photos to send.", "How many photos Claude scores: each year's top 100, 300 or 1,000, or every photo on the list. More photos cost more."),
                     ("Score automatically.", "On by default once you've scored photos with Claude. Then new photos are sent each time you open the app."),
                     ("Swimwear or shirtless.", "Off unless you turn it on. Possible bath photos are never sent."),
                     ("Cost and model.", "Settings shows an estimate before you start. The model is always Haiku, the cheapest.")]),
        Page(symbol: "slider.horizontal.3", title: "Make the list yours", lead: "These each have their own heading in Settings.",
             notes: [("My taste.", "Write what you love in your own words. It's added to Claude's instructions for every photo sent from then on."),
                     ("Your kids' birthdays.", "Sorts photos into Baby (under 1), Toddler (1 to 3) and Kid (4 and up) for the age filter. Stays on this iPhone."),
                     ("Places.", "Save a home by address to see photos taken within about 650 feet of it, or turn on Name towns to filter by town."),
                     ("Fold similar shots.", "Tucks look-alike shots from within 5 minutes under the best one, so the top list shows more different moments."),
                     ("Balance kids.", "Gives each named child a fair share of the top spots. Scores don't change.")]),
        Page(symbol: "questionmark.circle", title: "When it looks off", lead: "Look for these in Settings.",
             notes: [("What's left out.", "See why photos aren't on the list, like screenshots or no child spotted, and add some of them back."),
                     ("Possible bath photos.", "Review photos Apple's check flagged. They stay on your list unless you keep one out, and Claude never sees them."),
                     ("Rescan.", "Checks again, including photos that couldn't load, like ones still in iCloud. Use it if the count looks short."),
                     ("Put back removed photos.", "Appears once you've removed photos, and brings them all back.")]),
        Page(symbol: "lock.shield", title: "Your photos stay yours", lead: "That's the tour. You can open it again any time from Settings, under How to use Awwbum.",
             notes: [("Read-only.", "It never edits, adds or deletes photos. The one change it can make is a favorite, when you tap the heart."),
                     ("On your iPhone.", "Scoring happens here. Photos are only uploaded if you choose to score them with Claude."),
                     ("Careful with Claude.", "Screenshots are left off the list. Possible bath photos, and shots taken near them, are never sent to Claude.")]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(page + 1) of \(pages.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Skip") { dismiss() }.font(Theme.label(17, relativeTo: .body)).foregroundStyle(Theme.accent)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 20).padding(.top, 8)
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    ScrollView { pageView(pages[i]).padding(.horizontal, 24).padding(.bottom, 16) }.tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule().fill(i == page ? Theme.accent : Theme.accent.opacity(0.25))
                        .frame(width: i == page ? 22 : 8, height: 8)
                }
            }
            .accessibilityHidden(true).padding(.vertical, 12)
            HStack(spacing: 12) {
                Button { withAnimation { page -= 1 } } label: {
                    Text("Back").font(Theme.label(19, relativeTo: .headline)).frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered).tint(Theme.accent).opacity(page == 0 ? 0.35 : 1).disabled(page == 0)
                Button {
                    if page == pages.count - 1 { dismiss() } else { withAnimation { page += 1 } }
                } label: {
                    Text(page == pages.count - 1 ? "Done" : "Next").font(Theme.label(19, relativeTo: .headline)).frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func pageView(_ p: Page) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: p.symbol).font(.system(size: 54)).foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 120).background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
                .accessibilityHidden(true)
            Text(p.title).font(Theme.display(30, relativeTo: .title)).foregroundStyle(Theme.grapeInk)
            if let lead = p.lead { Text(lead).font(.body).foregroundStyle(.secondary) }
            ForEach(p.notes.indices, id: \.self) { i in
                Text("**\(p.notes[i].0)** \(p.notes[i].1)").font(.body)
            }
        }
    }
}
