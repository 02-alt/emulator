import CryptoKit
import Foundation
import Security

/// The player's RetroAchievements credentials (username + Web API key). The username is a public
/// handle and lives in UserDefaults; the **Web API key is a secret and lives in the Keychain**. The
/// key is obtained from the user's RA account settings page.
public struct RACredentials: Sendable {
    public let username: String
    public let apiKey: String

    private static let usernameKey = "ra.username"
    /// Keychain account name for the API key. This is also the *legacy* UserDefaults key it used to
    /// live under, so ``storedAPIKey`` can migrate an old plaintext value out on first read.
    private static let apiKeyAccount = "ra.apiKey"

    public static var stored: RACredentials? {
        guard let u = UserDefaults.standard.string(forKey: usernameKey), !u.isEmpty,
              let k = storedAPIKey, !k.isEmpty else { return nil }
        return RACredentials(username: u, apiKey: k)
    }
    public static var isConfigured: Bool { stored != nil }

    /// The API key from the Keychain. If an old build left one in UserDefaults, it's migrated into
    /// the Keychain (and the plaintext copy deleted) the first time it's read, so upgrading users
    /// keep their key without re-entering it.
    public static var storedAPIKey: String? {
        if let k = RAKeychain.get(account: apiKeyAccount), !k.isEmpty { return k }
        if let legacy = UserDefaults.standard.string(forKey: apiKeyAccount), !legacy.isEmpty {
            RAKeychain.set(legacy, account: apiKeyAccount)
            UserDefaults.standard.removeObject(forKey: apiKeyAccount)
            return legacy
        }
        return nil
    }

    public static func store(username: String, apiKey: String) {
        UserDefaults.standard.set(username, forKey: usernameKey)
        setAPIKey(apiKey)
    }

    /// Persist just the API key to the Keychain (empty clears it). Also drops any stale plaintext
    /// copy from UserDefaults so the secret never lingers there.
    public static func setAPIKey(_ key: String) {
        if key.isEmpty { RAKeychain.delete(account: apiKeyAccount) }
        else { RAKeychain.set(key, account: apiKeyAccount) }
        UserDefaults.standard.removeObject(forKey: apiKeyAccount)
    }
}

/// Minimal Keychain string store for a single service. Items use `kSecAttrAccessibleAfterFirstUnlock`
/// so background achievement checks can read the key while the device is locked.
enum RAKeychain {
    private static let service = "RetroAchievements"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add.merge(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

public struct RAAchievement: Sendable {
    public let id: Int
    public let title: String
    public let points: Int
    public let type: String?      // "progression" | "win_condition" | "missable" | nil
    public let earned: Bool
}

/// A game's achievement set + the player's progress. `storyPercent` uses the "progression"-typed
/// achievements (RA's own notion of main-story steps), falling back to overall completion.
public struct RAGameProgress: Sendable {
    public let gameID: Int
    public let total: Int
    public let earned: Int
    public let points: Int
    public let earnedPoints: Int
    public let achievements: [RAAchievement]

    public var storyPercent: Double {
        let progression = achievements.filter { $0.type == "progression" }
        if !progression.isEmpty {
            return Double(progression.filter(\.earned).count) / Double(progression.count)
        }
        return total > 0 ? Double(earned) / Double(total) : 0
    }
}

/// The outcome of resolving a ROM to RetroAchievements progress — distinct cases so the UI can
/// explain *why* there are no trophies rather than just showing an empty panel.
public enum RAFetchResult: Sendable {
    case ok(RAGameProgress)   // matched, progress loaded
    case notFound             // credentials fine, but this ROM isn't a game RA tracks
    case failed               // couldn't read the ROM, or the RA API was unreachable
}

/// Minimal RetroAchievements Web API client. Resolves a ROM to an RA game by MD5 (GBA hashes are a
/// straight full-file MD5), then fetches the achievement set + the player's earned progress.
public enum RetroAchievements {
    private static let consoleGBA = 5
    private static let consolePSX = 12
    private static let base = "https://retroachievements.org/API/"

    /// Full-file MD5 (the RetroAchievements hash for Game Boy Advance).
    public static func md5(ofFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Resolve a ROM to its RA progress, distinguishing "not tracked" from a genuine failure so the
    /// caller can surface the difference. Assumes credentials are configured (caller checks first).
    public static func fetch(forROMAt romURL: URL, system: GameSystem = .gba) async -> RAFetchResult {
        // RA identifies GBA carts by a whole-file MD5, but a PS1 disc by its boot-executable hash.
        let isPSX = system == .ps1
        let console = isPSX ? consolePSX : consoleGBA
        guard let creds = RACredentials.stored,
              let hash = isPSX ? PSXDiscHash.raHash(for: romURL) : md5(ofFileAt: romURL)
        else { return .failed }
        let map = await hashMap(console: console, creds: creds)
        // An empty map means the game-list request itself failed (offline / bad key). A populated map
        // with no match means this game genuinely isn't one RA tracks.
        guard let id = map[hash.lowercased()] else { return map.isEmpty ? .failed : .notFound }
        guard let progress = await progress(gameID: id, creds: creds) else { return .failed }
        return .ok(progress)
    }

    // MARK: - Hash → game ID (via the cached GBA hash library)

    nonisolated(unsafe) private static var cachedMaps: [Int: [String: Int]] = [:]
    private static func cacheFile(_ console: Int) -> URL {
        AppPaths.appSupport.appendingPathComponent("ra-console\(console)-hashes.json")
    }

    private struct GameListEntry: Decodable { let ID: Int; let Hashes: [String]? }

    /// A console's hash→gameID map, cached on disk (refreshed weekly).
    private static func hashMap(console: Int, creds: RACredentials) async -> [String: Int] {
        if let cached = cachedMaps[console] { return cached }

        // Use the on-disk cache if it's fresh.
        let file = cacheFile(console)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 7 * 24 * 3600,
           let data = try? Data(contentsOf: file),
           let map = try? JSONDecoder().decode([String: Int].self, from: data) {
            cachedMaps[console] = map
            return map
        }

        // Fetch the console's game list with hashes (games with achievements only).
        var comps = URLComponents(string: base + "API_GetGameList.php")!
        comps.queryItems = [
            .init(name: "i", value: "\(console)"),
            .init(name: "f", value: "1"),   // has-achievements only
            .init(name: "h", value: "1"),   // include hashes
            .init(name: "y", value: creds.apiKey),
        ]
        guard let entries: [GameListEntry] = await get(comps.url) else { return cachedMaps[console] ?? [:] }

        var map: [String: Int] = [:]
        for e in entries { for h in e.Hashes ?? [] { map[h.lowercased()] = e.ID } }
        cachedMaps[console] = map
        try? JSONEncoder().encode(map).write(to: file)
        return map
    }

    // MARK: - Game progress

    private struct ProgressDTO: Decodable {
        let NumAchievements: Int?
        let NumAwardedToUser: Int?
        let Achievements: [String: AchievementDTO]?
    }
    private struct AchievementDTO: Decodable {
        let ID: Int?; let Title: String?; let Points: Int?; let type: String?; let DateEarned: String?
    }

    private static func progress(gameID: Int, creds: RACredentials) async -> RAGameProgress? {
        var comps = URLComponents(string: base + "API_GetGameInfoAndUserProgress.php")!
        comps.queryItems = [
            .init(name: "g", value: "\(gameID)"),
            .init(name: "u", value: creds.username),
            .init(name: "y", value: creds.apiKey),
        ]
        guard let dto: ProgressDTO = await get(comps.url) else { return nil }

        let achievements = (dto.Achievements ?? [:]).values.map {
            RAAchievement(id: $0.ID ?? 0, title: $0.Title ?? "", points: $0.Points ?? 0,
                          type: $0.type, earned: $0.DateEarned != nil)
        }
        return RAGameProgress(
            gameID: gameID,
            total: dto.NumAchievements ?? achievements.count,
            earned: dto.NumAwardedToUser ?? achievements.filter(\.earned).count,
            points: achievements.reduce(0) { $0 + $1.points },
            earnedPoints: achievements.filter(\.earned).reduce(0) { $0 + $1.points },
            achievements: achievements)
    }

    // MARK: - Networking

    private static func get<T: Decodable>(_ url: URL?) async -> T? {
        guard let url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            NSLog("RetroAchievements request failed: \(error)")
            return nil
        }
    }
}
