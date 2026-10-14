import XCTest
import KeyReader

final class BackupDiagnosticTests: XCTestCase {
    func testActivityIsIncrementalBoundedAndDoesNotTreatOtherOutputAsActivity() {
        var diagnostic = BackupDiagnostic()
        diagnostic.consume(Data("OURA_ACTIV".utf8))
        XCTAssertNil(diagnostic.activity)
        diagnostic.consume(Data("ITY {\"files\":19532,\"bytes\":123456789,\"indexReady\":false,\"path\":\"private\"}\n".utf8))
        XCTAssertEqual(diagnostic.activity?.files, 19532)
        XCTAssertEqual(diagnostic.activity?.bytes, 123456789)
        XCTAssertEqual(diagnostic.activityUpdates, 1)
        diagnostic.consume(Data("private unrelated output\nOURA_ACTIVITY {\"files\":-1,\"bytes\":0,\"indexReady\":false}\nOURA_ACTIVITY {\"files\":true,\"bytes\":0,\"indexReady\":false}\nOURA_ACTIVITY {\"files\":1,\"bytes\":10,\"indexReady\":false}\n".utf8))
        XCTAssertEqual(diagnostic.activityUpdates, 1)
        diagnostic.consume(Data("OURA_ACTIVITY {\"files\":19533,\"bytes\":123456790,\"indexReady\":true}\n".utf8))
        XCTAssertEqual(diagnostic.activityUpdates, 2)
        XCTAssertEqual(diagnostic.activity?.indexReady, true)
        XCTAssertFalse(diagnostic.failure(exitStatus: 1).contains("private"))
    }
    func testPayloadDetailsOnlyUseRecognizedCategories() {
        var diagnostic = BackupDiagnostic()
        diagnostic.consume(Data("OURA_FAILURE {\"stage\":\"payload\",\"kind\":\"OuraPayloadMissing\",\"payload\":\"journal\",\"state\":\"absent\",\"message\":\"private\"}\n".utf8))
        XCTAssertTrue(diagnostic.failure(exitStatus: 1).contains("journal/absent"))
        XCTAssertFalse(diagnostic.failure(exitStatus: 1).contains("private"))
    }
    func testStructuredFailureIdentifiesStageWithoutEchoingPrivateFields() {
        var diagnostic = BackupDiagnostic()
        diagnostic.consume(Data("OURA_FAILURE {\"stage\":\"payload\",\"kind\":\"OuraPayloadMissing\",\"deviceCode\":104,\"message\":\"secret-key/private/file\"}\n".utf8))
        let message = diagnostic.failure(exitStatus: 1)
        XCTAssertTrue(message.contains("wasn’t received completely"))
        XCTAssertTrue(message.contains("payload/OuraPayloadMissing; device code 104"))
        XCTAssertFalse(message.contains("secret")); XCTAssertFalse(message.contains("/private/file"))
    }
    func testUnrecognizedStructuredFieldsAreNotEchoedAnd902IsNotCalledADeviceError() {
        var diagnostic = BackupDiagnostic()
        diagnostic.consume(Data("OURA_FAILURE {\"stage\":\"private-stage\",\"kind\":\"secret-key\"}\nErrorCode 902: private message\n".utf8))
        let message = diagnostic.failure(exitStatus: 1)
        XCTAssertTrue(message.contains("older collector"))
        XCTAssertFalse(message.contains("Device error")); XCTAssertFalse(message.contains("private")); XCTAssertFalse(message.contains("secret"))
    }
    func testSplitErrorCodeIsCapturedWithoutItsSensitiveDescription() {
        var diagnostic = BackupDiagnostic()
        diagnostic.consume(Data("Unrelated/private/file\nErrorCo".utf8))
        diagnostic.consume(Data("de 104: sensitive description\n".utf8))
        diagnostic.finish()
        XCTAssertEqual(diagnostic.errorCode, 104)
        let message = diagnostic.failure(exitStatus: 1)
        XCTAssertTrue(message.contains("104"))
        XCTAssertFalse(message.contains("sensitive")); XCTAssertFalse(message.contains("private"))
    }
    func testProgressAcceptsOnlyBoundedIntegers() {
        var diagnostic = BackupDiagnostic()
        diagnostic.consume(Data("OURA_PROGRESS 42\n".utf8))
        XCTAssertEqual(diagnostic.progress, 42)
        diagnostic.consume(Data("OURA_PROGRESS 101\nOURA_PROGRESS -1\nOURA_PROGRESS private-data\n".utf8))
        XCTAssertEqual(diagnostic.progress, 42)
    }
    func testOversizedOrMalformedLinesCannotBecomeFailureCodes() {
        var diagnostic = BackupDiagnostic()
        diagnostic.consume(Data((String(repeating: "x", count: 9000) + "ErrorCode 5: ignored\nErrorCode oops: ignored\nErrorCode 0: successful\n").utf8))
        diagnostic.finish()
        XCTAssertNil(diagnostic.errorCode)
        XCTAssertTrue(diagnostic.failure(exitStatus: 7).contains("exit status: 7"))
    }
}
