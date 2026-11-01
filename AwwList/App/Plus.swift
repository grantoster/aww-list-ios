import Foundation
import StoreKit

/// Awwbum Plus: a subscription that includes Claude scoring through Awwbum's own server, so no Anthropic API key is
/// needed. The server checks the subscription (the signed App Store transaction) on every photo and allows up to a
/// monthly number of photos.
@MainActor
final class PlusStore: ObservableObject {
    static let productIDs = ["com.grantoster.awwlist.plus.monthly", "com.grantoster.awwlist.plus.yearly"]
    /// Awwbum's scoring server (set in project.yml as AWW_SCORE_SERVER); empty until it's deployed, and then Plus
    /// isn't offered.
    static let serverURL: URL? = {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "AwwScoreServer") as? String,
              !s.trimmingCharacters(in: .whitespaces).isEmpty, let u = URL(string: s), u.scheme == "https" else { return nil }
        return u
    }()
    static var available: Bool { serverURL != nil }

    @Published private(set) var products: [Product] = []
    /// The current subscription's signed transaction (sent to the server with each photo); nil when not subscribed.
    @Published private(set) var signedTransaction: String?
    @Published private(set) var expires: Date?
    @Published private(set) var busy = false
    @Published var message: String?
    /// The App Store didn't return the subscription options (no connection, or not set up yet).
    @Published private(set) var loadFailed = false
    /// This month's photos scored through Plus, and the limit (from the server).
    @Published private(set) var quota: (used: Int, limit: Int)?

    var isActive: Bool { signedTransaction != nil }
    private var updates: Task<Void, Never>?

    init() {
        guard Self.available else { return }
        // Purchases made elsewhere (another device, Ask to Buy, renewals) arrive here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await load() }
    }

    func load() async {
        guard Self.available else { return }
        if products.isEmpty {
            loadFailed = false
            products = ((try? await Product.products(for: Self.productIDs)) ?? []).sorted { $0.price < $1.price }
            loadFailed = products.isEmpty
        }
        await refresh()
    }

    /// Finds the current, unrevoked Plus subscription.
    func refresh() async {
        var jws: String?, exp: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, Self.productIDs.contains(t.productID), t.revocationDate == nil,
                  (t.expirationDate ?? .distantFuture) > Date() else { continue }
            if exp == nil || (t.expirationDate ?? .distantFuture) > exp! { jws = result.jwsRepresentation; exp = t.expirationDate }
        }
        signedTransaction = jws; expires = exp
        if jws != nil { await refreshQuota() } else { quota = nil }
    }

    func buy(_ product: Product) async {
        busy = true; defer { busy = false }
        message = nil
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let t) = result { await t.finish() }
                await refresh()
                if !isActive { message = "The purchase couldn't be confirmed. Tap Restore Purchases, or try again later." }
            case .pending: message = "Waiting for approval (for example, Ask to Buy)."
            case .userCancelled: break
            @unknown default: break
            }
        } catch {
            message = "Couldn't reach the App Store. Try again in a moment."
        }
    }

    /// Restore Purchases: asks the App Store for this Apple ID's purchases again.
    func restore() async {
        busy = true; defer { busy = false }
        message = nil
        try? await AppStore.sync()
        await refresh()
        message = isActive ? "Awwbum Plus is active." : "No Awwbum Plus subscription was found for this Apple ID."
    }

    func refreshQuota() async {
        guard let base = Self.serverURL, let jws = signedTransaction else { return }
        var r = URLRequest(url: base.appendingPathComponent("v1/quota"))
        r.setValue(jws, forHTTPHeaderField: "X-Awwbum-Transaction")
        r.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let used = obj["used"] as? Int, let limit = obj["limit"] as? Int else { return }
        quota = (used, limit)
    }

    /// A request to score one photo through Awwbum's server (nil without Plus).
    func scoreRequest(jpeg: Data, model: String) -> URLRequest? {
        guard let base = Self.serverURL, let jws = signedTransaction,
              let body = try? JSONSerialization.data(withJSONObject: ["image": jpeg.base64EncodedString(), "model": model],
                                                     options: [.withoutEscapingSlashes]) else { return nil }
        var r = URLRequest(url: base.appendingPathComponent("v1/score"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(jws, forHTTPHeaderField: "X-Awwbum-Transaction")
        r.httpBody = body
        r.timeoutInterval = 120
        return r
    }
}
