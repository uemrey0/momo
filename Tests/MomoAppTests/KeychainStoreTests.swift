import Foundation
import Testing

@testable import MomoApp

@Suite("Keychain store", .serialized)
struct KeychainStoreTests {
    private let store = KeychainStore(service: "io.github.uemrey0.Momo.tests.\(UUID().uuidString)")
    private let account = "test-provider"

    @Test("a new key is saved and read back trimmed")
    func savesNewKey() throws {
        defer { try? store.setKey("", for: account) }
        try store.setKey("  sk-first \n", for: account)
        #expect(store.key(for: account) == "sk-first")
    }

    @Test("saving again replaces the existing key")
    func updatesExistingKey() throws {
        defer { try? store.setKey("", for: account) }
        try store.setKey("sk-first", for: account)
        try store.setKey("sk-second", for: account)
        #expect(store.key(for: account) == "sk-second")
    }

    @Test("an empty key deletes the saved one")
    func emptyKeyDeletes() throws {
        try store.setKey("sk-first", for: account)
        try store.setKey("", for: account)
        #expect(store.key(for: account) == nil)
    }

    @Test("deleting a key that isn't there succeeds")
    func deletingMissingKeySucceeds() throws {
        try store.setKey("", for: account)
        #expect(store.key(for: account) == nil)
    }

    @Test("the error explains the failed status")
    func errorDescription() {
        let error = KeychainError(status: errSecAuthFailed)
        #expect(error.localizedDescription.contains("Keychain"))
        #expect(error.localizedDescription.count > "Couldn't update your Keychain: ".count)
    }
}
