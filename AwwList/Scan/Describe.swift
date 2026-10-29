import Foundation

/// Builds a short, specific description of a photo from what the on-device models saw:
/// who is in it and how they look, what's around them, and the day it was taken.
/// For example "Belly-laugh baby in the high chair", "Two big smiles by the Christmas tree", "Halloween costume grin".
enum Describe {
    /// Scene and object labels from Apple's image classifier, and how they read in a caption.
    /// Earlier entries win when several are present, so the more specific moment goes first.
    static let scenes: [(labels: [String], phrase: String)] = [
        (["birthday_cake"], "with the birthday cake"),
        (["santa_claus"], "with Santa"),
        (["christmas_tree", "christmas_decoration", "wreath", "poinsettia"], "by the Christmas tree"),
        (["jack_o_lantern"], "with the jack-o'-lantern"),
        (["easter_egg"], "on the Easter egg hunt"),
        (["graduation"], "at graduation"),
        (["wedding", "wedding_cake", "bride", "groom"], "at a wedding"),
        (["fireworks", "sparkler"], "at the fireworks"),
        (["gift"], "opening presents"),
        (["costume"], "in costume"),
        (["cake", "cupcake", "candle"], "with cake"),
        (["balloon", "balloon_hotair"], "with balloons"),
        (["pumpkin"], "at the pumpkin patch"),
        (["snowman"], "with the snowman"),
        (["sled", "sledding"], "sledding"),
        (["snow", "snowball", "blizzard"], "in the snow"),
        (["carousel", "ferris_wheel", "rollercoaster", "amusement_park", "fairground", "carnival"], "at the fair"),
        (["zoo", "giraffe", "elephant", "zebra", "lion", "tiger", "panda", "kangaroo"], "at the zoo"),
        (["aquarium", "fishtank"], "at the aquarium"),
        (["farm", "goat", "sheep", "cow", "pig", "donkey", "llama", "poultry"], "at the farm"),
        (["orchard"], "at the orchard"),
        (["swing_playground", "slide_toy", "seesaw", "playground"], "at the playground"),
        (["trampoline"], "on the trampoline"),
        (["bicycle", "tricycle"], "on a bike"),
        (["scooter", "skateboard"], "on wheels"),
        (["soccer"], "at soccer"), (["baseball", "softball"], "at baseball"), (["basketball"], "at basketball"),
        (["ballet", "ballet_dancer", "dancing"], "dancing"),
        (["gymnastics"], "at gymnastics"),
        (["stuffed_animals"], "with a stuffed animal"),
        (["book", "library"], "with a book"),
        (["blocks", "train_toy", "vehicle_toy", "toy", "puzzles", "games"], "playing with toys"),
        (["painting", "paintbrush", "art", "easel"], "making art"),
        (["piano", "guitar", "ukulele", "drum", "musical_instrument"], "making music"),
        (["ice_cream", "popsicle", "frozen_dessert"], "with ice cream"),
        (["pizza"], "with pizza"), (["pancake", "waffle"], "at breakfast"),
        (["high_chair"], "in the high chair"),
        (["crib"], "in the crib"),
        (["stroller"], "in the stroller"),
        (["car_seat"], "in the car seat"),
        (["dog", "canine", "retriever", "terrier", "spaniel", "poodle"], "with the dog"),
        (["cat", "kitten", "feline"], "with the cat"),
        (["horse", "equestrian"], "with a horse"),
        (["airplane", "airport"], "on a trip"),
        (["museum"], "at the museum"),
        (["restaurant"], "out to eat"),
        (["kitchen", "kitchen_room", "kitchen_countertop"], "in the kitchen"),
        (["camping", "tent"], "camping"),
        (["hiking", "trail", "forest"], "on a hike"),
        (["flower", "sunflower", "blossom", "tulip", "daisy", "flower_arrangement"], "among the flowers"),
        (["garden"], "in the garden"),
        (["park"], "at the park"),
        (["bed", "bedroom", "pillow"], "in bed"),
        (["sofa", "living_room"], "on the couch")
    ]
    static let sceneLabels: Set<String> = Set(scenes.flatMap(\.labels))

    static func scenePhrase(_ labels: [String]) -> String? {
        let have = Set(labels)
        return scenes.first { !have.isDisjoint(with: $0.labels) }?.phrase
    }

    /// A holiday the date falls on, if any.
    static func holiday(_ date: Date, calendar: Calendar = .current) -> String? {
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
            if smiles == 1 { return baby ? "Baby and a big smile" : "Grinning side by side" }
            return baby ? "Snuggled up with baby" : "Side by side"
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
        if let scene = scenePhrase(s.labels) {
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
                          "stablediffusion", "stable_diffusion", "firefly", "imagen", "gemini", "image playground",
                          "imageplayground", "ideogram", "leonardo.ai", "nightcafe", "dreamstudio", "image creator",
                          "copilot", "meta ai", "grok", "flux"]
    static let retouchApps = ["photoshop", "facetune", "faceapp", "lensa", "remini", "picsart", "airbrush",
                              "beautyplus", "youcam", "meitu", "b612", "peachy", "perfect365", "photoroom"]

    struct FileInfo {
        var filename: String = ""
        var software: String = ""        // TIFF Software, XMP CreatorTool, etc.
        var aiMarker: Bool = false       // IPTC/C2PA "trainedAlgorithmicMedia" found in the file
        var cameraMake: String = ""      // TIFF Make (empty when there is no camera information)
        var isPNG: Bool = false
    }

    /// File-name patterns these tools use when you save their output (kept narrow: ordinary words like
    /// "imagen", Spanish for "image", must not trip it).
    static let aiFilenames = ["dall-e", "dall·e", "dalle", "midjourney", "chatgpt image", "gemini_generated",
                              "firefly", "stablediffusion", "stable_diffusion", "ideogram", "imageplayground"]
    static let retouchFilenames = ["faceapp", "facetune", "lensa", "remini"]

    /// "AI image", "Edited" or nil.
    static func verdict(_ f: FileInfo) -> String? {
        let name = f.filename.lowercased(), sw = f.software.lowercased()
        if f.aiMarker { return "AI image" }
        if aiTools.contains(where: { sw.contains($0) }) || aiFilenames.contains(where: { name.contains($0) }) { return "AI image" }
        if retouchApps.contains(where: { sw.contains($0) }) || retouchFilenames.contains(where: { name.contains($0) }) { return "Edited" }
        // Cameras save HEIC or JPEG with camera details; a PNG with none came out of an app or an editor.
        if f.isPNG && f.cameraMake.isEmpty { return "Edited" }
        return nil
    }

    /// True when the raw file bytes carry an AI-provenance marker (IPTC digital source type or a C2PA manifest).
    static func hasAIMarker(_ data: Data) -> Bool {
        for needle in ["trainedAlgorithmicMedia", "TrainedAlgorithmicMedia", "compositeSynthetic"] {
            if data.range(of: Data(needle.utf8)) != nil { return true }
        }
        return false
    }
}
