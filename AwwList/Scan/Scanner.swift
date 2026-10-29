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
    private var finishHandlers: [() -> Void] = []
    /// True when the last scan was stopped early (for example by iOS in the background), so the next visit resumes it.
    private var stoppedEarly = false

    /// Runs `handler` when the current scan (and any follow-up for photos added meanwhile) is done,
    /// or right away when nothing is scanning.
    func whenFinished(_ handler: @escaping () -> Void) {
        if isScanning { finishHandlers.append(handler) } else { handler() }
    }

    private static let retryKey = "lastUnavailableRetry"

    /// Scans on first launch and afterwards only when photos were added or deleted, so opening and closing
    /// photos, or switching back to the app, doesn't start the scan over. Photos that couldn't be loaded
    /// (offline iCloud) are retried automatically about once a day.
    func startIfNeeded(library: Library) {
        if isScanning { return }                       // don't consume a change while a scan is running
        let last = UserDefaults.standard.object(forKey: Self.retryKey) as? Date ?? .distantPast
        let retry = Date().timeIntervalSince(last) > 86_400
        if hasScanned && !retry && !stoppedEarly && !changes.takeChanged() { return }
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
        // Counted photos from before Who's Who are measured again to get their face fingerprints.
        let known = Set(library.photos.values.filter {
            $0.version == Scorer.version && !(retryUnavailable && $0.excluded == Scorer.unavailable)
                && ($0.raw == nil || ($0.faceRecords.map { $0.allSatisfy { $0.vec.count == People.dim } } ?? false))
        }.map(\.id))
        // Photos already on the list keep their score if they can't be re-read this time.
        let ranked = Set(library.photos.values.filter { $0.raw != nil }.map(\.id))
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
                    // Clearly AI-generated or face-retouched photos stay off the list (checked from the file's details).
                    if !signals.isScreenshot, let verdict = Provenance.verdict(fileInfo(asset, manager: manager)) {
                        return PhotoScore(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast, raw: nil,
                                          excluded: verdict, age: nil, caption: "", version: Scorer.version)
                    }
                    var records: [FaceRecord] = []
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
                            if ranked.contains(asset.localIdentifier) { return nil }
                            return PhotoScore(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast, raw: nil,
                                              excluded: Scorer.unavailable, age: nil, caption: "", version: Scorer.version)
                        }
                        // Vision couldn't read it: remember that too, same retry rules.
                        guard let measured = analyzer.analyze(cg, orientation: CGImagePropertyOrientation(img.imageOrientation)) else {
                            if ranked.contains(asset.localIdentifier) { return nil }
                            return PhotoScore(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast, raw: nil,
                                              excluded: Scorer.unavailable, age: nil, caption: "", version: Scorer.version)
                        }
                        signals = measured
                        if Scorer.score(measured).raw != nil {
                            records = analyzer.facePrints(cg, orientation: CGImagePropertyOrientation(img.imageOrientation),
                                                          faces: measured.faces)
                        }
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
                                      raw: raw, excluded: excluded, age: age, caption: Scorer.caption(signals, date: date),
                                      version: Scorer.version, faces: signals.faces.count,
                                      faceRecords: raw == nil ? nil : records)
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
                me.stoppedEarly = flag.isCancelled
                // Photos added while scanning are picked up right away (unless the scan was stopped).
                if !flag.isCancelled && me.changes.peekChanged() {
                    me.start(library: library)
                } else {
                    let handlers = me.finishHandlers
                    me.finishHandlers = []
                    handlers.forEach { $0() }
                }
            }
        }
    }

    func stop() { cancelFlag.cancel() }
}

/// Reads the file details that reveal AI generation or retouching: the original file name, the app that wrote
/// it, camera make, file type, and any AI-provenance tag. Only the first 512 KB of the file is read (where those
/// details live), and only from files already on the phone (no download).
private func fileInfo(_ asset: PHAsset, manager: PHImageManager) -> Provenance.FileInfo {
    var info = Provenance.FileInfo()
    let resources = PHAssetResource.assetResources(for: asset)
    let original = resources.first { $0.type == .photo } ?? resources.first
    info.filename = original?.originalFilename ?? ""
    info.isPNG = (original?.uniformTypeIdentifier ?? "").lowercased().contains("png")
    // The original, plus the edited version when the photo was edited (where AI tools leave their tag).
    let edited = resources.first { $0.type == .fullSizePhoto }
    info.headerRead = false
    for (resource, isOriginal) in [(original, true), (edited, false)] {
        guard let resource, let header = headerBytes(resource) else { continue }
        let (data, complete) = header
        if isOriginal { info.headerRead = true }
        if Provenance.hasAIMarker(data) { info.aiMarker = true }
        var src = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(src, data as CFData, complete)
        if CGImageSourceCopyPropertiesAtIndex(src, 0, nil) == nil, let whole = CGImageSourceCreateWithData(data as CFData, nil) {
            src = whole
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            if let sw = tiff[kCGImagePropertyTIFFSoftware] as? String { info.software += " " + sw }
            if isOriginal, let make = tiff[kCGImagePropertyTIFFMake] as? String { info.cameraMake = make }
        }
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
           let tool = CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:CreatorTool" as CFString) as String? {
            info.software += " " + tool
        }
    }
    return info
}

/// The first `limit` bytes of a resource that is stored on the phone (and whether that was the whole file),
/// or nil (iCloud-only, or nothing arrived within 10 s).
private func headerBytes(_ resource: PHAssetResource, limit: Int = 512 * 1024) -> (Data, Bool)? {
    let manager = PHAssetResourceManager.default()
    let opts = PHAssetResourceRequestOptions()
    opts.isNetworkAccessAllowed = false
    let box = HeaderBox(limit: limit)
    let sem = DispatchSemaphore(value: 0)
    let rid = manager.requestData(for: resource, options: opts, dataReceivedHandler: { chunk in
        if box.append(chunk), let id = box.requestID { manager.cancelDataRequest(id) }
    }, completionHandler: { error in box.finished(error == nil); sem.signal() })
    box.requestID = rid
    if box.isFull { manager.cancelDataRequest(rid) }
    if sem.wait(timeout: .now() + 10) == .timedOut { manager.cancelDataRequest(rid) }
    let data = box.data
    return data.isEmpty ? nil : (data, box.wholeFile && data.count < limit)
}

private final class HeaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var bytes = Data()
    private var id: PHAssetResourceDataRequestID?
    init(limit: Int) { self.limit = limit }
    var requestID: PHAssetResourceDataRequestID? {
        get { lock.lock(); defer { lock.unlock() }; return id }
        set { lock.lock(); id = newValue; lock.unlock() }
    }
    /// Adds a chunk; returns true once enough has arrived.
    func append(_ chunk: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if bytes.count < limit { bytes.append(chunk.prefix(limit - bytes.count)) }
        return bytes.count >= limit
    }
    var isFull: Bool { lock.lock(); defer { lock.unlock() }; return bytes.count >= limit }
    private var done = false
    /// True when the request finished on its own (not cancelled or timed out), so `data` is the whole file.
    var wholeFile: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func finished(_ ok: Bool) { lock.lock(); done = ok; lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
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
