import Foundation
import Security

// MARK: - KeychainError

/// Keychain 操作错误
public enum KeychainError: LocalizedError {
    case unableToSave(OSStatus)
    case unableToRead(OSStatus)
    case unableToDelete(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unableToSave(let s): "Keychain 保存失败 (OSStatus: \(s))"
        case .unableToRead(let s): "Keychain 读取失败 (OSStatus: \(s))"
        case .unableToDelete(let s): "Keychain 删除失败 (OSStatus: \(s))"
        }
    }
}

/// Keychain 服务，安全存储多个 App Store 账号
public final class KeychainService {
    public nonisolated(unsafe) static let shared = KeychainService()
    private let service = "cn.ipatool.account"

    private init() {}

    // MARK: - 多账号存取

    public func saveAccount(_ account: Account) throws {
        let data = try JSONEncoder().encode(account)
        try save(key: account.id, data: data)
    }

    public func loadAccount(id: String) throws -> Account? {
        guard let data = try load(key: id) else { return nil }
        return try JSONDecoder().decode(Account.self, from: data)
    }

    public func loadAllAccounts() throws -> [Account] {
        // 先获取所有账号的 key，再逐个加载，避免 kSecMatchLimitAll + kSecReturnData 的兼容问题
        let attrQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var attrResult: AnyObject?
        let attrStatus = SecItemCopyMatching(attrQuery as CFDictionary, &attrResult)

        if attrStatus == errSecItemNotFound { return [] }

        guard attrStatus == errSecSuccess,
              let items = attrResult as? [[String: Any]] else {
            throw KeychainError.unableToRead(attrStatus)
        }

        let keys = items.compactMap { $0[kSecAttrAccount as String] as? String }

        return try keys.compactMap { key in
            try loadAccount(id: key)
        }
    }

    public func loadAllSummaries() throws -> [AccountSummary] {
        try loadAllAccounts().map { acc in
            AccountSummary(email: acc.email, name: acc.name, region: acc.region)
        }
    }

    public func deleteAccount(id: String) throws {
        try delete(key: id)
    }

    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unableToDelete(status)
        }
    }

    // MARK: - Private

    private func save(key: String, data: Data) throws {
        try? delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToSave(status)
        }
    }

    private func load(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }

        guard status == errSecSuccess else {
            throw KeychainError.unableToRead(status)
        }

        return result as? Data
    }

    private func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unableToDelete(status)
        }
    }
}