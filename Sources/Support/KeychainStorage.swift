import Foundation
import Security

// Small wrapper around Keychain Services for storing per-app secrets
// (the ElevenLabs API key, today). NOT for passwords that should sync
// across devices — we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
// so entries stay on this Mac and don't leave via iCloud Keychain.
//
// API shape: `get` returns nil for "not found" and throws only on
// unexpected errors; `set(nil)` deletes the entry; `set(value)` upserts.
struct KeychainStorage {
    let service: String

    init(service: String) {
        self.service = service
    }

    enum KeychainError: LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
                return "\(message) (\(status))"
            }
        }
    }

    func get(_ account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &result) {
            SecItemCopyMatching(query as CFDictionary, $0)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // Upserts `value`. Passing nil deletes the entry.
    func set(_ value: String?, for account: String) throws {
        guard let value else {
            try delete(account)
            return
        }
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            for (key, value) in attributes {
                addQuery[key] = value
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    func delete(_ account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
