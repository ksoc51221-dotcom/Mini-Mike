import Foundation
import Security

// Part S (2026-11-27): a song that is not in My songs is found with the Spotify Web API (Merlin's own developer app,
// client credentials: no account login), then played with `play track` through the focus guard. The Spotify app never
// comes to the front. Endpoints checked against Spotify's docs on 2026-11-27: token POST
// https://accounts.spotify.com/api/token (Basic client_id:client_secret, grant_type=client_credentials, 1 hour);
// search GET https://api.spotify.com/v1/search (q, type=track, limit at most 10, market).

/// One track from the search.
struct SpotifyHit: Equatable, Identifiable {
    let uri: String
    let name: String
    let artist: String
    var id: String { uri }
}

// MARK: - The key (client ID and secret)

/// A secret in the macOS Keychain as a generic password, under its own service and account. Never logged or printed.
final class KeychainSecretStore: GroqKeyStore {
    let service: String
    let account: String
    init(service: String, account: String) { self.service = service; self.account = account }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    @discardableResult
    func save(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let data = clean.data(using: .utf8) else { return false }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func remove() { SecItemDelete(query as CFDictionary) }
}

/// The Spotify developer app's client ID and secret: one Keychain item, "id" and "secret" on two lines. Tests and pictures
/// use a store in memory, never the Keychain.
enum SpotifyKeys {
    nonisolated(unsafe) static var shared: GroqKeyStore = {
        let args = CommandLine.arguments
        let throwaway = ["--unittest", "--uishots", "--settingsshots", "--edgeglasscheck"].contains { args.contains($0) }
        return throwaway ? MemoryGroqKeyStore() : KeychainSecretStore(service: "com.kien.merlin.spotify", account: "spotify-client")
    }()

    /// The pair from a store, or nil when either half is missing.
    static func pair(_ store: GroqKeyStore) -> (id: String, secret: String)? {
        guard let raw = store.read() else { return nil }
        let parts = raw.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// Saves both halves (trimmed). False: either is empty or the Keychain refused.
    @discardableResult static func save(id: String, secret: String, in store: GroqKeyStore) -> Bool {
        let i = id.trimmingCharacters(in: .whitespacesAndNewlines), s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !i.isEmpty, !s.isEmpty, !i.contains("\n"), !s.contains("\n") else { return false }
        defer { changed() }
        return store.save(i + "\n" + s)
    }

    /// Removes the key (Settings' Remove button).
    static func remove(in store: GroqKeyStore) {
        store.remove()
        changed()
    }

    /// The shared search reads the key again (and forgets its token) after a save or a remove.
    static func changed() { (SpotifyWebSearch.shared as? SpotifyWebSearch)?.forgetKey() }
}

// MARK: - The search

/// What the card needs (a fake in the tests: they never touch the network).
protocol SpotifyWebSearching: AnyObject {
    var hasKey: Bool { get }
    func search(_ query: String) async -> Result<[SpotifyHit], SpotifyWebSearch.Failure>
}

final class SpotifyWebSearch: SpotifyWebSearching {
    enum Failure: Error, Equatable {
        case noKey, badKey, offline, refused(Int)
        /// One short line for the card.
        var message: String {
            switch self {
            case .noKey: return "Add a Spotify key in Settings."
            case .badKey: return "Spotify did not accept the key. Check it in Settings."
            case .offline: return "No connection to Spotify."
            case .refused(let code): return "Spotify search failed (\(code))."
            }
        }
    }

    /// Sends one request: the response body and the HTTP status.
    typealias Transport = (URLRequest) async throws -> (Data, Int)

    static let liveTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    nonisolated(unsafe) static var shared: SpotifyWebSearching = SpotifyWebSearch(keys: SpotifyKeys.shared, transport: liveTransport)

    /// Results shown in the card.
    static let limit = 5
    static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    static let searchURL = URL(string: "https://api.spotify.com/v1/search")!

    private let keys: GroqKeyStore
    private let transport: Transport
    private let now: () -> Date
    private var token: (value: String, expires: Date)?
    /// The key as last read (nil: not read yet). The card asks `hasKey` on each redraw: one Keychain read, not one per redraw.
    private var cachedPair: (id: String, secret: String)??

    init(keys: GroqKeyStore, transport: @escaping Transport, now: @escaping () -> Date = Date.init) {
        self.keys = keys
        self.transport = transport
        self.now = now
    }

    var hasKey: Bool { pair() != nil }

    private func pair() -> (id: String, secret: String)? {
        if let cached = cachedPair { return cached }
        let read = SpotifyKeys.pair(keys)
        cachedPair = .some(read)
        return read
    }

    /// After a save or a remove in Settings.
    func forgetKey() { cachedPair = nil; token = nil }

    /// The country for `market` (client credentials know no user country): the Mac's region, else US.
    static var market: String { Locale.current.region?.identifier ?? "US" }

    func search(_ query: String) async -> Result<[SpotifyHit], Failure> {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .success([]) }
        guard let pair = pair() else { return .failure(.noKey) }
        for attempt in 0..<2 {
            let bearer: String
            switch await accessToken(pair) {
            case .success(let t): bearer = t
            case .failure(let f): return .failure(f)
            }
            var c = URLComponents(url: Self.searchURL, resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "type", value: "track"),
                            URLQueryItem(name: "limit", value: String(Self.limit)), URLQueryItem(name: "market", value: Self.market)]
            var request = URLRequest(url: c.url!)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            guard let (data, status) = try? await transport(request) else { return .failure(.offline) }
            if status == 401, attempt == 0 { token = nil; continue } // an old token: one fresh try
            guard status == 200 else { return .failure(status == 401 ? .badKey : .refused(status)) }
            return .success(Self.parse(data))
        }
        return .failure(.badKey)
    }

    /// Up to `limit` tracks: name, the artists joined by ", ", and a valid `spotify:track:` URI.
    static func parse(_ data: Data) -> [SpotifyHit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = root["tracks"] as? [String: Any], let items = tracks["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item -> SpotifyHit? in
            guard let name = item["name"] as? String, let uri = item["uri"] as? String, SpotifyTrackURI.isValid(uri) else { return nil }
            let artists = (item["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return SpotifyHit(uri: uri, name: name, artist: artists.joined(separator: ", "))
        }
        .prefix(limit).map { $0 }
    }

    /// A cached token, or a new one (client credentials; renewed a minute before it ends).
    private func accessToken(_ pair: (id: String, secret: String)) async -> Result<String, Failure> {
        if let t = token, t.expires > now() { return .success(t.value) }
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        let basic = Data("\(pair.id):\(pair.secret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        request.timeoutInterval = 10
        guard let (data, status) = try? await transport(request) else { return .failure(.offline) }
        guard status == 200 else { return .failure(status == 400 || status == 401 ? .badKey : .refused(status)) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["access_token"] as? String, !value.isEmpty else { return .failure(.refused(status)) }
        let seconds = (root["expires_in"] as? Double) ?? 3600
        token = (value, now().addingTimeInterval(max(60, seconds - 60)))
        return .success(value)
    }

    /// Settings' Test button: nil when Spotify gives a token for the saved key and one search works (a search can still
    /// fail after a good token, for example when the app's owner has no Premium).
    func checkKey() async -> Failure? {
        forgetKey()
        if case .failure(let f) = await search("test") { return f }
        return nil
    }
}
