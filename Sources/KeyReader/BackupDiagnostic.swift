import Foundation

/// Drain tool output without retaining unrelated filenames or device data.
public struct BackupDiagnostic {
    private var line = Data()
    private var dropping = false
    public private(set) var errorCode: Int?
    public private(set) var progress: Int?
    public init() {}
    public mutating func consume(_ data: Data) {
        for byte in data {
            if byte == 10 || byte == 13 {
                if !dropping { inspectLine() }
                line.removeAll(keepingCapacity: true); dropping = false
            } else if !dropping {
                if line.count < 4096 { line.append(byte) }
                else { line.removeAll(keepingCapacity: true); dropping = true }
            }
        }
    }
    public mutating func finish() { if !dropping { inspectLine() }; line.removeAll() }
    private mutating func inspectLine() {
        guard let text = String(data: line, encoding: .utf8) else { return }
        if text.hasPrefix("OURA_PROGRESS "), let value = Int(text.dropFirst(14)), (0...100).contains(value) {
            progress = value; return
        }
        guard text.hasPrefix("ErrorCode "),
              let colon = text.firstIndex(of: ":"), let code = Int(text[text.index(text.startIndex, offsetBy: 10)..<colon]), code != 0 else { return }
        errorCode = code
    }
    public func failure(exitStatus: Int32) -> String {
        let code = errorCode.map { " Device error code: \($0)." } ?? " Tool exit status: \(exitStatus)."
        return "The device backup did not complete." + code + " Keep the device connected, approve its prompts, and check the Mac’s free disk space before retrying."
    }
}
