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
            let generation = Self.cacheGeneration()
            // A cached copy shows right away; it's checked (off the main thread) that the photo is still visible
            // (not hidden or deleted since), and taken down if not.
            if let hit = Self.thumbs.object(forKey: key) {
                image = hit
                let photo = id
                let stillThere = await Task.detached(priority: .userInitiated) { Self.visible([photo]).count == 1 }.value
                if !stillThere && !Task.isCancelled { image = nil; Self.thumbs.removeObject(forKey: key) }
                return
            }
            image = nil   // never leave the previous photo showing while a different one loads
            // Show the quick low-resolution version as soon as Photos has it, then the sharp one.
            let run = RunFlag()
            defer { run.end() }   // a preview arriving after this run ends (or moved on) is ignored
            let mode: PHImageContentMode = contentMode == .fit ? .aspectFit : .aspectFill
            let r = await withTaskCancellationHandler {
                await Self.load(id: id, size: CGSize(width: px, height: px), mode: mode,
                                preview: { img in Task { @MainActor in if run.live, image == nil { image = img } } })
            } onCancel: { run.end() }
            guard !Task.isCancelled else { return }   // this view has moved on to another photo
            if let img = r.image {
                image = img
                // Only sharp, finished images are kept, and only if the library didn't change meanwhile.
                if !r.degraded, Self.cacheGeneration() == generation { Self.thumbs.setObject(img, forKey: key) }
            }
        }
    }

    nonisolated(unsafe) static let manager = PHCachingImageManager()   // thread-safe; used from any thread
    /// Recently drawn photos, so scrolling back or reopening a list is instant. Emptied whenever the photo library
    /// changes (so a photo hidden or deleted meanwhile is never shown from here), and by iOS under memory pressure.
    nonisolated static let thumbs: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.countLimit = 400; return c }()
    private nonisolated static let genLock = NSLock()
    private nonisolated(unsafe) static var generation = 0
    nonisolated static func cacheGeneration() -> Int { genLock.lock(); defer { genLock.unlock() }; return generation }
    /// Called whenever the photo library changes.
    nonisolated static func clearCache() {
        genLock.lock(); generation += 1; genLock.unlock()
        thumbs.removeAllObjects()
    }

    /// Looks photos up by id the same way the scan does, so the Hidden album is never looked at: a photo that's
    /// hidden simply isn't found.
    /// Asks Photos to get the photos about to be shown ready ahead of time (the same sizes the list draws), so
    /// scrolling doesn't wait on each one. Off the main thread; replaces the previous set.
    nonisolated static func prefetch(_ ids: [String], side: CGFloat, mode: PHImageContentMode = .aspectFill) {
        guard !ids.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let found = visible(ids)
            var assets: [PHAsset] = []
            found.enumerateObjects { a, _, _ in assets.append(a) }
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.isNetworkAccessAllowed = true
            manager.stopCachingImagesForAllAssets()   // only the current set is kept ready
            manager.startCachingImages(for: assets, targetSize: CGSize(width: side, height: side), contentMode: mode, options: opts)
        }
    }

    nonisolated static func visible(_ ids: [String]) -> PHFetchResult<PHAsset> {
        let o = PHFetchOptions()
        o.includeHiddenAssets = false
        o.predicate = NSPredicate(format: "localIdentifier IN %@", ids)
        return PHAsset.fetchAssets(with: o)
    }

    /// Loads one image. Cancelled automatically when the view scrolls away; returns the best image delivered.
    nonisolated static func load(id: String, size: CGSize, mode: PHImageContentMode,
                     preview: (@Sendable (UIImage) -> Void)? = nil) async -> (image: UIImage?, degraded: Bool) {
        guard let asset = visible([id]).firstObject else { return (nil, false) }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = true
        let box = RequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<(image: UIImage?, degraded: Bool), Never>) in
                let rid = manager.requestImage(for: asset, targetSize: size, contentMode: mode, options: opts) { img, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded { box.keep(img); if let img { preview?(img) }; return }
                    box.finish { cont.resume(returning: img != nil ? (img, false) : (box.lastImage, true)) }
                }
                box.setID(rid)
            }
        } onCancel: {
            if let rid = box.id { manager.cancelImageRequest(rid) }
        }
    }
}

/// Marks whether one load is still the current one for its view.
private final class RunFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    var live: Bool { lock.lock(); defer { lock.unlock() }; return !ended }
    func end() { lock.lock(); ended = true; lock.unlock() }
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
