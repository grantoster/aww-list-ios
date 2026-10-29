import SwiftUI

/// A round crop of one face from a photo.
struct FaceThumb: View {
    let photo: String
    let box: [Float]
    var size: CGFloat = 56
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        Circle().fill(Color.secondary.opacity(0.15))
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipShape(Circle())
            .frame(width: size, height: size)
            .task(id: photo) {
                guard let full = await AssetImage.load(id: photo, size: CGSize(width: 900, height: 900), mode: .aspectFit) else { return }
                image = Self.crop(full, box: box)
            }
            .accessibilityHidden(true)
    }

    /// Crops a face (normalized, bottom-left origin) with some room around it.
    static func crop(_ img: UIImage, box: [Float]) -> UIImage? {
        guard box.count == 4 else { return img }
        let upright = UIGraphicsImageRenderer(size: img.size).image { _ in img.draw(at: .zero) }
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

    struct NamingGroup: Identifiable {
        let id = UUID()
        let faces: [(photo: String, face: FaceRecord)]
    }

    var body: some View {
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
                Section {
                    if loading {
                        HStack { ProgressView(); Text("Finding faces…").foregroundStyle(.secondary) }
                    } else if groups.isEmpty {
                        Text(library.moments.isEmpty ? "Faces show up here once your photos are scanned."
                                                     : "Everyone who shows up often has a name.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(groups.prefix(30).enumerated()), id: \.offset) { _, g in
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
                    Text("Faces that look alike are grouped. Name a group, and giving two groups the same name joins them. Everything stays on this iPhone.")
                }
                Section {
                    Picker("Grouping", selection: Binding(get: { library.strictness }, set: { library.setStrictness($0); regroup() })) {
                        Text("Stricter").tag(0)
                        Text("Normal").tag(1)
                        Text("Looser").tag(2)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Stricter if groups mix different people; looser if one person is split across many groups. Kids' faces change a lot, so you may need to name a child a few times across the years.")
                }
            }
            .navigationTitle("Who's Who")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $naming, onDismiss: regroup) { g in NameSheet(faces: g.faces) }
            .sheet(item: $editing, onDismiss: regroup) { p in PersonSheet(person: p) }
            .task { regroup() }
        }
    }

    private func summary(_ p: Person) -> String {
        let n = library.moments.filter { $0.people.contains(p.id) }.count
        var s = "\(n) moment\(n == 1 ? "" : "s")"
        if let b = p.birthday { s += " · born " + b.formatted(date: .abbreviated, time: .omitted) }
        return s
    }

    /// Groups the unnamed faces off the main thread; groups of at least 3 photos are shown.
    private func regroup() {
        loading = true
        let faces = library.unnamedFaces()
        let t = library.threshold
        Task.detached(priority: .userInitiated) {
            let vecs = faces.map { People.floats($0.face.vec) }
            let clusters = People.cluster(vecs, threshold: t).filter { $0.count >= 3 }.map { $0.map { faces[$0] } }
            await MainActor.run { groups = clusters; loading = false }
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
