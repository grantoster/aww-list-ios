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
    private let changes = LibraryChangeFlag()
    private var hasScanned = false

    private static let retryKey = "lastUnavailableRetry"

    /// Scans on first launch and afterwards only when photos were added or deleted, so opening and closing
    /// photos, or switching back to the app, doesn't start the scan over. Photos that couldn't be loaded
    /// (offline iCloud) are retried automatically about once a day.
    func startIfNeeded(library: Library) {
        if isScanning { return }                       // don't consume a change while a scan is running
        let last = UserDefaults.standard.object(forKey: Self.retryKey) as? Date ?? .distantPast
        let retry = Date().timeIntervalSince(last) > 86_400
        if hasScanned && !retry && !changes.takeChanged() { return }
        start(library: library, retryUnavailable: retry)
    }

    /// `retryUnavailable` also retries photos whose image couldn't be loaded before.
    func start(library: Library, retryUnavailable: Bool = false) {
        guard !isScanning else { return }
        isScanning = true
        total = 0; done = 0                            // so no stale "x of y" shows before counting finishes
        hasScanned = true
        changes.register()
        _ = changes.takeChanged()
        if retryUnavailable { UserDefaults.standard.set(Date(), forKey: Self.retryKey) }
        cancelFlag.reset()
        let all = Set(library.photos.keys)
        // Photos scored by an older version of the scorer are analyzed again.
        let known = Set(library.photos.values.filter {
            $0.version == Scorer.version && !(retryUnavailable && $0.excluded == Scorer.unavailable)
        }.map(\.id))
        let flag = cancelFlag
        let changes = self.changes
        let me = self
        queue.async {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let assets = PHAsset.fetchAssets(with: opts)
            changes.watch(assets)
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
            req.deliveryMode = .highQualityFormat // one callback, at the 768 px size asked for
            req.resizeMode = .fast
            req.isNetworkAccessAllowed = true    // "Optimize iPhone Storage" keeps originals in iCloud; fetch a small copy
            var batch: [PhotoScore] = []
            var checked = 0

            for asset in todo {
                if flag.isCancelled { break }
                let result: PhotoScore? = autoreleasepool {
                    var signals = Signals()
                    signals.isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
                    if !signals.isScreenshot {
                        // Wait up to 20 s per photo (an iCloud download on a slow connection), then move on.
                        let got = LoadedImage()
                        let sem = DispatchSemaphore(value: 0)
                        let rid = manager.requestImage(for: asset, targetSize: CGSize(width: 768, height: 768),
                                                       contentMode: .aspectFit, options: req) { img, _ in
                            got.set(img)
                            sem.signal()
                        }
                        if sem.wait(timeout: .now() + 20) == .timedOut {
                            manager.cancelImageRequest(rid)
                            return nil                 // slow, not broken: tried again on the next scan
                        }
                        // No image even from iCloud: remember that, so it isn't retried on every launch
                        // (it's retried about once a day, and from Settings).
                        guard let img = got.image, let cg = img.cgImage else {
                            return PhotoScore(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast, raw: nil,
                                              excluded: Scorer.unavailable, age: nil, caption: "", version: Scorer.version)
                        }
                        // Vision couldn't read it: remember that too, same retry rules.
                        guard let measured = analyzer.analyze(cg, orientation: CGImagePropertyOrientation(img.imageOrientation)) else {
                            return PhotoScore(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast, raw: nil,
                                              excluded: Scorer.unavailable, age: nil, caption: "", version: Scorer.version)
                        }
                        signals = measured
                    }
                    // Undated photos can't be placed in a year or grouped into moments, so they stay off the list.
                    // (No fallback to the modification date: that's the edit or import date, which would misfile them.)
                    guard let date = asset.creationDate else {
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
                // Photos added while scanning are picked up right away.
                if me.changes.peekChanged() { me.start(library: library) }
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

/// Notes when photos are added to or deleted from the library, so the next foreground visit rescans.
/// Edits, favorites, iCloud sync and Photos' own background analysis don't count.
final class LibraryChangeFlag: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    private var registered = false
    private var fetch: PHFetchResult<PHAsset>?
    func register() {
        lock.lock(); defer { lock.unlock() }
        guard !registered else { return }
        registered = true
        PHPhotoLibrary.shared().register(self)
    }
    /// The set of photos the last scan saw; changes are measured against it.
    func watch(_ result: PHFetchResult<PHAsset>) { lock.lock(); fetch = result; lock.unlock() }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock(); defer { lock.unlock() }
        guard let f = fetch, let d = changeInstance.changeDetails(for: f) else { return }
        if !d.hasIncrementalChanges || !d.insertedObjects.isEmpty || !d.removedObjects.isEmpty { changed = true }
        fetch = d.fetchResultAfterChanges
    }
    /// Returns whether photos were added or deleted since the last call, and resets the flag.
    func takeChanged() -> Bool { lock.lock(); defer { changed = false; lock.unlock() }; return changed }
    func peekChanged() -> Bool { lock.lock(); defer { lock.unlock() }; return changed }
}

/// Holds the result of one image request across threads.
private final class LoadedImage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UIImage?
    func set(_ img: UIImage?) { lock.lock(); value = img; lock.unlock() }
    var image: UIImage? { lock.lock(); defer { lock.unlock() }; return value }
}
