// Copyright © 2026 the container-compose authors.
// SPDX-License-Identifier: Apache-2.0
import ComposeSupport
import Foundation
import Testing

@Suite("Plugin-owned machine identity")
struct OwnershipTests {
    private func record() -> OwnershipRecord {
        OwnershipRecord(machineID: "compose", imageDigest: "sha256:abc", username: "test", uid: 501, gid: 20)
    }

    @Test func roundTrip() throws {
        let record = record()
        #expect(try JSONDecoder().decode(OwnershipRecord.self, from: JSONEncoder().encode(record)) == record)
        #expect(UUID(uuidString: record.guestToken) == record.token)
    }

    @Test func identitiesAreUnique() {
        #expect(record().token != record().token)
    }

    @Test func immutableIdentityMatches() {
        #expect(record().matches(machineID: "compose", imageDigest: "sha256:abc", username: "test", uid: 501, gid: 20))
    }

    @Test(arguments: ["id", "image", "username", "uid", "gid"])
    func changedIdentityIsRejected(field: String) {
        #expect(
            !record().matches(
                machineID: field == "id" ? "foreign" : "compose",
                imageDigest: field == "image" ? "sha256:other" : "sha256:abc",
                username: field == "username" ? "other" : "test",
                uid: field == "uid" ? 502 : 501,
                gid: field == "gid" ? 21 : 20
            ))
    }

    @Test func storeIsSeparateFromDaemonState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OwnershipStore(appRoot: root)
        #expect(store.file.path.hasSuffix("/plugin-state/compose/machine.json"))
        #expect(try store.load() == nil)
        let record = record()
        try store.saveNew(record)
        #expect(try store.load() == record)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: (any Error).self) { try store.saveNew(self.record()) }
        #expect(try store.load() == record)
    }

    @Test func corruptRecordIsNotTreatedAsAbsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OwnershipStore(appRoot: root)
        try store.saveNew(record())
        try Data("broken".utf8).write(to: store.file)
        #expect(throws: DecodingError.self) { try store.load() }
        #expect(throws: (any Error).self) { try store.saveNew(self.record()) }
        #expect(try String(contentsOf: store.file, encoding: .utf8) == "broken")
    }
}
