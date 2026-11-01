import Foundation
import Photos

/// The only place Awwbum looks at photos in the Hidden album (allowed by the owner, and checked by the build):
/// - Settings → What's left out → Hidden in Apple Photos lists them, only while that screen is open. (iOS shares
///   them only when the Hidden album's lock is off in Settings → Photos.)
/// - Photos you add from there are the only hidden ones read, ranked and shown in your list.
/// Hidden photos are never sent to Claude, whether added or not (see Library.neverSend and ClaudeService.jpeg).
enum HiddenPhotos {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var added = Set<String>()
    nonisolated(unsafe) private static var browsing = false

    /// The hidden photos you added to your list (kept in step by Library).
    static func setAdded(_ ids: Set<String>) { lock.lock(); added = ids; lock.unlock() }
    static func isAdded(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return added.contains(id) }
    static var addedIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return added }

    /// True only while the Hidden photos screen is open.
    static func setBrowsing(_ on: Bool) { lock.lock(); browsing = on; lock.unlock() }
    static var isBrowsing: Bool { lock.lock(); defer { lock.unlock() }; return browsing }

    private static func hiddenOptions() -> PHFetchOptions {
        let o = PHFetchOptions()
        o.includeHiddenAssets = true   // the one exception (see above)
        return o
    }

    /// Every photo in the Hidden album, newest first. Only while that screen is open.
    static func all() -> [String] {
        guard isBrowsing else { return [] }
        let o = hiddenOptions()
        o.predicate = NSPredicate(format: "mediaType == %d AND isHidden == YES", PHAssetMediaType.image.rawValue)
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var out: [String] = []
        PHAsset.fetchAssets(with: o).enumerateObjects { a, _, _ in if a.isHidden { out.append(a.localIdentifier) } }
        return out
    }

    /// Hidden photos you added, as assets (for scanning and showing them). Photos no longer hidden or deleted
    /// simply aren't returned.
    static func addedAssets(_ ids: Set<String>? = nil) -> [PHAsset] {
        let want = (ids ?? addedIDs).intersection(addedIDs)
        guard !want.isEmpty else { return [] }
        let o = hiddenOptions()
        o.predicate = NSPredicate(format: "localIdentifier IN %@", Array(want))
        var out: [PHAsset] = []
        PHAsset.fetchAssets(with: o).enumerateObjects { a, _, _ in if a.isHidden { out.append(a) } }
        return out
    }

    /// One hidden photo to show: an added one, or any while browsing.
    static func asset(_ id: String) -> PHAsset? {
        guard isAdded(id) || isBrowsing else { return nil }
        let o = hiddenOptions()
        o.predicate = NSPredicate(format: "localIdentifier == %@", id)
        guard let a = PHAsset.fetchAssets(with: o).firstObject, a.isHidden else { return nil }
        return a
    }
}
