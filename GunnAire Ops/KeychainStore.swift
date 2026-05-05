import Foundation
import Security

enum KeychainStore {
    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case encodingFailed
        case decodingFailed
    }

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "www.gunnaire.com.GunnAire-Ops"
    }

    static func saveCodable<T: Codable>(_ value: T, account: String) throws {
        guard let data = try? JSONEncoder().encode(value) else {
            throw KeychainError.encodingFailed
        }
        try save(data: data, account: account)
    }

    static func loadCodable<T: Codable>(_ type: T.Type, account: String) throws -> T? {
        guard let data = try loadData(account: account) else { return nil }
        guard let decoded = try? JSONDecoder().decode(type, from: data) else {
            throw KeychainError.decodingFailed
        }
        return decoded
    }

    static func remove(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func save(data: Data, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return }

        guard status == errSecDuplicateItem else {
            throw KeychainError.unexpectedStatus(status)
        }

        let updateQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attrsToUpdate: [CFString: Any] = [
            kSecValueData: data
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attrsToUpdate as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    private static func loadData(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        return item as? Data
    }
}
