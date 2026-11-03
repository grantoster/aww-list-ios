import Foundation

/// Who's Who's own data — the people you named and everything you told the app about faces — shared by Awwbum and
/// AwwSnap so faces only need teaching once. Each app's Library reads and changes it through the same names as
/// before; Awwbum's library saves it (AwwSnap asks Awwbum to save when it changed something here).
@MainActor
final class WhoStore {
    var people: [Person] = []
    var strictness = 1
    var notThem: [String: Set<UUID>] = [:]
    var ignoredFaces = Set<String>()
    var confirmedFaces: [String: UUID] = [:]
    var skippedFaces = Set<String>()
    /// Changed since Awwbum's library last saved it.
    var dirty = false
}
