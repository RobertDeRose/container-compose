// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A plugin-owned identity record, not a copy of the machine daemon's runtime state.
public struct OwnershipRecord: Codable, Equatable, Sendable {
    public let machineID: String
    public let imageDigest: String
    public let username: String
    public let uid: UInt32
    public let gid: UInt32
    public let token: UUID

    public init(machineID: String, imageDigest: String, username: String, uid: UInt32, gid: UInt32, token: UUID = UUID()) {
        self.machineID = machineID
        self.imageDigest = imageDigest
        self.username = username
        self.uid = uid
        self.gid = gid
        self.token = token
    }

    public func matches(machineID: String, imageDigest: String, username: String, uid: UInt32, gid: UInt32) -> Bool {
        self.machineID == machineID && self.imageDigest == imageDigest && self.username == username
            && self.uid == uid && self.gid == gid
    }

    public var guestToken: String { token.uuidString.lowercased() }
}

public struct OwnershipStore: Sendable {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("machine.json") }

    public init(appRoot: URL) {
        directory = appRoot.appendingPathComponent("plugin-state/compose", isDirectory: true)
    }

    public func load() throws -> OwnershipRecord? {
        do {
            return try JSONDecoder().decode(OwnershipRecord.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public func saveNew(_ record: OwnershipRecord) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The caller holds the plugin's initialization lock. Do not overwrite
        // an existing identity, even when the existing file cannot be decoded.
        let data = try JSONEncoder().encode(record)
        try data.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
