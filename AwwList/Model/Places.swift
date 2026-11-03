import CoreLocation
import Foundation

/// Where photos were taken: places you save (a home, by address) and the towns your photos are in (named from the
/// photo's own location by Apple's location service). Used by the Place filter on Home and by search.
@MainActor
final class PlaceBook: ObservableObject {
    struct Saved: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var address: String
        var lat: Double
        var lon: Double
        /// How close a photo has to be to count as taken here, in meters.
        var radius: Double = 200
    }

    @Published private(set) var saved: [Saved] = []
    /// Town names by map square ("Gulf Shores, AL"); "" where none was found.
    @Published private(set) var towns: [String: String] = [:]
    /// Name towns with Apple's location service (it gets the photos' rough locations, never the photos).
    @Published var lookUpTowns: Bool {
        didSet { UserDefaults.standard.set(lookUpTowns, forKey: Self.lookUpKey); if lookUpTowns { nameTowns(Shared.library(.current)) } }
    }
    @Published private(set) var naming = false

    private static let savedKey = "places.saved", townsKey = "places.towns", lookUpKey = "places.lookUpTowns"

    init() {
        let d = UserDefaults.standard
        lookUpTowns = d.object(forKey: Self.lookUpKey) as? Bool ?? false   // off until you turn it on
        if let data = d.data(forKey: Self.savedKey), let s = try? JSONDecoder().decode([Saved].self, from: data) { saved = s }
        towns = d.dictionary(forKey: Self.townsKey) as? [String: String] ?? [:]
    }

    // MARK: Matching

    /// The map square a location falls in (about 5 km across), for naming towns.
    nonisolated static func cell(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.2f,%.2f", (lat * 20).rounded() / 20, (lon * 20).rounded() / 20)
    }
    nonisolated static func center(of cell: String) -> CLLocation? {
        let parts = cell.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CLLocation(latitude: parts[0], longitude: parts[1]) : nil
    }

    func town(_ p: PhotoScore) -> String? {
        guard let lat = p.lat, let lon = p.lon, let t = towns[Self.cell(lat, lon)], !t.isEmpty else { return nil }
        return t
    }
    /// The saved place a photo was taken at (the nearest one it's inside), if any.
    func savedPlace(_ p: PhotoScore) -> Saved? {
        guard let lat = p.lat, let lon = p.lon else { return nil }
        let here = CLLocation(latitude: lat, longitude: lon)
        return saved.map { ($0, here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon))) }
            .filter { $0.1 <= $0.0.radius }.min { $0.1 < $1.1 }?.0
    }
    /// Words for search: the saved place's name and the town.
    func searchText(_ p: PhotoScore) -> String {
        [savedPlace(p)?.name, town(p)].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Saved places

    /// Adds a place from its address (looked up with Apple's location service). Returns a problem to show, or nil.
    func add(name: String, address: String) async -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !a.isEmpty else { return "Add a name and an address." }
        do {
            guard let loc = try await CLGeocoder().geocodeAddressString(a).first?.location else {
                return "That address couldn't be found. Try adding the city and state."
            }
            saved.append(Saved(name: n, address: a, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude))
            store()
            Shared.placesChanged()
            return nil
        } catch {
            return "That address couldn't be found (or there's no connection). Try again, adding the city and state."
        }
    }
    func remove(_ id: UUID) { saved.removeAll { $0.id == id }; store(); Shared.placesChanged() }
    func setRadius(_ id: UUID, _ r: Double) {
        guard let i = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[i].radius = r; store(); Shared.placesChanged()
    }
    private func store() {
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
    }

    // MARK: Towns

    private var townTask: Task<Void, Never>?
    /// Names the towns of photos on the list (or that can be put back) that don't have one yet, most photos first,
    /// one look-up every couple of seconds (Apple limits how fast apps can ask). Each area is looked up at one of
    /// its photos' locations, rounded to about 1 km (not the area's middle, which can be out at sea). Stops on a
    /// connection problem and tries again next time.
    func nameTowns(_ library: Library) {
        guard lookUpTowns, townTask == nil else { return }
        var counts: [String: Int] = [:], spot: [String: CLLocation] = [:]
        for p in library.photos.values where p.raw != nil || p.soft != nil {
            guard let lat = p.lat, let lon = p.lon else { continue }
            let c = Self.cell(lat, lon)
            guard towns[c] == nil else { continue }
            counts[c, default: 0] += 1
            if spot[c] == nil { spot[c] = CLLocation(latitude: (lat * 100).rounded() / 100, longitude: (lon * 100).rounded() / 100) }
        }
        let todo = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        guard !todo.isEmpty else { return }
        naming = true
        townTask = Task { [weak self] in
            let geocoder = CLGeocoder()
            var done = 0
            for c in todo {
                guard let self, self.lookUpTowns, !Task.isCancelled, let loc = spot[c] ?? Self.center(of: c) else { break }
                do {
                    let mark = try await geocoder.reverseGeocodeLocation(loc).first
                    self.towns[c] = mark.map(Self.name) ?? ""
                } catch let e as CLError where e.code == .geocodeFoundNoResult {
                    self.towns[c] = ""   // open sea, say: don't ask again
                } catch {
                    break                // no connection, or asked too often: try again next time
                }
                UserDefaults.standard.set(self.towns, forKey: Self.townsKey)
                done += 1
                if done % 20 == 0 { Shared.placesChanged() }   // towns show up in the Place menu as they're named
                try? await Task.sleep(for: .seconds(2))
            }
            self?.townTask = nil
            self?.naming = false
            Shared.placesChanged()
        }
    }

    /// "Gulf Shores, AL" in the US; "Paris, France" elsewhere.
    nonisolated static func name(_ m: CLPlacemark) -> String {
        let town = m.locality ?? m.subAdministrativeArea ?? m.name ?? ""
        if m.isoCountryCode == "US" {
            return [town, m.administrativeArea].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return [town, m.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
