import Combine
import SwiftUI

/// A round crop of one face from a photo.
struct FaceThumb: View {
    let photo: String
    let box: [Float]
    var size: CGFloat = 56
    @State private var image: UIImage?

    var body: some View {
        Circle().fill(Color.secondary.opacity(0.15))
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipShape(Circle())
            .frame(width: size, height: size)
            .task(id: photo + box.map { String($0) }.joined()) {
                guard let full = await AssetImage.load(id: photo, size: CGSize(width: 900, height: 900), mode: .aspectFit).image else { return }
                let b = box
                image = await Task.detached(priority: .userInitiated) { Self.crop(full, box: b) }.value
            }
            .accessibilityHidden(true)
    }

    /// Crops a face (normalized, bottom-left origin) with some room around it.
    nonisolated static func crop(_ img: UIImage, box: [Float]) -> UIImage? {
        guard box.count == 4 else { return img }
        // Redraw only when the photo isn't already upright, at 1x (not screen scale) to keep memory small.
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let upright = img.imageOrientation == .up ? img : UIGraphicsImageRenderer(size: img.size, format: fmt).image { _ in img.draw(at: .zero) }
        guard let cg = upright.cgImage else { return img }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let bw = CGFloat(box[2]) * w, bh = CGFloat(box[3]) * h
        let side = max(bw, bh) * 1.6
        let cx = CGFloat(box[0]) * w + bw / 2, cy = (1 - CGFloat(box[1])) * h - bh / 2   // flip to top-left origin
        let r = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !r.isNull, let c = cg.cropping(to: r.integral) else { return img }
        return UIImage(cgImage: c)
    }
}

/// Who's Who: name the faces that keep showing up, then filter the list by person.
struct WhoView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [[(photo: String, face: FaceRecord)]] = []
    @State private var askTurnOff = false
    @State private var loading = true
    @State private var naming: NamingGroup?
    @State private var editing: Person?
    @State private var generation = 0
    /// How many of the top 300 have no one tagged (worked out when the list changes).
    @State private var untaggedCount = 0
    /// Groups that look like someone already named: "Is this Maya?"
    @State private var suggestions: [Suggestion] = []
    /// A quick check opened to see all its faces.
    @State private var checking: Suggestion?

    struct Suggestion: Identifiable {
        let id: String
        let person: Person
        let faces: [(photo: String, face: FaceRecord)]
    }

    struct NamingGroup: Identifiable {
        let id = UUID()
        let faces: [(photo: String, face: FaceRecord)]
    }

    @AppStorage("faceConsent") private var faceConsent = false

    var body: some View {
        if faceConsent { whoBody } else { consentBody }
    }

    /// Asked once, before Who's Who recognizes anyone.
    private var consentBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "person.2.crop.square.stack").font(.system(size: 44)).foregroundStyle(Theme.accent)
                    Text("Turn on Who's Who?").font(Theme.label(24, relativeTo: .title2))
                    Text("Who's Who recognizes the people you name, like \(AppMode.current == .snap ? "your family and friends" : "your kids"), so you can see each person's best photos.")
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Turning it on makes face measurements (face prints) of up to 8 faces in each photo on your list, on this iPhone, so it can tell people apart. It re-reads those photos, which can take a while on a large library.", systemImage: "face.smiling")
                        Label("Face prints and names stay in the app on this iPhone. They're never sent to us, Claude or Anthropic (they're part of your iPhone backup if backups are on).", systemImage: "lock.fill")
                        Label("Forget a person, or turn Who's Who off to delete every face print. Deleting the app deletes all of it (copies in earlier backups stay until those backups are deleted).", systemImage: "trash")
                        Label("Only name people who are OK with it (or whose parent is).", systemImage: "hand.raised")
                    }
                    .font(.subheadline).padding().background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    Button {
                        faceConsent = true
                        library.setFaceConsent(true)
                    } label: {
                        Text("Turn on Who's Who").font(Theme.label(19, relativeTo: .headline)).frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    Button("Not now") { dismiss() }.frame(maxWidth: .infinity)
                }
                .padding(24)
            }
            .navigationTitle("Who's Who").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private var whoBody: some View {
        NavigationStack {
            List {
                let tally = library.faceTally
                if tally.total > 0 {
                    Section {
                        HStack(spacing: 0) {
                            TallyCell(value: tally.unidentified, label: "Unidentified")
                            TallyCell(value: tally.named, label: "Named")
                            TallyCell(value: tally.setAside, label: "Set aside")
                        }
                        .accessibilityElement(children: .combine)
                    } header: {
                        Text("\(tally.total.formatted()) faces found")
                    } footer: {
                        let pct = Int((Double(tally.named) * 100 / Double(tally.total)).rounded(.toNearestOrAwayFromZero))
                        Text("\(pct)% of faces have a name. Unidentified includes strangers and faces in the background; tap × on those in Who is this? to set them aside.")
                    }
                }
                // The fastest way to teach it: one face at a time, most likely first.
                let reviewable = library.people.filter { !(library.reviewFaces[$0.id] ?? []).isEmpty }
                if !reviewable.isEmpty {
                    Section {
                        ForEach(reviewable) { p in
                            // By value, so the screen stays open when this row goes away (all of their faces answered).
                            NavigationLink(value: ReviewTarget(person: p)) {
                                HStack(spacing: 12) {
                                    FaceThumb(photo: p.samplePhoto, box: p.sampleBox, size: 36)
                                    Text("Is this \(p.name)?")
                                    Spacer()
                                    let n = (library.reviewFaces[p.id] ?? []).count
                                    Text("\(n) face\(n == 1 ? "" : "s")").foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Review faces")
                    } footer: {
                        Text("Up to 24 faces at a time, most likely first. Every answer teaches the app, so it recognizes more on its own.")
                    }
                }
                if !library.people.isEmpty {
                    // The best photos with no one tagged yet: open one and tag who's in it.
                    Section {
                        NavigationLink {
                            UntaggedPhotosView()
                        } label: {
                            HStack {
                                Text("Top \(UntaggedPhotosView.topCount) with no one tagged")
                                Spacer()
                                Text("\(untaggedCount) photo\(untaggedCount == 1 ? "" : "s")").foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("Photos in your top \(UntaggedPhotosView.topCount) with faces where no one is tagged or recognized yet. Tap one to tag who's in it, or ignore ones you won't tag.")
                    }
                    Section("Named") {
                        ForEach(library.people) { p in
                            Button { editing = p } label: {
                                HStack(spacing: 12) {
                                    FaceThumb(photo: p.samplePhoto, box: p.sampleBox, size: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).font(.headline).foregroundStyle(.primary)
                                        Text(summary(p)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                let open = suggestions.filter { !library.declinedChecks.contains($0.id) }
                if !open.isEmpty {
                    Section {
                        ForEach(open) { s in
                            VStack(alignment: .leading, spacing: 10) {
                                // Tap the faces to see all of them and take out any that aren't this person.
                                Button { checking = s } label: {
                                    HStack(spacing: -10) {
                                        ForEach(Array(s.faces.prefix(4).enumerated()), id: \.offset) { _, f in
                                            FaceThumb(photo: f.photo, box: f.face.box, size: 48)
                                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                        }
                                        Spacer(minLength: 16)
                                        Text("See all \(s.faces.count)").font(.subheadline).foregroundStyle(Theme.grapeInk)
                                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                                            .padding(.leading, 6).accessibilityHidden(true)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("See all \(s.faces.count) faces that might be \(s.person.name)")
                                HStack {
                                    Text("Is this \(s.person.name)?").font(.headline)
                                    Spacer()
                                    Button("No") {
                                        // Remembered for good: these faces aren't suggested as them again.
                                        if let p = library.people.first(where: { $0.id == s.person.id }) { library.rejectFaces(s.faces, for: p) }
                                        library.declinedChecks.insert(s.id); regroup()
                                    }.buttonStyle(.bordered)
                                    Button("Yes") {
                                        // By id, in case they were renamed since.
                                        if let p = library.people.first(where: { $0.id == s.person.id }) {
                                            library.name(s.faces, as: p.name, birthday: nil)
                                        }
                                        library.declinedChecks.insert(s.id)
                                    }
                                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Quick check")
                    } footer: {
                        Text("These look like people you've named. Each yes teaches the app more of their faces.")
                    }
                }
                Section {
                    if library.learningPeople {
                        HStack { ProgressView(); Text("Learning the rest of the faces…").foregroundStyle(.secondary) }
                    }
                    if loading {
                        HStack { ProgressView(); Text("Finding faces…").foregroundStyle(.secondary) }
                    } else if groups.isEmpty {
                        Text(library.scanner.isScanning ? "Reading faces in your photos… they show up here as they're found."
                             : library.moments.isEmpty ? "Faces show up here once your photos are scanned."
                             : "Everyone who shows up often has a name.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                        Button { naming = NamingGroup(faces: g) } label: {
                            HStack(spacing: -10) {
                                ForEach(Array(g.prefix(4).enumerated()), id: \.offset) { _, f in
                                    FaceThumb(photo: f.photo, box: f.face.box, size: 48)
                                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                }
                                Spacer(minLength: 16)
                                Text("\(g.count) photos").font(.subheadline).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary).padding(.leading, 6)
                            }
                        }
                        .accessibilityLabel("Name this person, seen in \(g.count) photos")
                    }
                } header: {
                    Text("Who is this?")
                } footer: {
                    Text("Only the biggest groups are shown. Name a few and the app learns the rest of that person's faces on its own, so the list shrinks as you go. Giving two groups the same name joins them. Everything stays on this iPhone.")
                }
                Section {
                    Picker("Grouping", selection: Binding(get: { library.strictness }, set: { library.setStrictness($0); regroup() })) {
                        Text("Stricter").tag(0)
                        Text("Normal").tag(1)
                        Text("Looser").tag(2)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Stricter if groups mix different people; looser if one person is split across many groups. Kids' faces change a lot, so naming a child once or twice per year or so helps the app follow them. With a birthday set, a child is never matched in photos from before they were born. Faces are recognized on this iPhone with InsightFace's face model (non-commercial license).")
                }
                Section {
                    Button("Turn off Who's Who") { askTurnOff = true }
                        .confirmationDialog("Turn off Who's Who?", isPresented: $askTurnOff, titleVisibility: .visible) {
                            Button("Turn off and delete face prints", role: .destructive) { faceConsent = false; library.setFaceConsent(false) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Every face print in Awwbum and AwwSnap is deleted. Names and birthdays stay.")
                        }
                } footer: {
                    Text("Stops recognizing people and deletes every Who's Who face print. Names and birthdays stay; to recognize someone again, turn Who's Who back on and name a few of their faces with the same name.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Who's Who")
            .navigationDestination(for: ReviewTarget.self) { t in ReviewGridView(person: t.person) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $naming, onDismiss: regroup) { g in NameSheet(faces: g.faces) }
            .sheet(item: $checking, onDismiss: regroup) { s in QuickCheckSheet(suggestion: s) }
            .sheet(item: $editing, onDismiss: regroup) { p in PersonSheet(person: p) }
            .task { regroup() }
            .onReceive(library.scanner.$isScanning) { scanning in if !scanning { regroup() } }   // new face prints
            .onReceive(library.$moments.combineLatest(library.$untaggedIgnored)
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)) { pair in
                untaggedCount = UntaggedPhotosView.untagged(pair.0, library: library).count
            }
            .onChange(of: library.learningPeople) { _, busy in if !busy { regroup() } }
        }
    }

    private func summary(_ p: Person) -> String {
        let n = library.everyMoment.filter { $0.people.contains(p.id) }.count
        var s = "\(n) moment\(n == 1 ? "" : "s")"
        if let l = p.learnedCount, l > 0 { s += " · \(l) faces learned" }
        if let b = p.birthday { s += " · born " + b.formatted(date: .abbreviated, time: .omitted) }
        return s
    }

    /// Groups the unnamed faces off the main thread. Groups that look like someone named become quick yes/no
    /// checks; otherwise only the biggest groups are shown (5+ photos, the 12 largest), since naming those teaches
    /// the app the most. Smaller groups usually get learned once their person is named.
    private func regroup() {
        loading = true
        generation += 1
        let gen = generation
        let faces = library.unnamedFaces()
        let t = library.threshold
        let dates = Dictionary(faces.map { ($0.photo, library.photos[$0.photo]?.date ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
        let named = library.people
        let declined = library.declinedChecks
        let rejected = library.notThemKeys
        @Sendable func rejectedFor(_ id: UUID, _ f: (photo: String, face: FaceRecord)) -> Bool {
            rejected[Library.faceKey(f.photo, f.face)]?.contains(id) == true
        }
        Task.detached(priority: .userInitiated) {
            let vecs = faces.map { People.floats($0.face.vec) }
            let matcher = People.Matcher(named)   // named faces only
            var all = People.cluster(vecs, threshold: t).filter { $0.count >= 3 }.sorted { $0.count > $1.count }
            var asks: [Suggestion] = []
            all.removeAll { c in
                guard asks.count < 8 else { return false }
                let center = People.merged([], count: 0, adding: c.map { vecs[$0] })
                guard let b = matcher.best(center), b.sim >= t - 0.07,
                      let p = named.first(where: { $0.id == b.id }) else { return false }
                // Keyed by the group's first photo, so a No sticks even if the group gains or loses a face.
                let key = p.id.uuidString + ":" + (c.map { faces[$0].photo }.min() ?? "")
                guard !declined.contains(key) else { return false }   // answered No: show it as an ordinary group
                // A face you said isn't them never comes back through a quick "yes".
                // Nor a face from before they were born.
                let fs = c.map { faces[$0] }.filter { f in
                    !rejectedFor(p.id, f) && !(p.birthday.map { (dates[f.photo] ?? .distantPast) < $0.addingTimeInterval(-86_400) } ?? false)
                }
                guard fs.count >= 3 else { return false }
                asks.append(Suggestion(id: key, person: p, faces: fs))
                return true
            }
            let big = all.filter { $0.count >= 5 }
            let shown = (big.isEmpty ? all : big).prefix(12).map { $0.map { faces[$0] } }
            let found = asks
            await MainActor.run {
                guard gen == generation else { return }     // a newer grouping is on its way
                groups = Array(shown); suggestions = found; loading = false
            }
        }
    }
}

/// "Who is this?" — name a group of faces (optionally with a birthday).
struct NameSheet: View {
    @State var faces: [(photo: String, face: FaceRecord)]
    @EnvironmentObject var library: Library
    @State private var showAll = false
    /// Faces taken out of this group; set aside for good only when you tap Save.
    @State private var removed: [(photo: String, face: FaceRecord)] = []
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hasBirthday = false
    @State private var birthday = Calendar.current.startOfDay(for: Date())

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                        ForEach(Array(faces.prefix(showAll ? 120 : 24).enumerated()), id: \.offset) { _, f in
                            RemovableFace(photo: f.photo, box: f.face.box, size: 64, label: "Remove this face from the group") {
                                faces.removeAll { $0.face.vec == f.face.vec && $0.photo == f.photo }
                                removed.append(f)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if faces.count > 24 && !showAll { Button("Show more") { showAll = true } }
                    if let last = removed.last {
                        Button("Undo remove") { removed.removeLast(); faces.insert(last, at: 0) }
                    }
                } footer: {
                    Text("\(faces.count) photos. Tap × on a face that doesn't belong; when you save, it isn't asked about again. If many don't belong, try Stricter grouping.")
                }
                Section("Name") {
                    TextField("Name", text: $name).textInputAutocapitalization(.words).submitLabel(.done)
                    if !library.people.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(library.people) { p in
                                    Button(p.name) { name = p.name }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                Section {
                    Toggle("Add a birthday", isOn: $hasBirthday)
                    if hasBirthday {
                        DatePicker("Birthday", selection: $birthday, in: ...Date(), displayedComponents: .date).tint(Theme.accent)
                    }
                } footer: {
                    Text("With a birthday, this person's photos are sorted into Baby, Toddler and Kid exactly. Once any of your kids has a birthday here, someone without one counts as a grown-up, so group photos with them are under Family & groups, not Kids together.")
                }
            }
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if !faces.isEmpty {
                            // A birthday left at today (the picker's starting day) isn't a real one: it would hide them
                            // in every older photo.
                            let b = Calendar.current.startOfDay(for: birthday)
                            library.name(faces, as: name, birthday: hasBirthday && b != Calendar.current.startOfDay(for: Date()) ? b : nil)
                            // The faces you took out of the group aren't this person, so they're never learned as them.
                            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let p = library.people.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
                                library.rejectFaces(removed, for: p)
                            }
                        }
                        library.ignoreFaces(removed)
                        dismiss()
                    }
                    // Removing every face (a group of strangers) can be saved without a name.
                    .disabled(faces.isEmpty ? removed.isEmpty : name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Rename someone, set their birthday, or forget them.
struct PersonSheet: View {
    @State var person: Person
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false
    @State private var showAll = false
    /// This person's faces, worked out once when the sheet opens (and updated as you remove some).
    @State private var theirs: [(photo: String, face: FaceRecord)] = []
    @State private var lastRemoved: (photo: String, face: FaceRecord)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        FaceThumb(photo: person.samplePhoto, box: person.sampleBox, size: 96)
                        Spacer()
                    }
                }
                Section("Name") { TextField("Name", text: $person.name).textInputAutocapitalization(.words) }
                if !theirs.isEmpty {
                    Section {
                        NavigationLink { DoubleCheckView(person: person) } label: {
                            Label("Double-check \(person.name)'s photos", systemImage: "questionmark.circle")
                        }
                    } footer: {
                        Text("Shows the faces the app counted as \(person.name) on its own but is least sure about, one at a time, so you can say yes or no.")
                    }
                }
                if !theirs.isEmpty || lastRemoved != nil {
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                            ForEach(Array(theirs.prefix(showAll ? 120 : 24).enumerated()), id: \.offset) { _, f in
                                let photoDate = library.photos[f.photo]?.date.formatted(date: .abbreviated, time: .omitted) ?? ""
                                RemovableFace(photo: f.photo, box: f.face.box, size: 64,
                                              label: "Not \(person.name), photo from \(photoDate)") {
                                    library.removeFace(f.photo, f.face, from: person)
                                    theirs.removeAll { $0.face.vec == f.face.vec && $0.photo == f.photo }
                                    lastRemoved = f
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        if theirs.count > 24 && !showAll { Button("Show more") { showAll = true } }
                        if let f = lastRemoved {
                            Button("Undo remove") {
                                library.restoreFace(f.photo, f.face, to: person)
                                theirs.insert(f, at: 0); lastRemoved = nil
                            }
                        }
                    } header: {
                        Text("Faces counted as \(person.name)")
                    } footer: {
                        Text("Tap × on any face that isn't \(person.name). That face is never counted as them again, and the app stops learning from it. No photos are deleted.")
                    }
                }
                Section {
                    Toggle("Birthday", isOn: Binding(get: { person.birthday != nil },
                                                     set: { person.birthday = $0 ? (person.birthday ?? Calendar.current.startOfDay(for: Date())) : nil }))
                    if person.birthday != nil {
                        DatePicker("Born", selection: Binding(get: { person.birthday ?? Date() },
                                                              set: { person.birthday = Calendar.current.startOfDay(for: $0) }),
                                   in: ...Date(), displayedComponents: .date).tint(Theme.accent)
                    }
                }
                Section {
                    if confirmForget {
                        Button("Yes, forget \(person.name)", role: .destructive) { library.forget(person); dismiss() }
                        Button("Keep") { confirmForget = false }
                    } else {
                        Button("Forget this person", role: .destructive) { confirmForget = true }
                    }
                } footer: {
                    Text("Forgetting only removes the name here. No photos are deleted.")
                }
            }
            .navigationTitle(person.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if theirs.isEmpty { theirs = library.faces(of: person) } }
            // Opened before face learning finished: fill in once it has (unless you've started removing faces).
            .onChange(of: library.learningPeople) { _, busy in
                if !busy && lastRemoved == nil { theirs = library.faces(of: person) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { library.update(person); dismiss() }
                        .disabled(person.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// A face with a small × to take it out (of a group to name, or of a named person).
struct RemovableFace: View {
    let photo: String
    let box: [Float]
    var size: CGFloat = 64
    var label = "Remove this face"
    let remove: () -> Void
    var body: some View {
        FaceThumb(photo: photo, box: box, size: size)
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.6))
                        .frame(width: 44, height: 44, alignment: .topTrailing)   // a full-size target over the corner
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .offset(x: 6, y: -6)
                .accessibilityLabel(label)
            }
            .accessibilityElement(children: .contain)
    }
}

/// "Is this Maya?" with every face shown: take out the ones that aren't her, then say yes for the rest.
struct QuickCheckSheet: View {
    let suggestion: WhoView.Suggestion
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var faces: [(photo: String, face: FaceRecord)] = []
    @State private var removed: [(photo: String, face: FaceRecord)] = []
    @State private var showAll = false

    /// The person as named now (by id, in case they were renamed).
    private var person: Person? { library.people.first { $0.id == suggestion.person.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                        ForEach(Array(faces.prefix(showAll ? faces.count : 36).enumerated()), id: \.offset) { _, f in
                            RemovableFace(photo: f.photo, box: f.face.box, size: 64,
                                          label: "Not \(suggestion.person.name), take out") {
                                faces.removeAll { $0.face.vec == f.face.vec && $0.photo == f.photo }
                                removed.append(f)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if faces.count > 36 && !showAll { Button("Show all \(faces.count)") { showAll = true } }
                    if let last = removed.last {
                        Button("Undo take out") { removed.removeLast(); faces.insert(last, at: 0) }
                    }
                } footer: {
                    Text("Tap × on any face that isn't \(suggestion.person.name). Those won't be counted or suggested as \(suggestion.person.name) again.")
                }
                Section {
                    Button("Yes, \(faces.count == 1 ? "this is" : "these are") \(suggestion.person.name)") {
                        guard let p = person else { dismiss(); return }
                        library.rejectFaces(removed, for: p)
                        library.name(faces, as: p.name, birthday: nil)
                        library.declinedChecks.insert(suggestion.id)
                        dismiss()
                    }
                    .disabled(faces.isEmpty)
                    Button("None of these are \(suggestion.person.name)") {
                        if let p = person { library.rejectFaces(faces + removed, for: p) }
                        library.declinedChecks.insert(suggestion.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Is this \(suggestion.person.name)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if faces.isEmpty && removed.isEmpty { faces = suggestion.faces } }
        }
    }
}

/// Opens Review faces (the grid) for a person.
struct ReviewTarget: Hashable { let person: Person }

/// Review faces, many at a time: up to 24 of a person's likely faces in a grid. Tap once for yes, twice for no (or
/// "Mark all"), then save: yeses are named as them, noes never count as them, the rest are asked again later. Each
/// round teaches the app, so the next finds more. "One at a time" offers the slower view with more choices.
struct ReviewGridView: View {
    let person: Person
    @EnvironmentObject var library: Library
    @State private var batch: [(photo: String, face: FaceRecord)] = []
    /// Your answer per face (face key): true = them, false = not them; no entry = not answered (asked again later).
    @State private var answers: [String: Bool] = [:]
    @State private var rounds = 0
    @State private var named = 0
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]
    private var yesCount: Int { answers.values.filter { $0 }.count }
    private var noCount: Int { answers.values.filter { !$0 }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if batch.isEmpty {
                    ContentUnavailableView(rounds == 0 ? "Nothing to check right now" : "All caught up",
                                           systemImage: "checkmark.circle",
                                           description: Text(rounds == 0
                                                             ? "New faces to check show up as the app finds them."
                                                             : "You confirmed \(named.formatted()) face\(named == 1 ? "" : "s") of \(person.name). The app is learning from them; more show up here as it finds them."))
                } else {
                    Text("Is this \(person.name)? Tap once for yes (✓), twice for no (×). Faces you leave are asked about later.")
                        .font(Theme.label(17, relativeTo: .headline))
                    Button("Mark all as \(person.name)") {
                        for f in batch { answers[Library.faceKey(f.photo, f.face)] = true }
                    }
                    .frame(minHeight: 44)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(batch.map { (k: Library.faceKey($0.photo, $0.face), f: $0) }, id: \.k) { item in
                            let k = item.k, f = item.f
                            let a = answers[k]
                            Button {
                                // unanswered → yes → no → unanswered
                                answers[k] = a == nil ? true : (a == true ? false : nil)
                            } label: {
                                FaceThumb(photo: f.photo, box: f.face.box, size: 96)
                                    .opacity(a == false ? 0.35 : 1)
                                    .overlay(alignment: .bottomTrailing) {
                                        if let a {
                                            Image(systemName: a ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .font(.title2).symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, a ? Theme.accent : Color.gray)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Might be \(person.name)")
                            .accessibilityValue(a == nil ? "Not answered" : (a == true ? "Yes, \(person.name)" : "No, not \(person.name)"))
                            .accessibilityHint("Tap for yes; tap again for no; a third tap clears it")
                        }
                    }
                    Button { confirm() } label: {
                        Text(yesCount + noCount == 0 ? "Tap faces to answer"
                             : "Save: \(yesCount.formatted()) yes, \(noCount.formatted()) no")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(yesCount + noCount == 0)
                }
                NavigationLink("One at a time (with more choices)") { ReviewFacesView(person: person) }
                    .frame(minHeight: 44)
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(person.name).navigationBarTitleDisplayMode(.inline)
        .onAppear { if batch.isEmpty { next() } }
        .onChange(of: library.reviewFaces[person.id]?.count ?? 0) { if batch.isEmpty { next() } }
    }

    private func next() {
        batch = Array((library.reviewFaces[person.id] ?? []).prefix(24))
        answers = [:]
    }

    private func confirm() {
        guard let p = library.people.first(where: { $0.id == person.id }) else { return }
        let yes = batch.filter { answers[Library.faceKey($0.photo, $0.face)] == true }
        let no = batch.filter { answers[Library.faceKey($0.photo, $0.face)] == false }
        library.applyReview(person: p, yes: yes, no: no)
        named += yes.count; rounds += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Answered faces leave; unanswered ones come back in the next batch.
        let done = Set((yes + no).map { Library.faceKey($0.photo, $0.face) })
        batch = Array((library.reviewFaces[person.id] ?? []).filter { !done.contains(Library.faceKey($0.photo, $0.face)) }.prefix(24))
        answers = [:]
    }
}

/// Review faces: one possible face of a person at a time, with the photo it's from. Yes, No or Skip; the answers
/// are applied every 15 and when you leave, and each round teaches the app more about them.
struct ReviewFacesView: View {
    let person: Person
    @EnvironmentObject var library: Library
    @State private var queue: [(photo: String, face: FaceRecord)] = []
    @State private var index = 0
    @State private var yes: [(photo: String, face: FaceRecord)] = []
    @State private var no: [(photo: String, face: FaceRecord)] = []
    /// Per answered face, for Undo: yes, no, skipped, or tagged as someone else (their name).
    private enum Answer { case yes, no, skip, stranger, other(String, created: Bool) }
    @State private var history: [Answer] = []
    @State private var started = false
    @State private var naming = false
    @State private var newName = ""
    @State private var tagging: TagTarget?

    private var others: [Person] {
        library.people.filter { $0.id != person.id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {   // scrolls on a small phone, so Undo and Skip stay reachable
        VStack(spacing: 18) {
            if index < queue.count {
                let f = queue[index]
                Text("\(index + 1) of \(queue.count)").font(.footnote).foregroundStyle(.secondary)
                FaceThumb(photo: f.photo, box: f.face.box, size: 220)
                AssetImage(id: f.photo, contentMode: .fit, targetSide: 300, cached: false)
                    .frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text("Is this \(person.name)?").font(Theme.label(22, relativeTo: .title2))
                    .accessibilityLabel("Is this face \(person.name)? From a photo taken \(library.photos[f.photo]?.date.formatted(date: .abbreviated, time: .omitted) ?? "")")
                HStack(spacing: 12) {
                    Button { answer(false) } label: { Text("No").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.bordered)
                    Button { answer(true) } label: { Text("Yes").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                }
                // Not them, but you know who it is: tag it as that person instead.
                Menu {
                    ForEach(others) { p in Button(p.name) { tagOther(p.name) } }
                    Button { newName = ""; naming = true } label: { Label("New person…", systemImage: "plus") }
                } label: {
                    Label("It's someone else", systemImage: "person.crop.circle.badge.questionmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                // Someone you'll never name (a stranger in the background): never asked about again, for anyone.
                Button {
                    library.ignoreFaces([f]); no.append(f); history.append(.stranger); index += 1
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if yes.count + no.count >= 15 { apply(); history = [] }
                } label: {
                    Label("Never ask me about this face", systemImage: "nosign").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered).tint(.secondary)
                HStack {
                    Button("Undo") { undo() }.disabled(history.isEmpty)
                    Spacer()
                    Button("Tag everyone in this photo") { tagging = TagTarget(id: f.photo) }
                    Spacer()
                    Button("Skip") {
                        library.skipFace(queue[index].photo, queue[index].face)   // not asked about again
                        history.append(.skip); index += 1
                    }
                }
                .font(.subheadline)
            } else {
                ContentUnavailableView {
                    Label(queue.isEmpty ? "Nothing to review" : "All done", systemImage: "checkmark.circle")
                } description: {
                    Text("Thanks! The app is learning from your answers; new faces to check show up here as it finds them.")
                }
            }
        }
        .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(person.name).navigationBarTitleDisplayMode(.inline)
        .alert("Who is this?", isPresented: $naming) {
            TextField("Name", text: $newName).textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Tag") { tagOther(newName); newName = "" }
        }
        .sheet(item: $tagging) { t in TagPeopleSheet(photo: t.id) }
        .onAppear {
            guard !started else { return }
            started = true
            queue = library.reviewFaces[person.id] ?? []
        }
        .onDisappear { apply() }
    }

    private func answer(_ isThem: Bool) {
        let f = queue[index]
        if isThem { yes.append(f) } else { no.append(f) }
        history.append(isThem ? .yes : .no)
        index += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if yes.count + no.count >= 15 { apply(); history = [] }   // Undo only goes back to the last batch handed over
    }

    /// Tags this face as someone else (named now, so it counts as theirs), and it isn't this person.
    private func tagOther(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, index < queue.count else { return }
        if name.caseInsensitiveCompare(person.name) == .orderedSame { answer(true); return }   // that's a yes
        let f = queue[index]
        let created = !library.people.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        library.name([f], as: name, birthday: nil)
        no.append(f)
        history.append(.other(name, created: created))
        index += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if yes.count + no.count >= 15 { apply(); history = [] }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        index -= 1
        let f = queue[index]
        let same = { (g: (photo: String, face: FaceRecord)) in g.photo == f.photo && g.face.vec == f.face.vec }
        switch last {
        case .yes: yes.removeAll(where: same)
        case .no: no.removeAll(where: same)
        case .skip: library.unskipFace(f.photo, f.face)
        case .stranger:
            no.removeAll(where: same)
            library.unignoreFace(f.photo, f.face)
        case .other(let name, let created):
            no.removeAll(where: same)
            if let p = library.people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                // Someone added just now by this tag goes away again; otherwise the face is just untagged.
                if created { library.forget(p) } else { library.untagFace(f.photo, f.face, from: p) }
            }
        }
    }

    /// Hands the answers so far to the app (it re-learns in the background).
    private func apply() {
        guard !yes.isEmpty || !no.isEmpty else { return }
        library.applyReview(person: person, yes: yes, no: no)
        yes = []; no = []
    }
}

/// Which photo the Tag people sheet is open for.
struct TagTarget: Identifiable { let id: String }

/// Tag people: name (or un-name) each face in one photo. Every tag counts as a face you confirmed in Who's Who, so
/// it's never asked about again and it teaches the recognizer.
struct TagPeopleSheet: View {
    let photo: String
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var newFor: FaceRecord?
    @State private var newName = ""

    private var faces: [FaceRecord] {
        (library.photos[photo]?.faceRecords ?? []).filter { $0.vec.count == People.dim && $0.box.count == 4 }
            .sorted { $0.box[0] < $1.box[0] }   // left to right, as in the photo
    }
    private func owner(_ f: FaceRecord) -> Person? {
        library.faceOwner[Library.faceKey(photo, f)].flatMap { id in library.people.first { $0.id == id } }
    }
    private var sortedPeople: [Person] {
        library.people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if !Library.faceConsent {
                    Text("Turn on Who's Who first (in Who's Who), so the app can tell faces apart.")
                        .foregroundStyle(.secondary)
                } else if faces.isEmpty {
                    Text(library.photos[photo]?.faceRecords == nil
                         ? "This photo's faces haven't been read yet. Try again after the scan finishes."
                         : "No faces were found in this photo.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(faces, id: \.self) { f in row(f) }
                    } footer: {
                        Text("Tags count as faces you confirmed in Who's Who, so they're never asked about again and they help it recognize everyone else.")
                    }
                }
            }
            .navigationTitle("Tag people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("New person", isPresented: Binding(get: { newFor != nil }, set: { if !$0 { newFor = nil } })) {
                TextField("Name", text: $newName).textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) { newFor = nil; newName = "" }
                Button("Tag") {
                    if let f = newFor { tag(f, as: newName) }
                    newFor = nil; newName = ""
                }
            } message: { Text("Who is this?") }
        }
    }

    private func row(_ f: FaceRecord) -> some View {
        let who = owner(f)
        return HStack(spacing: 12) {
            FaceThumb(photo: photo, box: f.box, size: 56)
            Text(who?.name ?? "Not tagged")
                .font(Theme.label(17)).foregroundStyle(who == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
            Spacer()
            Menu {
                ForEach(sortedPeople) { p in
                    if p.id != who?.id { Button(p.name) { tag(f, as: p.name) } }
                }
                Button { newName = ""; newFor = f } label: { Label("New person…", systemImage: "plus") }
                if let who {
                    Button { library.removeFace(photo, f, from: who) } label: {
                        Label("Not \(who.name)", systemImage: "xmark")
                    }
                }
            } label: {
                Text(who == nil ? "Tag" : "Change").font(.body.bold())
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(who == nil ? "Tag this face" : "Change who this is")
        }
        .accessibilityElement(children: .contain)
    }

    private func tag(_ f: FaceRecord, as name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Moving a face from one person to another: it's no longer the first person.
        if let old = owner(f), old.name.caseInsensitiveCompare(name) != .orderedSame {
            library.removeFace(photo, f, from: old)
        }
        library.name([(photo, f)], as: name, birthday: nil)
    }
}

/// One number in the Who's Who face count.
struct TallyCell: View {
    let value: Int
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value.formatted()).font(Theme.label(22, relativeTo: .title3)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

/// The top photos (as ranked on Home, Overall) where no one is tagged or recognized, to tag them one by one.
struct UntaggedPhotosView: View {
    static let topCount = 500
    @EnvironmentObject var library: Library
    @State private var tagging: TagTarget?
    @State private var list: [Moment]?
    /// Choosing photos to take off this list (tap to pick, then Ignore).
    @State private var choosing = false
    @State private var chosen = Set<String>()
    /// The photos just ignored, for Undo.
    @State private var lastIgnored: [String] = []

    /// A face Tag people can name (the current recognizer's print, with a box), and not one you set aside.
    @MainActor static func taggable(_ f: FaceRecord, in photo: String, _ library: Library) -> Bool {
        f.vec.count == People.dim && f.box.count == 4 && !library.ignoredFaces.contains(Library.faceKey(photo, f))
    }

    /// Moments in the top 500 as Home shows them on Overall (similar shots folded, kids balanced, if those are on)
    /// that have faces but no named person, leaving out photos you ignored here.
    @MainActor static func untagged(_ moments: [Moment], library: Library, includingIgnored: Bool = false) -> [Moment] {
        let people = library.people
        let d = UserDefaults.standard
        let fold = d.object(forKey: AppMode.current.key("groupSimilar")) as? Bool ?? true, balance = d.bool(forKey: AppMode.current.key("balanceKids"))
        var top: [Moment]
        if balance {   // balancing needs the whole list
            top = KidBalance.order(fold ? SimilarShots.fold(moments) : moments, kids: KidBalance.kids(people))
        } else {
            top = fold ? SimilarShots.fold(moments, limit: topCount) : moments
        }
        let ignored = includingIgnored ? [] : library.untaggedIgnored
        return top.prefix(topCount).filter { m in
            !ignored.contains(m.best.id) && m.people.isEmpty
                && (m.best.faceRecords ?? []).contains { taggable($0, in: m.best.id, library) }
        }
    }

    private func refresh() { list = Self.untagged(library.moments, library: library); tidy() }
    /// How many ignored photos would come back (still in the top 500 with no one tagged).
    @State private var comeBack = 0

    private func ignore(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        library.ignoreUntagged(ids)
        lastIgnored = ids
        chosen = []; choosing = false
        refresh()
    }

    var body: some View {
        ScrollView {
            if list == nil {
                ProgressView().padding(.top, 40)
            } else if let list, list.isEmpty {
                ContentUnavailableView(library.moments.isEmpty ? "No photos yet" : comeBack > 0 ? "Nothing left to tag" : "Everyone's tagged", systemImage: "checkmark.circle",
                                       description: Text(library.moments.isEmpty ? "Photos show up here once your library has been scanned."
                                                         : "Every photo with faces in your top \(Self.topCount) has someone tagged or recognized, or you ignored it here."))
                    .padding(.top, 40)
            } else if let list {
                Text(choosing ? "Tap the photos to take off this list, then tap Ignore."
                     : "Tap a photo to tag who's in it. Hold one, or tap Select, to ignore photos you won't tag (they stay everywhere else).")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                    ForEach(list) { m in tile(m) }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if comeBack > 0 && !choosing {
                Button("Show the \(comeBack) ignored photo\(comeBack == 1 ? "" : "s") again") {
                    library.unignoreUntagged(Array(library.untaggedIgnored)); lastIgnored = []; refresh()
                }
                .font(.subheadline).padding(.vertical, 16)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if choosing {
                Button { ignore(Array(chosen)) } label: {
                    Text(chosen.isEmpty ? "Pick photos to ignore" : "Ignore \(chosen.count) photo\(chosen.count == 1 ? "" : "s")")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(chosen.isEmpty)
                .padding(.horizontal, 16).padding(.bottom, 8)
            } else if !lastIgnored.isEmpty {
                HStack {
                    Text("Ignored \(lastIgnored.count) photo\(lastIgnored.count == 1 ? "" : "s")").font(.subheadline)
                    Spacer()
                    Button("Undo") { library.unignoreUntagged(lastIgnored); lastIgnored = []; refresh() }.font(.subheadline.bold())
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Top \(Self.topCount), no one tagged")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(choosing ? "Cancel" : "Select") { choosing.toggle(); chosen = [] }
                    .disabled(!choosing && (list?.isEmpty ?? true))
            }
        }
        .sheet(item: $tagging) { t in TagPeopleSheet(photo: t.id) }
        // Worked out when the list changes (tagging someone takes their photo off this list).
        .onReceive(library.$moments.debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)) {
            list = Self.untagged($0, library: library); tidy()
        }
    }

    /// After the list changes: picks that left it are dropped, and Select ends if nothing's left.
    private func tidy() {
        let ids = Set((list ?? []).map(\.best.id))
        chosen = chosen.filter(ids.contains)
        if ids.isEmpty { choosing = false }
        comeBack = Self.untagged(library.moments, library: library, includingIgnored: true).filter { library.untaggedIgnored.contains($0.best.id) }.count
    }

    private func tile(_ m: Moment) -> some View {
        let faces = (m.best.faceRecords ?? []).filter { Self.taggable($0, in: m.best.id, library) }.count
        let picked = chosen.contains(m.best.id)
        return Button {
            if choosing { if picked { chosen.remove(m.best.id) } else { chosen.insert(m.best.id) } }
            else { tagging = TagTarget(id: m.best.id) }
        } label: {
            AssetImage(id: m.best.id, targetSide: 140)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { if choosing { PickMark(picked: picked, cornerRadius: 10) } }
                .overlay(alignment: .bottomLeading) {
                    Text("\(faces) face\(faces == 1 ? "" : "s")")
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(5)
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { tagging = TagTarget(id: m.best.id) } label: { Label("Tag people", systemImage: "person.crop.square") }
            Button { ignore([m.best.id]) } label: { Label("Ignore this photo", systemImage: "eye.slash") }
        }
        .accessibilityLabel("\(m.caption), \(faces) face\(faces == 1 ? "" : "s")" + (choosing ? (picked ? ", picked" : "") : ""))
        .accessibilityHint(choosing ? "Picks or unpicks this photo" : "Tag people")
        .accessibilityAction(named: "Ignore this photo") { ignore([m.best.id]) }
    }
}

/// Double-check: the faces counted as someone that the app is least sure about, one at a time — yes, no or skip.
struct DoubleCheckView: View {
    let person: Person
    @EnvironmentObject var library: Library
    @State private var queue: [(photo: String, face: FaceRecord)]?
    @State private var total = 0
    @State private var index = 0
    private enum Answer { case yes(Person?), no, skip }
    @State private var history: [Answer] = []
    /// The person as saved (not edits still open in their sheet).
    private var stored: Person? { library.people.first { $0.id == person.id } }

    var body: some View {
        ScrollView {   // scrolls on a small phone, so Undo and Skip stay reachable
        VStack(spacing: 18) {
            if let queue {
                if index < queue.count {
                    let f = queue[index]
                    Text("\(index + 1) of \(queue.count) to double-check, out of \(total) counted as \(person.name)")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    FaceThumb(photo: f.photo, box: f.face.box, size: 220)
                    AssetImage(id: f.photo, contentMode: .fit, targetSide: 300, cached: false)
                        .frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                    Text("Is this \(person.name)?").font(Theme.label(22, relativeTo: .title2))
                        .accessibilityLabel("Is this face \(person.name)? From a photo taken \(library.photos[f.photo]?.date.formatted(date: .abbreviated, time: .omitted) ?? "")")
                    HStack(spacing: 12) {
                        Button { answer(.no) } label: { Text("No").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.bordered)
                        Button { answer(.yes(nil)) } label: { Text("Yes").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                    HStack {
                        Button("Undo") { undo() }.disabled(history.isEmpty)
                        Spacer()
                        Button("Skip") { answer(.skip) }
                    }
                    .font(.subheadline)
                } else {
                    ContentUnavailableView {
                        Label(queue.isEmpty ? "Nothing to double-check" : "All done", systemImage: "checkmark.circle")
                    } description: {
                        Text(queue.isEmpty ? "Every face counted as \(person.name) is one you tagged or checked, or one the app is sure about."
                             : "Thanks! Your answers teach the app, so it gets \(person.name) right more often.")
                    }
                }
            } else {
                ProgressView("Checking \(person.name)'s photos…").padding(.top, 40)
            }
        }
        .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Double-check").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard queue == nil else { return }
            total = library.faces(of: person).count
            library.uncertainFaces(of: person) { queue = $0 }
        }
    }

    private func answer(_ a: Answer) {
        guard let queue, index < queue.count else { return }
        let f = queue[index]
        switch a {
        case .yes:
            guard let p = stored else { return }
            library.name([f], as: p.name, birthday: nil)                // now tagged by you: never asked again
            history.append(.yes(p)); index += 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        case .no: library.removeFace(f.photo, f.face, from: person)    // never counted as them again
        case .skip: library.skipFace(f.photo, f.face)                  // not asked again
        }
        history.append(a); index += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func undo() {
        guard let queue, let last = history.popLast(), index > 0 else { return }
        index -= 1
        let f = queue[index]
        switch last {
        case .yes(let before): library.unconfirmFace(f.photo, f.face, from: person, restoring: before)
        case .no: library.restoreFace(f.photo, f.face, to: person)
        case .skip: library.unskipFace(f.photo, f.face)
        }
    }
}
