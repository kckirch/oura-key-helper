import XCTest
import KeyReader

final class USBConnectionTests: XCTestCase {
    var root: URL!
    var device: URL { root.appendingPathComponent("idevice_id") }
    var info: URL { root.appendingPathComponent("ideviceinfo") }
    var installer: URL { root.appendingPathComponent("ideviceinstaller") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try devices("test-device")
        try stub(info, "printf false")
        try apps([["CFBundleIdentifier": "com.ouraring.oura"]])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func stub(_ path: URL, _ script: String) throws {
        try ("#!/bin/sh\n" + script + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }
    func devices(_ listing: String) throws {
        try stub(device, "if [ \"$1\" = \"-l\" ]; then printf '%s' '\(listing)'; else printf '%s' 'Test iPhone'; fi")
    }
    func plist(_ value: Any) throws -> String {
        String(data: try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0), encoding: .utf8)!
    }
    func apps(_ value: Any) throws {
        // Fail the test if the caller ever broadens this into an all-apps query.
        let guardArgs = "[ \"$1\" = '-u' ] && [ \"$3\" = 'list' ] && [ \"$4\" = '--bundle-identifier' ] && [ \"$5\" = 'com.ouraring.oura' ] && [ \"$6\" = '--attribute' ] && [ \"$7\" = 'CFBundleIdentifier' ] && [ \"$8\" = '--xml' ] || exit 7"
        try stub(installer, guardArgs + "\nprintf '%s' '" + plist(value) + "'")
    }
    func check() async -> USBConnection { await USBConnection.check(using: device, info: info, installer: installer) }

    func testUSBProbeDistinguishesAbsentConnectedAndMultipleDevices() async throws {
        try devices("")
        var status = await check()
        XCTAssertEqual(status, .none); XCTAssertFalse(status.canBackUp)
        try devices("test-device\n")
        status = await check()
        XCTAssertEqual(status, .connected("Test iPhone")); XCTAssertTrue(status.canBackUp)
        try devices("device-one\ndevice-two\n")
        status = await check()
        XCTAssertEqual(status, .multiple(2)); XCTAssertFalse(status.canBackUp)
        status = await USBConnection.check(using: nil, info: nil, installer: nil)
        XCTAssertEqual(status, .missingTools); XCTAssertFalse(status.canBackUp)
    }
    func testEncryptedOrUntrustedPhoneCannotStartBackup() async throws {
        try stub(info, "printf true")
        var status = await check()
        XCTAssertEqual(status, .encrypted("Test iPhone")); XCTAssertFalse(status.canBackUp)
        try stub(info, "exit 1")
        status = await check()
        XCTAssertEqual(status, .needsTrust("Test iPhone")); XCTAssertFalse(status.canBackUp)
        try stub(info, "printf false")
        status = await check()
        XCTAssertEqual(status, .connected("Test iPhone")); XCTAssertTrue(status.canBackUp)
    }
    func testFailedConnectionCheckDoesNotReportNoPhone() async {
        let status = await USBConnection.check(using: URL(fileURLWithPath: "/does-not-exist/idevice_id"), info: info, installer: installer)
        XCTAssertEqual(status, .unavailable); XCTAssertFalse(status.canBackUp)
    }
    func testMissingOfficialOuraBlocksBackupWithTargetedQuery() async throws {
        try apps([String: String]())
        var status = await check()
        XCTAssertEqual(status, .missingOura("Test iPhone")); XCTAssertFalse(status.canBackUp)
        // Report the missing prerequisite even when backup encryption is enabled too.
        try stub(info, "printf true")
        status = await check()
        XCTAssertEqual(status, .missingOura("Test iPhone")); XCTAssertFalse(status.canBackUp)
    }
    func testFailedAppQueryIsNotReportedAsNotInstalled() async throws {
        try stub(installer, "exit 1")
        var status = await check()
        XCTAssertEqual(status, .ouraCheckUnavailable("Test iPhone")); XCTAssertFalse(status.canBackUp)
        try apps([["CFBundleIdentifier": "com.example.other"]])
        status = await check()
        XCTAssertEqual(status, .ouraCheckUnavailable("Test iPhone")); XCTAssertFalse(status.canBackUp)
    }
    func testOfficialOuraPlistFormatsAndInvalidResponses() throws {
        XCTAssertEqual(USBConnection.ouraInstalled(in: try plist([["CFBundleIdentifier": "com.ouraring.oura"]])), true)
        XCTAssertEqual(USBConnection.ouraInstalled(in: try plist(["com.ouraring.oura": ["CFBundleIdentifier": "com.ouraring.oura"]])), true)
        XCTAssertEqual(USBConnection.ouraInstalled(in: try plist([[String: String]]())), false)
        XCTAssertEqual(USBConnection.ouraInstalled(in: try plist([String: String]())), false)
        XCTAssertNil(USBConnection.ouraInstalled(in: "not a plist"))
        XCTAssertNil(USBConnection.ouraInstalled(in: try plist(["error": "unverified"])))
    }
    func testAbsentEncryptionFlagUsesVerifiedBackupDomain() async throws {
        let domain = try plist(["CloudBackupEnabled": false, "Version": "2.0"] as [String: Any])
        try stub(info, "if [ \"$5\" = '--xml' ]; then printf '%s' '" + domain + "'; fi")
        var status = await check()
        XCTAssertEqual(status, .connected("Test iPhone"))
        try stub(info, "if [ \"$5\" = '--xml' ]; then printf broken; fi")
        status = await check()
        XCTAssertFalse(status.canBackUp)
    }
    func testBackupDomainEncryptionParserRejectsMalformedFlags() throws {
        XCTAssertEqual(USBConnection.backupEncryption(in: try plist(["WillEncrypt": true])), true)
        XCTAssertEqual(USBConnection.backupEncryption(in: try plist(["WillEncrypt": false])), false)
        XCTAssertEqual(USBConnection.backupEncryption(in: try plist(["Version": "2.0"])), false)
        XCTAssertNil(USBConnection.backupEncryption(in: try plist(["WillEncrypt": "false"])))
        XCTAssertNil(USBConnection.backupEncryption(in: try plist(["WillEncrypt": 1])))
        XCTAssertNil(USBConnection.backupEncryption(in: ""))
        XCTAssertNil(USBConnection.backupEncryption(in: try plist([String]())))
    }
    func testBundledProbeStatesAndInvalidResponses() {
        XCTAssertEqual(USBConnection.filteredProbe(Data("{\"state\":\"connected\",\"name\":\"Test iPad\"}".utf8)), .connected("Test iPad"))
        XCTAssertEqual(USBConnection.filteredProbe(Data("{\"state\":\"encrypted\"}".utf8)), .encrypted(""))
        XCTAssertEqual(USBConnection.filteredProbe(Data("{\"state\":\"missingOura\"}".utf8)), .missingOura(""))
        XCTAssertEqual(USBConnection.filteredProbe(Data("{\"state\":\"multiple\",\"count\":2}".utf8)), .multiple(2))
        XCTAssertEqual(USBConnection.filteredProbe(Data("{\"state\":\"multiple\",\"count\":1}".utf8)), .unavailable)
        XCTAssertEqual(USBConnection.filteredProbe(Data("{\"state\":\"unexpected\"}".utf8)), .unavailable)
        XCTAssertEqual(USBConnection.filteredProbe(Data("not json".utf8)), .unavailable)
    }
    func testMissingVerificationToolsCannotStartBackup() async {
        var status = await USBConnection.check(using: device, info: nil, installer: installer)
        XCTAssertEqual(status, .missingTools); XCTAssertFalse(status.canBackUp)
        status = await USBConnection.check(using: device, info: info, installer: nil)
        XCTAssertEqual(status, .missingTools); XCTAssertFalse(status.canBackUp)
    }
}
