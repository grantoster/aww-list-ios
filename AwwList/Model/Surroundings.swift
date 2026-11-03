import Foundation

/// The Setting filter on Home: what kind of place or occasion a photo is from (outdoors, a party, sports...), from
/// what Apple's image labels saw in it. A few common kinds are built in; the rest are learned from your own photos:
/// the things that show up most often in them become choices too, and the list is ordered by how many photos
/// you have of each, so it keeps up with the kinds of photos you take.
struct SceneKind: Identifiable, Hashable {
    let id: String
    let name: String
    let labels: Set<String>
    /// Also counts photos taken on a holiday (Christmas, Halloween, the Fourth of July...).
    var holidays = false
}

enum Surroundings {
    static let builtIn: [SceneKind] = [
        SceneKind(id: "outdoors", name: "Outdoors", labels: ["outdoor", "sky", "grass", "tree", "plant", "park", "garden", "field",
            "forest", "mountain", "hill", "hiking", "camping", "playground", "swing_playground", "slide_toy", "seesaw", "trail",
            "sunset_sunrise", "flower", "lawn", "yard", "backyard", "farm", "orchard"]),
        SceneKind(id: "beach", name: "Beach & water", labels: ["beach", "sand", "ocean", "shore", "sea", "coast", "lake", "pool",
            "swimming_pool", "water_body", "waterways", "river", "creek", "waterfall", "swimming", "surfing", "boat", "pier"]),
        SceneKind(id: "parties", name: "Holidays & parties", labels: ["birthday_cake", "cupcake", "balloon", "christmas_tree",
            "santa_claus", "jack_o_lantern", "easter_egg", "costume", "fireworks", "gift", "party", "celebration",
            "wedding_cake", "wedding", "pumpkin", "candle", "decoration", "christmas_decoration", "halloween"], holidays: true),
        SceneKind(id: "sports", name: "Sports", labels: ["sport", "sports", "soccer", "baseball", "softball", "basketball",
            "football", "american_football", "volleyball", "tennis", "golf", "hockey", "gymnastics", "ballet", "ballet_dancer",
            "martial_arts", "karate", "skateboard", "trampoline", "bicycle", "tricycle", "ball", "stadium", "sports_field"]),
        SceneKind(id: "snow", name: "Snow", labels: ["snow", "snowball", "snowman", "sledding", "skiing", "snowboarding", "ice"]),
        SceneKind(id: "outings", name: "Outings & trips", labels: ["zoo", "aquarium", "amusement_park", "carousel", "ferris_wheel",
            "rollercoaster", "museum", "airplane", "airport", "train", "theater", "stage", "concert", "fair"]),
        SceneKind(id: "food", name: "Food & eating out", labels: ["food", "meal", "restaurant", "pizza", "ice_cream", "popsicle",
            "pancake", "waffle", "dessert", "cake", "breakfast", "dining_table"]),
        SceneKind(id: "animals", name: "Animals", labels: ["animal", "dog", "cat", "kitten", "horse", "bird", "fish", "retriever",
            "terrier", "spaniel", "poodle", "pet", "farm_animal"]),
        SceneKind(id: "home", name: "Indoors & home", labels: ["indoor", "living_room", "bedroom", "kitchen", "kitchen_room", "sofa",
            "couch", "bed", "crib", "high_chair", "nursery", "home", "interior_room"]),
    ]

    /// Labels too general to be a useful choice of their own (they'd match almost every photo).
    static let tooGeneral: Set<String> = ["people", "adult", "child", "baby", "person", "portrait", "face", "smile", "hair",
        "clothing", "shirt", "dress", "structure", "material", "textile", "wood_processed", "conveyance", "furniture",
        "machine", "consumer_electronics", "jewelry", "headgear", "hat", "toy", "screenshot", "document", "selfie",
        "blue_sky", "cloudy", "light", "night_sky", "wall", "floor", "window", "room", "interior_room", "outdoor", "indoor"]

    static func matches(_ p: PhotoScore, _ kind: SceneKind) -> Bool {
        if let s = p.scenes, s.contains(where: kind.labels.contains) { return true }
        return kind.holidays && Describe.holiday(p.date) != nil
    }

    /// The choices to offer for these photos, most photos first: the built-in kinds you have at least 3 photos of,
    /// then up to 8 things seen most often in your own photos (at least 8 photos each) that no built-in kind covers.
    static func menu(_ moments: [Moment]) -> [(kind: SceneKind, count: Int)] {
        var counts: [String: Int] = [:], built: [String: Int] = [:]
        let covered = Set(builtIn.flatMap(\.labels))
        for m in moments {
            let p = m.best
            for k in builtIn where matches(p, k) { built[k.id, default: 0] += 1 }
            for l in Set(p.scenes ?? []) where !covered.contains(l) && !tooGeneral.contains(l) { counts[l, default: 0] += 1 }
        }
        let fixed = builtIn.compactMap { k in (built[k.id] ?? 0) >= 3 ? (kind: k, count: built[k.id]!) : nil }
        let learned = counts.filter { $0.value >= 8 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8).map { (kind: SceneKind(id: "label:" + $0.key, name: pretty($0.key), labels: [$0.key]), count: $0.value) }
        return (fixed + learned).sorted { $0.count != $1.count ? $0.count > $1.count : $0.kind.id < $1.kind.id }
    }

    /// "ferris_wheel" → "Ferris wheel".
    static func pretty(_ label: String) -> String {
        let s = label.replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Words for search (the kinds a photo belongs to).
    static func searchText(_ p: PhotoScore) -> String {
        builtIn.filter { matches(p, $0) }.map(\.name).joined(separator: " ")
            + " " + (p.scenes ?? []).map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " ")
    }
}
