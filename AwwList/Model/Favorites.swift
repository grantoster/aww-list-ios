import Photos

/// The one change Awwbum can make to your photo library: a photo's favorite (the heart in Photos).
/// It can't edit, add, hide or delete anything; a build check fails if this file does anything else.
enum Favorites {
    /// Whether Photos has this photo as a favorite (false if it isn't visible to the app).
    static func isFavorite(_ id: String) -> Bool {
        AssetImage.visible([id]).firstObject?.isFavorite ?? false
    }

    /// Sets or clears the favorite on these photos in Photos. Only photos the app can see (never the Hidden album).
    /// Returns how many photos were changed: nil if Photos refused (for example, access was turned off),
    /// 0 if none of them can be found any more (deleted, or hidden since the scan).
    static func set(_ ids: [String], favorite: Bool) async -> Int? {
        let found = AssetImage.visible(ids)
        var assets: [PHAsset] = []
        found.enumerateObjects { a, _, _ in assets.append(a) }
        guard !assets.isEmpty else { return 0 }
        let toChange = assets
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for asset in toChange {
                    PHAssetChangeRequest(for: asset).isFavorite = favorite
                }
            }
            return toChange.count
        } catch {
            return nil
        }
    }
}
