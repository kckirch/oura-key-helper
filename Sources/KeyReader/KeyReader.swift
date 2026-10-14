import Foundation
import SQLite3
import Darwin

public struct RingKey: Identifiable, Equatable {
    public var id: String
    public var hex: String
    public init(id: String, hex: String) { self.id = id; self.hex = hex }
}
public enum ReaderError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
private final class ReadOnlyDatabase {
    let handle: OpaquePointer
    init(_ path: URL) throws {
        var db: OpaquePointer?
        // A checkpointed backup can retain WAL mode without a WAL file. Immutable
        // reads avoid creating missing journal files; existing WALs are still honored.
        let hasWal = FileManager.default.fileExists(atPath: path.path + "-wal")
        let location = hasWal ? path.path : path.absoluteString + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(location, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let opened = db else {
            if let db { sqlite3_close(db) }
            throw ReaderError.message("Could not read the selected database. Check that the backup is complete and accessible.")
        }
        handle = opened
        sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil)
    }
    deinit { sqlite3_close(handle) }
    func query(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReaderError.message("The expected Oura backup schema was not found. This app or backup version may not be supported.")
        }
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { try body(statement); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw ReaderError.message("Could not finish reading the database. The backup may be incomplete.") }
    }
}
private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
}

public enum KeyReader {
    public static let domain = "AppDomain-com.ouraring.oura"
    public static func decodeKey(_ value: String) -> Data? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count == 32, value.allSatisfy({ $0.isHexDigit && $0.isASCII }) {
            var data = Data()
            var index = value.startIndex
            while index < value.endIndex {
                let end = value.index(index, offsetBy: 2)
                guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
                data.append(byte); index = end
            }
            return data
        }
        guard let data = Data(base64Encoded: value), data.count == 16 else { return nil }
        return data
    }
    public static func read(_ backup: URL) throws -> [RingKey] {
        let root = backup.resolvingSymlinksInPath().standardizedFileURL
        let manifestPlist = root.appendingPathComponent("Manifest.plist")
        if FileManager.default.fileExists(atPath: manifestPlist.path) {
            let data = try Data(contentsOf: manifestPlist)
            let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            if dictionary?["IsEncrypted"] as? Bool == true {
                throw ReaderError.message("This backup is encrypted. This prototype cannot decrypt it and will not change your encryption settings. You can delete a backup created by this helper below.")
            }
        }
        let manifest = root.appendingPathComponent("Manifest.db")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw ReaderError.message("Choose the backup folder containing Manifest.db, not the MobileSync folder above it.")
        }
        let index = try ReadOnlyDatabase(manifest)
        var entries: [String: URL] = [:]
        try index.query("SELECT fileID, relativePath FROM Files WHERE domain = 'AppDomain-com.ouraring.oura' AND (relativePath = 'assa.sqlite' OR relativePath LIKE '%/assa.sqlite' OR relativePath LIKE '%/assa.sqlite-wal' OR relativePath LIKE '%/assa.sqlite-shm')") { row in
            guard let fileID = text(row, 0), fileID.count == 40, fileID.allSatisfy({ $0.isHexDigit && $0.isASCII }),
                  let relative = text(row, 1), !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
                  ["assa.sqlite", "assa.sqlite-wal", "assa.sqlite-shm"].contains(URL(fileURLWithPath: relative).lastPathComponent) else {
                throw ReaderError.message("The backup contains an invalid Oura file entry.")
            }
            let grouped = root.appendingPathComponent(String(fileID.prefix(2))).appendingPathComponent(fileID)
            let flat = root.appendingPathComponent(fileID)
            let file = (FileManager.default.fileExists(atPath: grouped.path) ? grouped : flat).resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
                throw ReaderError.message("An Oura database file is missing or points outside this backup.")
            }
            entries[relative] = file
        }
        let databases = entries.keys.filter { $0.hasSuffix("assa.sqlite") }.sorted()
        guard !databases.isEmpty else { throw ReaderError.message("No Oura assa.sqlite database was found in this backup. Confirm official Oura was installed and had synced this ring before the backup. Current Oura versions may exclude this file.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("oura-key-reader-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        var found: [RingKey] = []
        for (offset, name) in databases.enumerated() {
            let folder = temporary.appendingPathComponent(String(offset))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            // SQLite may need its WAL/SHM. Only Oura's matching files are copied; originals stay read-only.
            for suffix in ["", "-wal", "-shm"] {
                if let file = entries[name + suffix] { try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("assa.sqlite" + suffix)) }
            }
            let database = try ReadOnlyDatabase(folder.appendingPathComponent("assa.sqlite"))
            try database.query("SELECT id, auth_key FROM ringconfiguration WHERE auth_key IS NOT NULL") { row in
                guard let id = text(row, 0) else { return }
                let data: Data?
                if sqlite3_column_type(row, 1) == SQLITE_BLOB, sqlite3_column_bytes(row, 1) == 16, let bytes = sqlite3_column_blob(row, 1) {
                    data = Data(bytes: bytes, count: 16)
                } else { data = text(row, 1).flatMap(decodeKey) }
                if let data, data.count == 16 {
                    let key = RingKey(id: id, hex: data.map { String(format: "%02x", $0) }.joined())
                    if !found.contains(key) { found.append(key) }
                }
            }
        }
        guard !found.isEmpty else { throw ReaderError.message("Oura's database was found, but no valid 16-byte ring key was present. No key has been guessed or generated.") }
        return found
    }
    public static func save(_ key: RingKey, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".oura-key-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data((key.hex + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ReaderError.message("Could not create the key file.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, url.path) == 0 else { throw ReaderError.message("Could not save the key at the selected location.") }
    }
}

public struct ManagedBackups {
    public let root: URL
    public init(root: URL) { self.root = root.resolvingSymlinksInPath().standardizedFileURL }
    public func create() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(folder.lastPathComponent.utf8).write(to: folder.appendingPathComponent(".oura-helper-owned"))
        return folder
    }
    public func list() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.filter { isOwned($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }
    public func isOwned(_ folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        guard folder.deletingLastPathComponent().path == root.path, UUID(uuidString: folder.lastPathComponent) != nil,
              folder.resolvingSymlinksInPath().path == folder.path,
              root.resolvingSymlinksInPath().path == root.path,
              let marker = try? String(contentsOf: folder.appendingPathComponent(".oura-helper-owned"), encoding: .utf8) else { return false }
        return marker == folder.lastPathComponent
    }
    public func delete(_ folder: URL) throws {
        guard isOwned(folder) else { throw ReaderError.message("Deletion refused: this is not a temporary backup created by this helper.") }
        if let text = try? String(contentsOf: folder.appendingPathComponent(".backup-active-pid"), encoding: .utf8),
           let pid = Int32(text), pid > 0, kill(pid, 0) == 0 {
            throw ReaderError.message("The backup process is still running. Stop it before deleting its files.")
        }
        try FileManager.default.removeItem(at: folder)
    }
}
