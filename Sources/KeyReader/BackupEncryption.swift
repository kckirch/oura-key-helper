import Foundation

/// The journal contains only a device identifier, never its password.
public struct BackupEncryption {
    public let journal: URL
    public init(journal: URL) { self.journal = journal }
    public var pendingDevice: String? { try? String(contentsOf: journal, encoding: .utf8) }
    public typealias Command = ([String], String?) async throws -> String

    public func disable(device: String, password: String, command: Command) async throws {
        guard pendingDevice == nil, !device.isEmpty, !password.isEmpty else {
            throw ReaderError.message("Restore pending encryption first, and enter the current backup password.")
        }
        guard try await encrypted(device, command: command) else {
            throw ReaderError.message("Backup encryption changed. Check the connection and try again.")
        }
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Record recovery before sending the mutation: a disconnect can hide a successful change.
        guard FileManager.default.createFile(atPath: journal.path, contents: Data(device.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ReaderError.message("Couldn’t save the encryption recovery reminder. Nothing was changed.")
        }
        _ = try await command(["-u", device, "encryption", "off"], password)
        guard try await !encrypted(device, command: command) else {
            throw ReaderError.message("Backup encryption is still enabled. No backup was started.")
        }
    }
    public func restore(password: String, command: Command) async throws {
        guard let device = pendingDevice else { return }
        if try await !encrypted(device, command: command) {
            guard !password.isEmpty else { throw ReaderError.message("Enter the original backup password to restore encryption.") }
            _ = try await command(["-u", device, "encryption", "on"], password)
            guard try await encrypted(device, command: command) else {
                throw ReaderError.message("Backup encryption could not be verified. Reconnect the phone and restore encryption.")
            }
        }
        try FileManager.default.removeItem(at: journal)
    }
    private func encrypted(_ device: String, command: Command) async throws -> Bool {
        let value = try await command(["-u", device, "-q", "com.apple.mobile.backup", "-k", "WillEncrypt"], nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ["true", "false"].contains(value) { return value == "true" }
        if value.isEmpty {
            let domain = try await command(["-u", device, "-q", "com.apple.mobile.backup", "--xml"], nil)
            if let enabled = USBConnection.backupEncryption(in: domain) { return enabled }
        }
        throw ReaderError.message("Couldn’t verify backup encryption. Reconnect and unlock the original phone.")
    }
}
