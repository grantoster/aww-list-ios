import Foundation

/// Builds a short, specific description of a photo from what the on-device models saw:
/// who is in it and how they look, what's around them, and the day it was taken.
/// For example "Belly-laugh baby in the high chair", "Two big smiles by the Christmas tree", "Halloween costume grin".
enum Describe {
    enum Kind { case moment, activity, container, place }
    /// Scene and object labels from Apple's image classifier (kept only above 0.6 confidence), and how they read
    /// in a caption. Earlier entries win when several are present, so the more specific moment goes first.
    /// Broad labels that fire on decor or toys (art, candle, pillow, toy, bride…) are deliberately left out,
    /// and guessed venues are phrased by the object, not the place ("with a pumpkin", not "at the pumpkin patch").
    static let scenes: [(labels: [String], phrase: String, kind: Kind)] = [
        (["birthday_cake"], "with the birthday cake", .moment),
        (["santa_claus"], "with Santa", .moment),
        (["christmas_tree"], "by the Christmas tree", .moment),
        (["jack_o_lantern"], "with the jack-o'-lantern", .moment),
        (["easter_egg"], "with Easter eggs", .moment),
        (["graduation"], "at graduation", .moment),
        (["wedding_cake"], "at a wedding", .moment),
        (["fireworks"], "at the fireworks", .moment),
        (["costume"], "in costume", .moment),
        (["cupcake"], "with a cupcake", .moment),
        (["balloon"], "with balloons", .moment),
        (["pumpkin"], "with a pumpkin", .moment),
        (["snowman"], "with the snowman", .moment),
        (["sledding"], "sledding", .activity),
        (["snow", "snowball"], "in the snow", .place),
        (["carousel", "ferris_wheel", "rollercoaster", "amusement_park"], "at the fair", .place),
        (["zoo"], "at the zoo", .place),
        (["aquarium"], "at the aquarium", .place),
        (["farm"], "at the farm", .place),
        (["orchard"], "at the orchard", .place),
        (["swing_playground", "slide_toy", "seesaw", "playground"], "at the playground", .place),
        (["trampoline"], "on the trampoline", .activity),
        (["bicycle", "tricycle"], "on a bike", .activity),
        (["soccer"], "at soccer", .activity), (["baseball", "softball"], "at baseball", .activity),
        (["basketball"], "at basketball", .activity),
        (["ballet", "ballet_dancer"], "dancing", .activity),
        (["gymnastics"], "at gymnastics", .activity),
        (["stuffed_animals"], "with a stuffed animal", .moment),
        (["book"], "with a book", .moment),
        (["blocks", "train_toy", "vehicle_toy", "puzzles"], "playing with toys", .activity),
        (["paintbrush", "easel"], "making art", .activity),
        (["piano", "guitar", "ukulele"], "making music", .activity),
        (["ice_cream", "popsicle"], "with ice cream", .moment),
        (["pizza"], "with pizza", .moment), (["pancake", "waffle"], "at breakfast", .activity),
        (["high_chair"], "in the high chair", .container),
        (["crib"], "in the crib", .container),
        (["stroller"], "in the stroller", .container),
        (["car_seat"], "in the car seat", .container),
        (["dog", "retriever", "terrier", "spaniel", "poodle"], "with the dog", .moment),
        (["cat", "kitten"], "with the cat", .moment),
        (["horse"], "with a horse", .moment),
        (["airplane"], "on a plane", .place),
        (["museum"], "at the museum", .place),
        (["restaurant"], "out to eat", .place),
        (["kitchen", "kitchen_room"], "in the kitchen", .place),
        (["camping"], "camping", .activity),
        (["hiking"], "on a hike", .activity),
        (["sunflower", "tulip", "flower_arrangement"], "among the flowers", .place),
        (["garden"], "in the garden", .place),
        (["park"], "at the park", .place),
        (["bedroom"], "in bed", .container),
        (["sofa", "living_room"], "on the couch", .place)
    ]
    static let sceneLabels: Set<String> = Set(scenes.flatMap(\.labels))

    /// The first scene phrase that fits this lead: no activities for someone asleep, and no
    /// one-person spots (crib, high chair, bike…) for a group.
    static func scenePhrase(_ labels: [String], asleep: Bool = false, group: Bool = false) -> String? {
        let have = Set(labels)
        return scenes.first { sc in
            if have.isDisjoint(with: sc.labels) { return false }
            if asleep && sc.kind == .activity { return false }
            if group && sc.kind == .container { return false }
            return true
        }?.phrase
    }

    /// A holiday the date falls on, if any.
    static func holiday(_ date: Date, calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c
    }()) -> String? {
        let c = calendar.dateComponents([.month, .day, .weekday, .weekdayOrdinal], from: date)
        switch (c.month ?? 0, c.day ?? 0) {
        case (12, 24): return "on Christmas Eve"
        case (12, 25): return "on Christmas"
        case (10, 31): return "on Halloween"
        case (7, 4): return "on the Fourth of July"
        case (1, 1): return "on New Year's Day"
        case (2, 14): return "on Valentine's Day"
        case (11, _) where c.weekday == 5 && c.weekdayOrdinal == 4: return "on Thanksgiving"
        default: return nil
        }
    }

    /// The opening words: who, and how they look.
    static func lead(_ s: Signals) -> String {
        let faces = s.faces
        let smiles = faces.filter(\.smile).count
        let baby = s.babyConfidence > 0.5
        let kid = baby ? "baby" : "kiddo"
        let subj = s.subject
        if faces.count >= 3 {
            if smiles == faces.count { return "Everyone all smiles" }
            if smiles >= 2 { return "Smiles all around" }
            return "The whole crew together"
        }
        if faces.count == 2 {
            if smiles == 2 { return "Two big smiles" }
            if smiles == 1 { return baby ? "Cuddles and smiles" : "Grinning side by side" }
            return baby ? "Snuggling baby" : "Side by side"
        }
        guard let f = subj else { return baby ? "Little baby moment" : "Little moment" }
        let close = f.area > 0.12
        switch (f.smile, f.eyesClosed) {
        case (true, true): return baby ? "Belly-laugh baby" : "Giggling so hard"   // smiling with eyes squeezed shut
        case (true, false): return close ? (baby ? "Baby grin up close" : "Big grin up close") : (baby ? "Smiling baby" : "Big smile")
        case (false, true): return baby ? "Sweet sleeping baby" : "Sleepy \(kid)"
        case (false, false): return close ? (baby ? "Wide-eyed baby" : "Thoughtful close-up") : (baby ? "Curious baby" : "Little explorer")
        }
    }

    /// "Lead + scene", or "Lead + holiday" when there is no scene, e.g. "Smiling baby with the birthday cake".
    static func caption(_ s: Signals, date: Date?) -> String {
        var text = lead(s)
        let asleep = s.faces.count == 1 && s.subject?.eyesClosed == true && s.subject?.smile == false
        if let scene = scenePhrase(s.labels, asleep: asleep, group: s.faces.count >= 2) {
            text += " " + scene
            if scene == "in costume", let d = date, holiday(d) == "on Halloween" { text = lead(s) + " in a Halloween costume" }
        } else if let d = date, let h = holiday(d) {
            text += " " + h
        }
        return text
    }
}

/// Decides from a photo's file details whether it is clearly AI-generated or heavily edited.
/// Only clear evidence counts: a provenance tag, an AI or face-retouching app in the file, or a file that
/// no camera produces. Photos sent through messaging apps (which strip details) are not penalized.
enum Provenance {
    static let aiTools = ["midjourney", "dall-e", "dall·e", "dalle", "openai", "chatgpt", "stable diffusion",
                          "stablediffusion", "stable_diffusion", "adobe firefly", "google imagen", "gemini", "image playground",
                          "imageplayground", "ideogram", "leonardo.ai", "nightcafe", "dreamstudio", "image creator",
                          "copilot designer", "meta ai", "grok", "flux.1", "black forest labs"]
    static let retouchApps = ["adobe photoshop", "facetune", "faceapp", "lensa", "remini", "picsart", "airbrush",
                              "beautyplus", "youcam perfect", "youcam makeup", "meitu", "b612", "peachy", "perfect365", "photoroom"]

    struct FileInfo {
        var filename: String = ""
        var software: String = ""        // TIFF Software, XMP CreatorTool, etc.
        var aiMarker: Bool = false       // IPTC/C2PA "trainedAlgorithmicMedia" found in the file
        var cameraMake: String = ""      // TIFF Make (empty when there is no camera information)
        var isPNG: Bool = false
        var headerRead: Bool = true      // false when the original's details couldn't be read (iCloud-only)
    }

    /// File-name patterns these tools use when you save their output (kept narrow: ordinary words like
    /// "imagen", Spanish for "image", must not trip it).
    static let aiFilenames = ["dall-e", "dall·e", "midjourney", "chatgpt image", "gemini_generated",
                              "adobe firefly", "stablediffusion", "stable_diffusion", "ideogram", "imageplayground"]
    static let retouchFilenames = ["faceapp", "facetune", "lensa_", "remini_", "remini-"]
    /// Photo editors that adjust light and color but don't reshape people; never counted as retouching.
    static let ordinaryEditors = ["adobe photoshop lightroom", "adobe photoshop express", "adobe photoshop camera raw", "camera raw", "lightroom", "photoshop express", "snapseed", "vsco"]

    /// "AI image", "Edited" or nil.
    static func verdict(_ f: FileInfo) -> String? {
        let name = f.filename.lowercased(), sw = f.software.lowercased()
        if f.aiMarker { return "AI image" }
        if aiTools.contains(where: { sw.contains($0) }) || aiFilenames.contains(where: { name.contains($0) }) { return "AI image" }
        // Adobe Firefly downloads: "Firefly <prompt> 12345.jpg"
        if name.hasPrefix("firefly "), name.range(of: #"\d{3,}\.\w+$"#, options: .regularExpression) != nil { return "AI image" }
        let swNoOrdinary = ordinaryEditors.reduce(sw) { $0.replacingOccurrences(of: $1, with: "") }
        if retouchApps.contains(where: { swNoOrdinary.contains($0) }) || retouchFilenames.contains(where: { name.contains($0) }) { return "Edited" }
        // Cameras save HEIC or JPEG with camera details; a PNG with none came out of an app or an editor.
        if f.isPNG && f.headerRead && f.cameraMake.isEmpty { return "Not a camera photo" }
        return nil
    }

    /// True when the file says the whole image was generated by AI (IPTC digital source type
    /// "trainedAlgorithmicMedia", in XMP or a C2PA manifest). Real photos with an AI touch-up
    /// ("compositeWithTrainedAlgorithmicMedia": Clean Up, Magic Eraser, Best Take) are kept.
    static func hasAIMarker(_ data: Data) -> Bool {
        let needle = Data("trainedAlgorithmicMedia".utf8)
        let composite = Data("compositeWith".utf8)
        var from = data.startIndex
        while let r = data.range(of: needle, in: from..<data.endIndex) {
            // Exact value only: "…/trainedAlgorithmicMedia" (lowercase t, not part of "compositeWithTrained…").
            let lead = r.lowerBound >= composite.count ? data[(r.lowerBound - composite.count)..<r.lowerBound] : Data()
            if lead != composite { return true }
            from = r.upperBound
        }
        return false
    }
}
