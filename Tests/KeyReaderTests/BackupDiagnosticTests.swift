import XCTest
import KeyReader

final class BackupDiagnosticTests: XCTestCase {
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
    func testOversizedOrMalformedLinesCannotBecomeFailureCodes() {
        var diagnostic = BackupDiagnostic()
        diagnostic.consume(Data((String(repeating: "x", count: 9000) + "ErrorCode 5: ignored\nErrorCode oops: ignored\nErrorCode 0: successful\n").utf8))
        diagnostic.finish()
        XCTAssertNil(diagnostic.errorCode)
        XCTAssertTrue(diagnostic.failure(exitStatus: 7).contains("exit status: 7"))
    }
}
