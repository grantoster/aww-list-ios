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

    /// Photos checked so far in this scan, counted one by one from the workers (`done` only moves every 50).
    /// The background task reports this to iOS every second, which treats a task whose progress stalls as stuck.
    nonisolated let live = Counter()

    private let queue = DispatchQueue(label: "aww.scan", qos: .userInitiated)
    private let cancelFlag = CancelFlag()
    private let changes = LibraryChangeFlag()
    private var hasScanned = false
    private var finishHandlers: [() -> Void] = []
    /// True when the last scan was stopped early (for example by iOS in the background), so the next visit resumes it.
    private(set) var stoppedEarly = false

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
        live.reset()
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
                // set-aside photos from before Claude could overrule Apple get one more look
                && !(Scorer.softReasons.contains($0.excluded ?? "") && $0.softChecked != true
                     && ($0.faces ?? 0) > 0)
                // photos on the list (or offered to Claude) get the fingerprint the learned score needs
                && !(($0.raw != nil || $0.soft != nil) && $0.featChecked != true && $0.feat?.count != Learner.featureCount)
                // file-flagged photos used to be skipped unanalyzed, and held-back ones had no score for Put back
                && !((Scorer.provenanceReasons.contains($0.excluded ?? "") || Scorer.heldBack.contains($0.excluded ?? ""))
                     && ($0.flagVersion ?? 0) < 2)
                // photos with faces but no child label get a score so Claude can be offered them
                && !($0.excluded == "No child" && $0.soft == nil && ($0.faces ?? 0) > 0 && ($0.flagVersion ?? 0) < 3)
                && !Scorer.needsShirtlessRecheck($0) && !Scorer.needsLabelRecheck($0)
                // listed photos from before the Shots filter get the face counts it needs
                && !(($0.raw != nil || $0.soft != nil) && ($0.faces ?? 0) >= 2 && ($0.flagVersion ?? 0) < 7)
        }.map(\.id))
        // Photos that already have a record keep it if they can't be re-read this time (a scored photo keeps its
        // score; a bath photo keeps its exclusion and the quarantine around it).
        let ranked = Set(library.photos.keys)
        // Older records being re-read under new rules: if the photo can't be read again, the old record is kept but
        // marked as done (so it isn't retried every scan), except ones needing the shirtless re-check, which become
        // Unavailable (they guard their neighbors and are retried about once a day).
        let restamp = library.photos.filter { _, p in
            ((Scorer.provenanceReasons.contains(p.excluded ?? "") || Scorer.heldBack.contains(p.excluded ?? "")) && (p.flagVersion ?? 0) < 2)
                || (p.excluded == "No child" && p.soft == nil && (p.faces ?? 0) > 0 && (p.flagVersion ?? 0) < 3)
                || Scorer.needsShirtlessRecheck(p) || Scorer.needsLabelRecheck(p)
                || ((p.raw != nil || p.soft != nil) && (p.faces ?? 0) >= 2 && (p.flagVersion ?? 0) < 7)
        }
        let flag = cancelFlag
        let changes = self.changes
        let me = self
        queue.async {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            opts.includeHiddenAssets = false   // the Hidden album is never looked at
            let assets = PHAsset.fetchAssets(with: opts)
            changes.watch(assets)
            var todo: [PHAsset] = []
            var alive = Set<String>()
            assets.enumerateObjects { a, _, _ in
                alive.insert(a.localIdentifier)
                if !known.contains(a.localIdentifier) { todo.append(a) }
            }
            // Includes photos moved to the Hidden album since the last scan: their records are dropped.
            let gone = all.subtracting(alive)
            let count = todo.count
            Task { @MainActor in library.remove(gone); me.total = count; me.done = 0 }

            // Several photos are analyzed at once (one worker per spare core). Photos already on the phone go first;
            // ones stored only in iCloud ("Optimize iPhone Storage") are downloaded afterwards, two at a time.
            let workers = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
            let collector = Collector()
            let live = me.live
            func post(_ r: PhotoScore?) {
                live.add()
                if let ready = collector.add(r) {
                    let (out, n) = ready
                    Task { @MainActor in library.add(out); me.done = max(me.done, n) }
                }
            }
            func runPass(_ list: [PHAsset], network: Bool, lanes: Int) -> [PHAsset] {
                let deferred = Deferred()
                let group = DispatchGroup()
                for lane in 0..<lanes {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { group.leave() }
                        let analyzer = Analyzer()
                        let manager = PHImageManager()
                        for k in stride(from: lane, to: list.count, by: lanes) {
                            if flag.isCancelled { return }
                            switch analyzePhoto(list[k], analyzer: analyzer, manager: manager, network: network, ranked: ranked, restamp: restamp) {
                            case .done(let r): post(r)
                            case .inCloud: deferred.add(list[k])
                            }
                        }
                    }
                }
                group.wait()
                return deferred.items
            }
            let cloudOnly = runPass(todo, network: false, lanes: workers)
            if !flag.isCancelled && !cloudOnly.isEmpty { _ = runPass(cloudOnly, network: true, lanes: 2) }
            let (batch, checked) = collector.drain()

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

    /// True when photos were added or changed since the last scan, or it was stopped before finishing.
    var needsScan: Bool { stoppedEarly || changes.peekChanged() }
}

/// Reads the file details that reveal AI generation or retouching: the original file name, the app that wrote
/// it, camera make, file type, and any AI-provenance tag. Only the first 512 KB of the file is read (where those
/// details live), and only from files already on the phone (no download).
func fileInfo(_ asset: PHAsset, manager: PHImageManager) -> Provenance.FileInfo {
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
        // Added or removed photos (hiding a photo removes it from this fetch, which leaves out the Hidden album).
        if !d.hasIncrementalChanges || !d.insertedObjects.isEmpty || !d.removedObjects.isEmpty { changed = true }
        fetch = d.fetchResultAfterChanges
    }
    /// Returns whether photos were added or deleted since the last call, and resets the flag.
    func takeChanged() -> Bool { lock.lock(); defer { changed = false; lock.unlock() }; return changed }
    func peekChanged() -> Bool { lock.lock(); defer { lock.unlock() }; return changed }
}

/// Holds the result of one image request across threads.
final class LoadedImage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UIImage?
    private var cloud = false
    func set(_ img: UIImage?, inCloud: Bool = false) { lock.lock(); value = img; cloud = inCloud; lock.unlock() }
    var image: UIImage? { lock.lock(); defer { lock.unlock() }; return value }
    var inCloud: Bool { lock.lock(); defer { lock.unlock() }; return cloud }
}

enum PhotoOutcome { case done(PhotoScore?), inCloud }

/// Analyzes one photo. With `network` off, a photo kept only in iCloud comes back as `.inCloud` for a later pass.
func analyzePhoto(_ asset: PHAsset, analyzer: Analyzer, manager: PHImageManager, network: Bool,
                  ranked: Set<String>, restamp: [String: PhotoScore] = [:]) -> PhotoOutcome {
    func keepOld() -> PhotoOutcome? {
        guard var old = restamp[asset.localIdentifier] else { return nil }
        // A photo that needs the shirtless re-check and can't be read: treat it as unreadable (never listed, guards
        // the 10 minutes around it, retried about once a day) rather than as checked.
        if Scorer.needsShirtlessRecheck(old) {
            return .done(PhotoScore(id: old.id, date: old.date, raw: nil, excluded: Scorer.unavailable, age: nil,
                                    caption: "", version: Scorer.version))
        }
        old.flagVersion = 7
        old.mainFaces = old.mainFaces ?? old.faces   // couldn't be re-read: keep what's known, don't retry every scan
        old.adults = old.adults ?? 0
        old.version = Scorer.version   // its held-back or flagged reason stands; just don't keep re-reading it
        return .done(old)
    }
    return autoreleasepool {
        var signals = Signals()
        signals.isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        // Photos that look AI-generated or face-retouched (from the file's details) are flagged, not dropped:
        // they're analyzed like any other photo and listed, and Claude decides.
        let verdict = signals.isScreenshot ? nil : Provenance.verdict(fileInfo(asset, manager: manager))
        var records: [FaceRecord] = []
        if !signals.isScreenshot {
            let req = PHImageRequestOptions()
            req.deliveryMode = .highQualityFormat   // one callback, at the 768 px size asked for
            req.resizeMode = .fast
            req.isNetworkAccessAllowed = network
            // Wait up to 20 s per photo (an iCloud download on a slow connection), then move on.
            let got = LoadedImage()
            let sem = DispatchSemaphore(value: 0)
            let rid = manager.requestImage(for: asset, targetSize: CGSize(width: 768, height: 768),
                                           contentMode: .aspectFit, options: req) { img, info in
                got.set(img, inCloud: (info?[PHImageResultIsInCloudKey] as? Bool) ?? false)
                sem.signal()
            }
            if sem.wait(timeout: .now() + 20) == .timedOut {
                manager.cancelImageRequest(rid)
                return .done(nil)                  // slow, not broken: tried again on the next scan
            }
            if got.image == nil && !network { return .inCloud }   // not on the phone: try again with iCloud
            // No image even from iCloud: remember that, so it isn't retried on every launch
            // (it's retried about once a day, and from Settings).
            guard let img = got.image, let cg = img.cgImage else {
                if let kept = keepOld() { return kept }
                if ranked.contains(asset.localIdentifier) { return .done(nil) }
                return .done(PhotoScore(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast, raw: nil,
                                        excluded: Scorer.unavailable, age: nil, caption: "", version: Scorer.version))
            }
            // Vision couldn't read it: remember that too, same retry rules.
            guard let measured = analyzer.analyze(cg, orientation: CGImagePropertyOrientation(img.imageOrientation)) else {
                if let kept = keepOld() { return kept }
                if ranked.contains(asset.localIdentifier) { return .done(nil) }
                return .done(PhotoScore(id: asset.localIdentifier, date: asset.creationDate ?? .distantPast, raw: nil,
                                        excluded: Scorer.unavailable, age: nil, caption: "", version: Scorer.version))
            }
            signals = measured
            if Scorer.score(measured).raw != nil || Scorer.softScore(measured) != nil || Scorer.poolScore(measured) != nil {
                signals.scenePrint = analyzer.scenePrint(cg, orientation: CGImagePropertyOrientation(img.imageOrientation))
                let ex = analyzer.learningExtras(cg, orientation: CGImagePropertyOrientation(img.imageOrientation), subject: measured.subject)
                signals.aesthetic = ex.aesthetic; signals.isUtility = ex.utility
                signals.faceShape = ex.shape; signals.facePrint = ex.facePrint
            }
            if Scorer.score(measured).raw != nil {
                records = analyzer.facePrints(cg, orientation: CGImagePropertyOrientation(img.imageOrientation),
                                              faces: measured.faces)
            }
        }
        // Undated photos can't be placed in a year or grouped into moments, so they stay off the list.
        // (No fallback to the modification date: that's the edit or import date, which would misfile them.)
        guard let date = asset.creationDate else {
            return .done(PhotoScore(id: asset.localIdentifier, date: .distantPast, raw: nil, excluded: "No date",
                                    age: nil, caption: "", version: Scorer.version))
        }
        var (raw, excluded) = Scorer.score(signals)
        var flaggedScore: Double? = nil
        if let verdict, raw != nil { flaggedScore = raw; raw = nil; excluded = verdict }
        var poolSoft: Double? = nil
        if raw == nil, excluded == "No child", Scorer.softScore(signals) == nil, let ps = Scorer.poolScore(signals) {
            excluded = "No child seen"; poolSoft = ps
        }
        let age: AgeGroup? = raw == nil ? nil : (signals.babyConfidence > 0.5 ? .baby : .kid)
        var p = PhotoScore(id: asset.localIdentifier, date: date,
                           raw: raw, excluded: excluded, age: age, caption: Scorer.caption(signals, date: date),
                           version: Scorer.version, faces: signals.faces.count,
                           faceRecords: (raw != nil || flaggedScore != nil) ? records : nil)
        if raw == nil, let e = excluded, Scorer.softReasons.contains(e) || Scorer.heldBack.contains(e) || Scorer.poolOnly.contains(e) {
            p.soft = flaggedScore ?? poolSoft ?? Scorer.softScore(signals)
            p.age = signals.babyConfidence > 0.5 ? .baby : .kid
        }
        p.softChecked = true
        p.flagVersion = 7
        let main = signals.mainFaceIndices
        p.mainFaces = main.count
        p.adults = main.filter { signals.isAdult($0) == true }.count
        if signals.privacyHint { p.privacyHold = true }
        // Flagged as a possible bath photo by an older check: the hold stays, even if the stricter check clears it.
        if let old = restamp[asset.localIdentifier], Scorer.heldBack.contains(old.excluded ?? "") || old.privacyHold == true {
            p.privacyHold = true
        }
        p.featChecked = true
        if let base = raw ?? p.soft, !signals.scenePrint.isEmpty {
            p.feat = Learner.encode(signals: Learner.signals(signals, apple: base),
                                    scene: People.embed(signals.scenePrint, dims: Learner.sceneDims),
                                    face: signals.facePrint.isEmpty ? Data() : People.embed(signals.facePrint, dims: Learner.faceDims))
        }
        return .done(p)
    }
}

/// Gathers results from the workers and hands them to the library 50 at a time.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var batch: [PhotoScore] = []
    private var checked = 0
    /// Adds one result; returns a batch to post every 50 photos.
    func add(_ r: PhotoScore?) -> ([PhotoScore], Int)? {
        lock.lock(); defer { lock.unlock() }
        checked += 1
        if let r { batch.append(r) }
        guard checked % 50 == 0 else { return nil }
        let out = batch; batch = []
        return (out, checked)
    }
    func drain() -> ([PhotoScore], Int) { lock.lock(); defer { lock.unlock() }; let out = batch; batch = []; return (out, checked) }
}

/// Photos set aside for the iCloud pass.
final class Deferred: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [PHAsset] = []
    func add(_ a: PHAsset) { lock.lock(); list.append(a); lock.unlock() }
    var items: [PHAsset] { lock.lock(); defer { lock.unlock() }; return list }
}

/// A thread-safe count (photos checked so far).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    func reset() { lock.lock(); n = 0; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
