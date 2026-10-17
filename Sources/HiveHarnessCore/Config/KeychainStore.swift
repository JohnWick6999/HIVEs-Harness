import Foundation
import Security

public enum KeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
    case itemNotFound
}

/// Keychain 抽象,便于测试注入 mock。
public protocol KeychainStoring: Sendable {
    func string(forKey key: String) throws -> String?
    func setString(_ value: String, forKey key: String) throws
    func delete(forKey key: String) throws
}

/// 基于 Security framework 的 Keychain 封装(零依赖)。
/// 用于存储 API Key 等敏感信息,对齐原版"API Key 不入配置文件"的工程实践。
public struct KeychainStore: KeychainStoring {
    public let service: String

    public init(service: String = "com.hiveharness.app") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    public func string(forKey key: String) throws -> String? {
        var query = baseQuery
        query[kSecAttrAccount as String] = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func setString(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery
        query[kSecAttrAccount as String] = key

        // 先尝试更新,不存在则新增
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            // 仅本机可读(不做 iCloud 同步),单机优先
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(insertStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func delete(forKey key: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = key
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
