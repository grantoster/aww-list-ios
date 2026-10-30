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
            .task(id: photo) {
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
    @State private var loading = true
    @State private var naming: NamingGroup?
    @State private var editing: Person?
    @State private var generation = 0
    /// Groups that look like someone already named: "Is this Maya?"
    @State private var suggestions: [Suggestion] = []

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
                    Text("Who's Who recognizes the people you name, like your kids, so you can see each person's best photos.")
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Turning it on makes face measurements (face prints) of up to 4 faces in each photo on your list, on this iPhone, so it can tell people apart. It re-reads those photos, which can take a while on a large library.", systemImage: "face.smiling")
                        Label("Face prints and names stay in Awwbum on this iPhone. They're never sent to us, Claude or Anthropic (they're part of your iPhone backup if backups are on).", systemImage: "lock.fill")
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
                    .buttonStyle(.borderedProminent)
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
                if !library.people.isEmpty {
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
                                HStack(spacing: -10) {
                                    ForEach(Array(s.faces.prefix(4).enumerated()), id: \.offset) { _, f in
                                        FaceThumb(photo: f.photo, box: f.face.box, size: 48)
                                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                    }
                                    Spacer(minLength: 16)
                                    Text("\(s.faces.count) photos").font(.subheadline).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text("Is this \(s.person.name)?").font(.headline)
                                    Spacer()
                                    Button("No") { library.declinedChecks.insert(s.id); regroup() }.buttonStyle(.bordered)
                                    Button("Yes") {
                                        // By id, in case they were renamed since.
                                        if let p = library.people.first(where: { $0.id == s.person.id }) {
                                            library.name(s.faces, as: p.name, birthday: nil)
                                        }
                                        library.declinedChecks.insert(s.id)
                                    }
                                    .buttonStyle(.borderedProminent)
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
                        Text(Shared.scanner.isScanning ? "Reading faces in your photos… they show up here as they're found."
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
                    Text("Stricter if groups mix different people; looser if one person is split across many groups. Kids' faces change a lot, so naming a child once or twice per year or so helps the app follow them.")
                }
                Section {
                    Button("Turn off Who's Who") { faceConsent = false; library.setFaceConsent(false) }
                } footer: {
                    Text("Stops recognizing people and deletes every Who's Who face print. Names and birthdays stay; to recognize someone again, turn Who's Who back on and name a few of their faces with the same name.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Who's Who")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $naming, onDismiss: regroup) { g in NameSheet(faces: g.faces) }
            .sheet(item: $editing, onDismiss: regroup) { p in PersonSheet(person: p) }
            .task { regroup() }
            .onReceive(Shared.scanner.$isScanning) { scanning in if !scanning { regroup() } }   // new face prints
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
        let named = library.people
        let declined = library.declinedChecks
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
                asks.append(Suggestion(id: key, person: p, faces: c.map { faces[$0] }))
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
    let faces: [(photo: String, face: FaceRecord)]
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hasBirthday = false
    @State private var birthday = Calendar.current.startOfDay(for: Date())

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                        ForEach(Array(faces.prefix(12).enumerated()), id: \.offset) { _, f in
                            FaceThumb(photo: f.photo, box: f.face.box, size: 64)
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("\(faces.count) photos. If these aren't all one person, try Stricter grouping.")
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
                        DatePicker("Birthday", selection: $birthday, in: ...Date(), displayedComponents: .date)
                    }
                } footer: {
                    Text("With a birthday, this person's photos are sorted into Baby, Toddler and Kid exactly.")
                }
            }
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.name(faces, as: name, birthday: hasBirthday ? Calendar.current.startOfDay(for: birthday) : nil)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
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
                Section {
                    Toggle("Birthday", isOn: Binding(get: { person.birthday != nil },
                                                     set: { person.birthday = $0 ? (person.birthday ?? Calendar.current.startOfDay(for: Date())) : nil }))
                    if person.birthday != nil {
                        DatePicker("Born", selection: Binding(get: { person.birthday ?? Date() },
                                                              set: { person.birthday = Calendar.current.startOfDay(for: $0) }),
                                   in: ...Date(), displayedComponents: .date)
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
