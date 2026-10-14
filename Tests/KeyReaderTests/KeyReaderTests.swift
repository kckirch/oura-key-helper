import XCTest
import SQLite3
import KeyReader
import Darwin

final class KeyReaderTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func sql(_ path: URL, _ commands: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, commands, nil, nil, nil), SQLITE_OK)
    }
    func fixture(_ key: String = "AAECAwQFBgcICQoLDA0ODw==", domain: String = KeyReader.domain) throws -> URL {
        let root = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identifier = String(repeating: "a", count: 40)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("aa"), withIntermediateDirectories: true)
        try sql(root.appendingPathComponent("Manifest.db"), "CREATE TABLE Files(fileID TEXT, domain TEXT, relativePath TEXT); INSERT INTO Files VALUES('\(identifier)','\(domain)','USER/assa.sqlite');")
        try sql(root.appendingPathComponent("aa/" + identifier), "CREATE TABLE ringconfiguration(id TEXT, auth_key TEXT); INSERT INTO ringconfiguration VALUES('test-ring','\(key)');")
        return root
    }
    func testExtractsExistingKeyAndLeavesOriginalFilesUnchanged() throws {
        let root = try fixture()
        let manifest = try Data(contentsOf: root.appendingPathComponent("Manifest.db"))
        let payload = root.appendingPathComponent("aa/" + String(repeating: "a", count: 40))
        let database = try Data(contentsOf: payload)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let keys = try KeyReader.read(root)
        XCTAssertEqual(keys, [RingKey(id: "test-ring", hex: "000102030405060708090a0b0c0d0e0f")])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Manifest.db")), manifest)
        XCTAssertEqual(try Data(contentsOf: payload), database)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
    }
    func testReadsUncheckpointedOuraWalWithoutChangingBackup() throws {
        let root = try fixture()
        let identifier = String(repeating: "a", count: 40)
        let databasePath = root.appendingPathComponent("aa/" + identifier)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databasePath.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE ringconfiguration SET auth_key='/////////////////////w==';", nil, nil, nil), SQLITE_OK)
        for (suffix, char) in [("-wal", "b"), ("-shm", "c")] {
            let id = String(repeating: char, count: 40)
            let folder = root.appendingPathComponent(String(id.prefix(2)))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: databasePath.path + suffix), to: folder.appendingPathComponent(id))
            try sql(root.appendingPathComponent("Manifest.db"), "INSERT INTO Files VALUES('\(id)','\(KeyReader.domain)','USER/assa.sqlite\(suffix)');")
        }
        let wal = root.appendingPathComponent("bb/" + String(repeating: "b", count: 40))
        let before = try Data(contentsOf: wal)
        XCTAssertEqual(try KeyReader.read(root).first?.hex, String(repeating: "ff", count: 16))
        XCTAssertEqual(try Data(contentsOf: wal), before)
    }

    func testOtherAppDomainIsNotRead() throws {
        let root = try fixture(domain: "AppDomain-com.example.other")
        XCTAssertThrowsError(try KeyReader.read(root))
    }
    func testRejectsInvalidKeysInsteadOfGeneratingOne() throws {
        XCTAssertThrowsError(try KeyReader.read(fixture("not-a-key")))
        XCTAssertNil(KeyReader.decodeKey("1234"))
        XCTAssertEqual(KeyReader.decodeKey(String(repeating: "ff", count: 16))?.count, 16)
    }
    func testEncryptedBackupIsRefusedWithoutChangingIt() throws {
        let root = try fixture()
        let data = try PropertyListSerialization.data(fromPropertyList: ["IsEncrypted": true], format: .binary, options: 0)
        try data.write(to: root.appendingPathComponent("Manifest.plist"))
        XCTAssertThrowsError(try KeyReader.read(root))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Manifest.plist")), data)
    }
    func testPayloadSymlinkCannotReadOutsideBackup() throws {
        let root = try fixture()
        let payload = root.appendingPathComponent("aa/" + String(repeating: "a", count: 40))
        let outside = directory.appendingPathComponent("outside.sqlite")
        try FileManager.default.moveItem(at: payload, to: outside)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: outside)
        XCTAssertThrowsError(try KeyReader.read(root))
    }
    func testDeletionOnlyAcceptsOwnedBackupsAndPreservesExport() throws {
        let store = ManagedBackups(root: directory.appendingPathComponent("managed"))
        let owned = try store.create()
        let foreign = try fixture()
        XCTAssertThrowsError(try store.delete(foreign))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        let output = directory.appendingPathComponent("ring.key")
        try KeyReader.save(RingKey(id: "test", hex: String(repeating: "00", count: 16)), to: output)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.delete(owned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(store.list().isEmpty)
    }
    func testDeletionRefusesSymlinkAndActiveProcess() throws {
        let store = ManagedBackups(root: directory.appendingPathComponent("managed"))
        let owned = try store.create()
        try Data(String(getpid()).utf8).write(to: owned.appendingPathComponent(".backup-active-pid"))
        XCTAssertThrowsError(try store.delete(owned))
        let alias = store.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: owned)
        XCTAssertFalse(store.isOwned(alias))
        XCTAssertThrowsError(try store.delete(alias))
    }
}
