import XCTest
import KeyReader

final class BackupEncryptionTests: XCTestCase {
    var root: URL!
    var recovery: BackupEncryption!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        recovery = BackupEncryption(journal: root.appendingPathComponent("recovery"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func testDisableAndRestoreVerifyStateAndKeepPasswordOutOfJournalAndArguments() async throws {
        var enabled = true
        let command: BackupEncryption.Command = { args, password in
            XCTAssertFalse(args.contains("fixture-password"))
            if args.contains("encryption") {
                XCTAssertEqual(self.recovery.pendingDevice, "fixture-device")
                XCTAssertEqual(password, "fixture-password")
                enabled = args.last == "on"
                return ""
            }
            XCTAssertNil(password)
            return enabled ? "true" : "false"
        }
        try await recovery.disable(device: "fixture-device", password: "fixture-password", command: command)
        XCTAssertFalse(enabled)
        XCTAssertEqual(try String(contentsOf: recovery.journal), "fixture-device")
        let attrs = try FileManager.default.attributesOfItem(atPath: recovery.journal.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try await recovery.restore(password: "fixture-password", command: command)
        XCTAssertTrue(enabled); XCTAssertNil(recovery.pendingDevice)
    }
    func testWrongPasswordLeavesEncryptionEnabledAndRecoveryClearsWithoutAnotherMutation() async throws {
        do {
            try await recovery.disable(device: "fixture-device", password: "wrong", command: { args, _ in
                if args.contains("encryption") { throw ReaderError.message("Rejected") }
                return "true"
            })
            XCTFail("Expected rejection")
        } catch {}
        XCTAssertNotNil(recovery.pendingDevice)
        try await recovery.restore(password: "", command: { args, _ in
            XCTAssertFalse(args.contains("encryption")); return "true"
        })
        XCTAssertNil(recovery.pendingDevice)
    }
    func testDisconnectRetainsReminderAcrossRelaunchAndTargetsOriginalDevice() async throws {
        try await recovery.disable(device: "original-device", password: "fixture", command: { args, _ in
            if args.contains("encryption") { return "" }
            return self.recovery.pendingDevice == nil ? "true" : "false"
        })
        let reopened = BackupEncryption(journal: recovery.journal)
        do {
            try await reopened.restore(password: "fixture", command: { args, _ in
                XCTAssertEqual(args[1], "original-device")
                throw ReaderError.message("Disconnected")
            })
            XCTFail("Expected disconnect")
        } catch {}
        XCTAssertEqual(reopened.pendingDevice, "original-device")
    }
    func testFailedRestoreVerificationKeepsReminder() async throws {
        try await recovery.disable(device: "fixture-device", password: "fixture", command: { args, _ in
            if args.contains("encryption") { return "" }
            return self.recovery.pendingDevice == nil ? "true" : "false"
        })
        do {
            try await recovery.restore(password: "fixture", command: { args, _ in
                args.contains("encryption") ? "" : "false"
            })
            XCTFail("Expected verification failure")
        } catch {}
        XCTAssertNotNil(recovery.pendingDevice)
    }
    func testUnverifiedInitialStateNeverMutatesOrCreatesJournal() async throws {
        do {
            try await recovery.disable(device: "fixture-device", password: "fixture", command: { args, _ in
                XCTAssertFalse(args.contains("encryption")); return "unknown"
            })
            XCTFail("Expected refusal")
        } catch {}
        XCTAssertNil(recovery.pendingDevice)
    }
}
