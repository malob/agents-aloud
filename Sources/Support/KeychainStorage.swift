import Foundation
import Security

// Small wrapper around Keychain Services for storing per-app secrets
// (the ElevenLabs API key, today). NOT for passwords that should sync
// across devices — we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
// so entries stay on this Mac and don't leave via iCloud Keychain.
//
// The legacy macOS keychain scopes items to an access control list
// keyed on the caller's designated requirement (code signing identity).
// That means `swift build`'s adhoc-signed binaries — whose CDHash
// changes every rebuild — trigger "Allow access?" prompts on relaunch
// because the ACL no longer matches the caller. The build script
// signs the .app with a stable Apple Development identity precisely
// so the designated requirement stays constant across rebuilds; see
// script/build_and_run.sh.
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

    private func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    func get(_ account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
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
        let query = baseQuery(account: account)
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
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
