import Foundation
import Photos
import UIKit
import ImageIO

/// Walks the photo library on a background queue, analyzes photos it hasn't seen yet, and reports progress.
@MainActor
final class PhotoScanner: ObservableObject {
    @Published private(set) var isScanning = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0

    private let queue = DispatchQueue(label: "aww.scan", qos: .utility)
    private let cancelFlag = CancelFlag()

    func start(library: Library) {
        guard !isScanning else { return }
        isScanning = true
        cancelFlag.reset()
        let all = Set(library.photos.keys)
        // Photos scored by an older version of the scorer are analyzed again.
        let known = Set(library.photos.values.filter { $0.version == Scorer.version }.map(\.id))
        let flag = cancelFlag
        let me = self
        queue.async {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let assets = PHAsset.fetchAssets(with: opts)
            var todo: [PHAsset] = []
            var alive = Set<String>()
            assets.enumerateObjects { a, _, _ in
                alive.insert(a.localIdentifier)
                if !known.contains(a.localIdentifier) { todo.append(a) }
            }
            let gone = all.subtracting(alive)
            let count = todo.count
            Task { @MainActor in library.remove(gone); me.total = count; me.done = 0 }

            let analyzer = Analyzer()
            let manager = PHImageManager.default()
            let req = PHImageRequestOptions()
            req.isSynchronous = true            // fine here: this is a dedicated serial queue, not the Swift concurrency pool
            req.deliveryMode = .highQualityFormat // one callback, at the 768 px size asked for
            req.resizeMode = .fast
            req.isNetworkAccessAllowed = false   // iCloud-only photos without a local preview are retried on a later scan
            var batch: [PhotoScore] = []
            var checked = 0

            for asset in todo {
                if flag.isCancelled { break }
                let result: PhotoScore? = autoreleasepool {
                    var signals = Signals()
                    signals.isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
                    if !signals.isScreenshot {
                        var image: UIImage?
                        manager.requestImage(for: asset, targetSize: CGSize(width: 768, height: 768),
                                             contentMode: .aspectFit, options: req) { img, _ in image = img }
                        // No image (offline iCloud photo): store nothing, so it's tried again next time.
                        guard let img = image, let cg = img.cgImage else { return nil }
                        // Vision failed: store nothing, so it's tried again next time.
                        guard let measured = analyzer.analyze(cg, orientation: CGImagePropertyOrientation(img.imageOrientation)) else { return nil }
                        signals = measured
                    }
                    // Undated photos can't be placed in a year or grouped into moments, so they stay off the list.
                    guard let date = asset.creationDate ?? asset.modificationDate else {
                        return PhotoScore(id: asset.localIdentifier, date: .distantPast, raw: nil, excluded: "No date",
                                          age: nil, caption: "", version: Scorer.version)
                    }
                    let (raw, excluded) = Scorer.score(signals)
                    let age: AgeGroup? = raw == nil ? nil : (signals.babyConfidence > 0.5 ? .baby : .kid)
                    return PhotoScore(id: asset.localIdentifier, date: date,
                                      raw: raw, excluded: excluded, age: age, caption: Scorer.caption(signals),
                                      version: Scorer.version)
                }
                checked += 1
                if let result { batch.append(result) }
                if checked % 50 == 0 {
                    let out = batch, n = checked
                    batch = []
                    Task { @MainActor in library.add(out); me.done = n }
                }
            }
            let out = batch, n = checked
            Task { @MainActor in
                library.add(out); library.finishScan()
                me.done = n; me.isScanning = false
            }
        }
    }

    func stop() { cancelFlag.cancel() }
}

/// Thread-safe stop switch shared with the scan queue.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
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
