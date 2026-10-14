import XCTest
import KeyReader

final class USBConnectionTests: XCTestCase {
    func testUSBProbeDistinguishesAbsentConnectedAndMultipleDevices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("idevice_id")
        func stub(_ listing: String) throws {
            let source = "#!/bin/sh\nif [ \"$1\" = \"-l\" ]; then printf '%s' '\(listing)'; else printf '%s' 'Test iPhone'; fi\n"
            try source.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        }
        try stub("")
        var status = await USBConnection.check(using: tool)
        XCTAssertEqual(status, .none); XCTAssertFalse(status.canBackUp)
        try stub("test-device\n")
        status = await USBConnection.check(using: tool)
        XCTAssertEqual(status, .connected("Test iPhone")); XCTAssertTrue(status.canBackUp)
        try stub("device-one\ndevice-two\n")
        status = await USBConnection.check(using: tool)
        XCTAssertEqual(status, .multiple(2)); XCTAssertFalse(status.canBackUp)
        status = await USBConnection.check(using: nil)
        XCTAssertEqual(status, .missingTools); XCTAssertFalse(status.canBackUp)
    }
    func testEncryptedOrUntrustedPhoneCannotStartBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = root.appendingPathComponent("idevice_id")
        let info = root.appendingPathComponent("ideviceinfo")
        try "#!/bin/sh\nif [ \"$1\" = \"-l\" ]; then printf 'test-device'; else printf 'Test iPhone'; fi\n".write(to: device, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: device.path)
        func setting(_ result: String) throws {
            try ("#!/bin/sh\n" + result + "\n").write(to: info, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: info.path)
        }
        try setting("printf true")
        var status = await USBConnection.check(using: device, info: info)
        XCTAssertEqual(status, .encrypted("Test iPhone")); XCTAssertFalse(status.canBackUp)
        try setting("exit 1")
        status = await USBConnection.check(using: device, info: info)
        XCTAssertEqual(status, .needsTrust("Test iPhone")); XCTAssertFalse(status.canBackUp)
        try setting("printf false")
        status = await USBConnection.check(using: device, info: info)
        XCTAssertEqual(status, .connected("Test iPhone")); XCTAssertTrue(status.canBackUp)
    }

    func testFailedConnectionCheckDoesNotReportNoPhone() async {
        let status = await USBConnection.check(using: URL(fileURLWithPath: "/does-not-exist/idevice_id"))
        XCTAssertEqual(status, .unavailable)
        XCTAssertFalse(status.canBackUp)
    }
}
