import Foundation
import Security

/// A keychain-backed store for a single generic-password item.
///
/// The `SecItem*` calls are injected rather than called directly so that tests can
/// exercise the failure paths (locked keychain, denied access) without touching — and
/// clobbering — the real login keychain entry the app depends on.
struct KeychainStore {
    typealias AddItem = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias CopyMatching = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias DeleteItem = (CFDictionary) -> OSStatus

    private let service: String
    private let account: String
    private let addItem: AddItem
    private let copyMatching: CopyMatching
    private let deleteItem: DeleteItem

    init(
        service: String,
        account: String,
        addItem: @escaping AddItem = SecItemAdd,
        copyMatching: @escaping CopyMatching = SecItemCopyMatching,
        deleteItem: @escaping DeleteItem = SecItemDelete
    ) {
        self.service = service
        self.account = account
        self.addItem = addItem
        self.copyMatching = copyMatching
        self.deleteItem = deleteItem
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Saves the given API key, overwriting any existing entry.
    /// - Returns: `true` if the key was stored; `false` if the keychain rejected it.
    func save(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        // Add first and only clear the way once the keychain has told us something is
        // already there. Deleting up front would mean a rejected add — locked keychain,
        // denied access — leaves the user with no key at all, having destroyed the
        // working one they had.
        let status = addItem(query as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem, delete() else { return false }

        return addItem(query as CFDictionary, nil) == errSecSuccess
    }

    /// Retrieves the stored API key, or `nil` if none exists.
    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the stored API key if it exists.
    /// - Returns: `true` if the item is gone afterwards — including when it never existed.
    @discardableResult
    func delete() -> Bool {
        let status = deleteItem(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Simple wrapper around the macOS Keychain for storing the Hyper API key.
enum KeychainHelper {
    private static let service = "soy.iko.usage-menubar"
    private static let account = "hyper-api-key"

    private static let store = KeychainStore(service: service, account: account)

    /// Saves the given API key to the Keychain, overwriting any existing entry.
    /// - Returns: `true` on success; `false` if the item could not be stored, e.g. because
    ///   the keychain is locked.
    @discardableResult
    static func save(_ key: String) -> Bool {
        store.save(key)
    }

    /// Retrieves the stored API key, or `nil` if none exists.
    static func load() -> String? {
        store.load()
    }

    /// Deletes the stored API key if it exists.
    @discardableResult
    static func delete() -> Bool {
        store.delete()
    }
}

/// Wrapper around the macOS Keychain for storing the z.ai API key.
///
/// Uses the same keychain service as the Hyper key but a different account, so the
/// two keys coexist without clobbering each other.
enum ZaiKeychainHelper {
    private static let service = "soy.iko.usage-menubar"
    private static let account = "zai-api-key"

    private static let store = KeychainStore(service: service, account: account)

    /// Saves the given z.ai API key to the Keychain, overwriting any existing entry.
    @discardableResult
    static func save(_ key: String) -> Bool {
        store.save(key)
    }

    /// Retrieves the stored z.ai API key, or `nil` if none exists.
    static func load() -> String? {
        store.load()
    }

    /// Deletes the stored z.ai API key if it exists.
    @discardableResult
    static func delete() -> Bool {
        store.delete()
    }
}
