import Foundation
import Security

// Small wrapper around Keychain Services for storing per-app secrets
// (the ElevenLabs API key, today). NOT for passwords that should sync
// across devices — we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
// so entries stay on this Mac and don't leave via iCloud Keychain.
//
// We prefer the **data protection keychain** (iOS-style, available on
// macOS 10.15+) via `kSecUseDataProtectionKeychain: true`. This matters
// for dev builds: `swift build` produces adhoc-signed binaries whose
// hash changes every rebuild. The *legacy* macOS keychain scopes items
// by a per-binary ACL, so every rebuild triggers a "Allow access?"
// prompt. The data protection keychain scopes by bundle ID instead,
// which is stable across rebuilds.
//
// The data protection keychain requires a signed bundle with a bundle
// ID. A proper .app bundle (what `build_and_run.sh` produces) has one;
// a bare `swift test` helper binary does not and gets back
// `errSecMissingEntitlement` (-34018). When that happens we transparently
// fall back to the legacy keychain so tests can still round-trip values.
// End users only ever hit the .app path.
//
// API shape: `get` returns nil for "not found" and throws only on
// unexpected errors; `set(nil)` deletes the entry; `set(value)` upserts.
struct KeychainStorage {
    let service: String
    let useDataProtection: Bool

    // Pick the keychain mode once. The .app bundle we ship has a bundle
    // identifier in its Info.plist; swift test's helper binary does not.
    // Mixing modes mid-process causes a write-here / read-there split,
    // so we lock it in at init.
    init(service: String) {
        self.init(
            service: service,
            useDataProtection: Bundle.main.bundleIdentifier != nil
        )
    }

    init(service: String, useDataProtection: Bool) {
        self.service = service
        self.useDataProtection = useDataProtection
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
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
