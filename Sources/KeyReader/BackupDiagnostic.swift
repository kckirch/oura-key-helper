import Foundation

/// Drain tool output without retaining unrelated filenames or device data.
public struct BackupDiagnostic {
    private var line = Data()
    private var dropping = false
    public private(set) var errorCode: Int?
    public private(set) var progress: Int?
    private var reportedFailure: (stage: String, kind: String, code: Int?)?
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
        if text.hasPrefix("OURA_FAILURE "),
           let data = String(text.dropFirst(13)).data(using: .utf8),
           let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let stage = value["stage"] as? String, let kind = value["kind"] as? String,
           ["connect", "prepare", "transfer", "decrypt", "index", "payload", "unknown"].contains(stage),
           ["FileNotFoundError", "PermissionError", "OSError", "ValueError", "DatabaseError", "OperationalError", "BackupPasswordIsRequired", "InvalidPassword", "CorruptedEntryError", "MissingEntryError", "NotEnoughDiskSpaceError", "ConnectionTerminatedError", "ConnectionResetError", "ConnectionAbortedError", "TimeoutError", "PyMobileDevice3Exception", "OuraPayloadMissing", "OuraDatabaseMissing", "StorageLimitError", "UnknownError"].contains(kind) {
            reportedFailure = (stage, kind, value["deviceCode"] as? Int)
            return
        }
        if text.hasPrefix("OURA_PROGRESS "), let value = Int(text.dropFirst(14)), (0...100).contains(value) {
            progress = value; return
        }
        guard text.hasPrefix("ErrorCode "),
              let colon = text.firstIndex(of: ":"), let code = Int(text[text.index(text.startIndex, offsetBy: 10)..<colon]), code != 0 else { return }
        errorCode = code
    }
    public func failure(exitStatus: Int32) -> String {
        if let failure = reportedFailure {
            let message: String
            switch failure.kind {
            case "OuraPayloadMissing": message = "Oura’s database was listed in the backup but wasn’t received completely. This is a collection failure; don’t repeat the full transfer yet."
            case "OuraDatabaseMissing": message = "Oura’s ring database wasn’t listed in the backup. Confirm official Oura is signed in and has synced; the app may exclude this file from backups."
            case "StorageLimitError", "NotEnoughDiskSpaceError": message = "Recovery stopped at a storage limit. No key was recovered."
            default:
                switch failure.stage {
                case "connect", "prepare": message = "Couldn’t prepare recovery from the device. Keep it connected and unlocked."
                case "transfer": message = "The device transfer failed before key extraction."
                case "decrypt": message = "Couldn’t unlock or open the backup index. For encrypted backups, verify the existing backup password."
                case "index": message = "Couldn’t read Oura’s backup index entries."
                case "payload": message = "Couldn’t read or decrypt Oura’s retained database."
                default: message = "Recovery failed before a key could be extracted."
                }
            }
            let code = failure.code.map { "; device code \($0)" } ?? ""
            return message + " [\(failure.stage)/\(failure.kind)\(code)]"
        }
        if errorCode == 902 { return "Recovery failed in the older collector, which did not report its cause. Update the helper before retrying." }
        if errorCode == 901 { return "Recovery cancelled." }
        let code = errorCode.map { " Device error code: \($0)." } ?? " Tool exit status: \(exitStatus)."
        return "The device backup did not complete." + code + " Keep the device connected, approve its prompts, and check the Mac’s free disk space before retrying."
    }
}
