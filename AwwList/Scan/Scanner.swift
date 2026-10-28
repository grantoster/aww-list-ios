import Foundation
import Photos
import UIKit
import ImageIO

/// Walks the photo library, analyzes photos it hasn't seen yet, and reports progress.
@MainActor
final class PhotoScanner: ObservableObject {
    @Published private(set) var isScanning = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0

    private var task: Task<Void, Never>?

    func start(library: Library) {
        guard !isScanning else { return }
        isScanning = true
        let known = Set(library.photos.keys)
        let me = self
        task = Task.detached(priority: .utility) {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let assets = PHAsset.fetchAssets(with: opts)
            var todo: [PHAsset] = []
            assets.enumerateObjects { a, _, _ in if !known.contains(a.localIdentifier) { todo.append(a) } }
            let count = todo.count
            await MainActor.run { me.total = count; me.done = 0 }

            let analyzer = Analyzer()
            let manager = PHImageManager.default()
            let req = PHImageRequestOptions()
            req.isSynchronous = true
            req.deliveryMode = .highQualityFormat
            req.resizeMode = .fast
            req.isNetworkAccessAllowed = true   // iCloud photos: downloads a small preview only
            var batch: [PhotoScore] = []

            for asset in todo {
                if Task.isCancelled { break }
                let result: PhotoScore = autoreleasepool {
                    var signals = Signals()
                    signals.isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
                    if !signals.isScreenshot {
                        var image: UIImage?
                        manager.requestImage(for: asset, targetSize: CGSize(width: 768, height: 768),
                                             contentMode: .aspectFit, options: req) { img, _ in image = img }
                        if let img = image, let cg = img.cgImage {
                            signals = analyzer.analyze(cg, orientation: CGImagePropertyOrientation(img.imageOrientation))
                        }
                    }
                    let (raw, excluded) = Scorer.score(signals)
                    let age: AgeGroup? = raw == nil ? nil : (signals.babyConfidence > 0.5 ? .baby : .kid)
                    return PhotoScore(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast,
                                      raw: raw, excluded: excluded, age: age, caption: Scorer.caption(signals))
                }
                batch.append(result)
                if batch.count >= 40 {
                    let out = batch; batch = []
                    await MainActor.run { library.add(out); me.done += out.count }
                }
            }
            let out = batch
            await MainActor.run {
                library.add(out); me.done += out.count
                library.save(); me.isScanning = false
            }
        }
    }

    func stop() { task?.cancel(); isScanning = false }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
