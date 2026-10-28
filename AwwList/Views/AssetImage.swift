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
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            }
        }
        .clipped()
        .task(id: id) {
            let px = targetSide * scale
            image = await Self.load(id: id, size: CGSize(width: px, height: px),
                                    mode: contentMode == .fit ? .aspectFit : .aspectFill)
        }
    }

    static let manager = PHCachingImageManager()

    /// Loads one image. Cancelled automatically when the view scrolls away; returns the best image delivered.
    static func load(id: String, size: CGSize, mode: PHImageContentMode) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = true
        let box = RequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
                let rid = manager.requestImage(for: asset, targetSize: size, contentMode: mode, options: opts) { img, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded { box.keep(img); return }
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
