import Foundation
import Testing
@testable import AgentsAloud

struct KeychainStorageTests {
    // Tests write to a unique service name per run so they don't collide
    // with the real app's Keychain entries (or with each other if run in
    // parallel).
    private func makeStorage() -> KeychainStorage {
        KeychainStorage(service: "me.malob.agentsaloud.tests.\(UUID().uuidString)")
    }

    @Test
    func roundTripsStringValue() throws {
        let storage = makeStorage()
        let account = "example-account"
        defer { try? storage.delete(account) }

        try storage.set("sk-secret-value", for: account)
        #expect(try storage.get(account) == "sk-secret-value")
    }

    @Test
    func updatesExistingValue() throws {
        let storage = makeStorage()
        let account = "example-account"
        defer { try? storage.delete(account) }

        try storage.set("first", for: account)
        try storage.set("second", for: account)
        #expect(try storage.get(account) == "second")
    }

    @Test
    func deletesValueWhenSetToNil() throws {
        let storage = makeStorage()
        let account = "example-account"
        defer { try? storage.delete(account) }

        try storage.set("value", for: account)
        try storage.set(nil, for: account)
        #expect(try storage.get(account) == nil)
    }

    @Test
    func returnsNilForMissingAccount() throws {
        let storage = makeStorage()
        #expect(try storage.get("never-set") == nil)
    }

    @Test
    func deleteOnMissingAccountIsNoOp() throws {
        let storage = makeStorage()
        try storage.delete("never-set")  // must not throw
    }
}
