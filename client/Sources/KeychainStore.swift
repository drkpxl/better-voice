import Foundation
import Security

/// Minimal generic-password Keychain wrapper for the one secret the app holds: the
/// OpenAI-compatible provider's API key.
///
/// Deliberately the legacy (file-based) login keychain, not the data-protection keychain: the
/// latter needs a `keychain-access-groups` entitlement backed by a provisioning profile, which a
/// Developer-ID app built by SwiftPM doesn't have. Items are keyed by service = bundle id, so the
/// dev channel ("Better Voice Dev", distinct bundle id) never reads the release app's key.
enum KeychainStore {
    /// Never falls back to the release id: an unbundled run (the bench binary) seeds fresh
    /// preferences, and its first save would otherwise delete the release app's key.
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.drkpxl.bettervoice2.unbundled"
    }

    enum ReadResult: Equatable {
        case value(String)
        case notFound
        /// Present but unreadable right now (locked keychain, access denied after a re-sign).
        case unavailable
    }

    static func read(_ account: String) -> ReadResult {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let data = out as? Data, let string = String(data: data, encoding: .utf8) else {
            Logger.log("Keychain", "Read \(account) failed: \(status)")
            return .unavailable
        }
        return .value(string)
    }

    /// Store `value`, or delete the item when `value` is empty. Returns false on failure.
    @discardableResult
    static func write(_ account: String, _ value: String) -> Bool {
        guard !value.isEmpty else {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(
            baseQuery(account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            Logger.log("Keychain", "Update \(account) failed: \(update)")
            return false
        }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Better Voice — \(account)"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.log("Keychain", "Add \(account) failed: \(status)")
        }
        return status == errSecSuccess
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
