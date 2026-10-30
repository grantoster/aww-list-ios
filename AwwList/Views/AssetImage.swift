import SwiftUI
import Photos

/// Shows one photo from the library, loaded at the size it's drawn.
struct AssetImage: View {
    let id: String
    var contentMode: ContentMode = .fill
    var targetSide: CGFloat = 400

    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        // The placeholder sets the size and the photo is drawn on top of it, so a wide photo filling a tile
        // can never make the tile (and the whole screen) wider than the space it was given.
        Color.secondary.opacity(0.15)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                }
            }
            .clipped()
            .contentShape(Rectangle())   // taps land on the visible photo, not its cropped-off overflow
        .task(id: id) {
            let px = targetSide * scale
            let key = "\(id)|\(Int(px))|\(contentMode == .fit ? 1 : 0)" as NSString
            if let hit = Self.thumbs.object(forKey: key) { image = hit; return }
            image = nil   // never leave the previous photo showing while a different one loads
            // Show the quick low-resolution version as soon as Photos has it, then the sharp one.
            let full = await Self.load(id: id, size: CGSize(width: px, height: px),
                                       mode: contentMode == .fit ? .aspectFit : .aspectFill,
                                       preview: { img in Task { @MainActor in if image == nil { image = img } } })
            if let full { image = full; Self.thumbs.setObject(full, forKey: key) }
        }
    }

    static let manager = PHCachingImageManager()
    /// Recently drawn photos, so scrolling back or reopening a list is instant. Emptied whenever the photo library
    /// changes (so a photo hidden or deleted meanwhile is never shown from here), and by iOS under memory pressure.
    static let thumbs: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.countLimit = 400; return c }()

    /// Looks photos up by id the same way the scan does, so the Hidden album is never looked at: a photo that's
    /// hidden simply isn't found.
    nonisolated static func visible(_ ids: [String]) -> PHFetchResult<PHAsset> {
        let o = PHFetchOptions()
        o.includeHiddenAssets = false
        o.predicate = NSPredicate(format: "localIdentifier IN %@", ids)
        return PHAsset.fetchAssets(with: o)
    }

    /// Loads one image. Cancelled automatically when the view scrolls away; returns the best image delivered.
    static func load(id: String, size: CGSize, mode: PHImageContentMode,
                     preview: (@Sendable (UIImage) -> Void)? = nil) async -> UIImage? {
        guard let asset = visible([id]).firstObject else { return nil }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = true
        let box = RequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
                let rid = manager.requestImage(for: asset, targetSize: size, contentMode: mode, options: opts) { img, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded { box.keep(img); if let img { preview?(img) }; return }
                    box.finish { cont.resume(returning: img ?? box.lastImage) }
                }
                box.setID(rid)
            }
        } onCancel: {
            if let rid = box.id { manager.cancelImageRequest(rid) }
        }
    }
}

/// Small lock-protected holder so the request can resume exactly once and be cancelled from another thread.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private(set) var id: PHImageRequestID?
    private(set) var lastImage: UIImage?
    func setID(_ v: PHImageRequestID) { lock.lock(); id = v; lock.unlock() }
    func keep(_ img: UIImage?) { lock.lock(); if img != nil { lastImage = img }; lock.unlock() }
    func finish(_ resume: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { resume() }
    }
}
