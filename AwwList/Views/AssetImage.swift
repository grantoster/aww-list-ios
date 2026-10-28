import SwiftUI
import Photos

/// Shows one photo from the library, loaded at the size it's drawn.
struct AssetImage: View {
    let id: String
    var contentMode: ContentMode = .fill
    var targetSide: CGFloat = 400

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            }
        }
        .clipped()
        .task(id: id) { image = await Self.load(id: id, side: targetSide) }
    }

    static let manager = PHCachingImageManager()

    static func load(id: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let scale = await MainActor.run { UIScreen.main.scale }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            var resumed = false
            manager.requestImage(for: asset, targetSize: CGSize(width: side * scale, height: side * scale),
                                 contentMode: .aspectFill, options: opts) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded && !resumed { resumed = true; cont.resume(returning: img) }
                else if img == nil && !resumed { resumed = true; cont.resume(returning: nil) }
            }
        }
    }
}
