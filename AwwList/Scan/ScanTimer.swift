import Foundation

/// Adds up how long each step of checking a photo takes, so Settings → Diagnostics can show what the time goes to.
/// Seconds are summed across the photos being checked at once, so "per photo" is the time one photo's step takes,
/// and "photos a minute" is the real overall speed.
enum ScanTimer {
    private static let lock = NSLock()
    private static var seconds: [String: Double] = [:]
    private static var counts: [String: Int] = [:]
    private static var order: [String] = []
    private static var started: CFAbsoluteTime = 0
    private static var finished = 0
    private static var lastDone: CFAbsoluteTime = 0

    static func reset() {
        lock.lock(); seconds = [:]; counts = [:]; order = []; finished = 0; started = CFAbsoluteTimeGetCurrent(); lastDone = started; lock.unlock()
    }

    @discardableResult
    static func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let t = CFAbsoluteTimeGetCurrent()
        let r = try body()
        add(label, CFAbsoluteTimeGetCurrent() - t)
        return r
    }

    static func add(_ label: String, _ secs: Double) {
        lock.lock()
        if counts[label] == nil { order.append(label) }
        seconds[label, default: 0] += secs; counts[label, default: 0] += 1
        lock.unlock()
    }

    /// Counts a photo for a yes/no question (for example "Photos with a face").
    static func count(_ label: String) {
        lock.lock()
        if counts[label] == nil { order.append(label) }
        counts[label, default: 0] += 1
        lock.unlock()
    }

    static func photoDone() {
        lock.lock(); finished += 1; lastDone = CFAbsoluteTimeGetCurrent(); lock.unlock()
    }

    /// Lines for Diagnostics: overall speed first, then each step.
    static func lines() -> [(label: String, value: String)] {
        lock.lock(); defer { lock.unlock() }
        guard finished > 0, lastDone > started else { return [] }
        let wall = lastDone - started
        var out: [(label: String, value: String)] = [
            ("Photos checked this scan", "\(finished)"),
            ("Overall speed", String(format: "%.0f photos a minute (%.2f s each)", Double(finished) / wall * 60, wall / Double(finished)))
        ]
        for l in order {
            let n = counts[l] ?? 0
            if let s = seconds[l], n > 0 {
                out.append((l, String(format: "%.0f ms each, over %d photos", s / Double(n) * 1000, n)))
            } else {
                out.append((l, "\(n) photos (\(Int((Double(n) / Double(finished) * 100).rounded()))%)"))
            }
        }
        return out
    }
}
