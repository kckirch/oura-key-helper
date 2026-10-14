import Foundation

public struct BackupActivity: Decodable, Equatable {
    public let files: Int
    public let bytes: Int64
    public let indexReady: Bool
}

public struct BackupRecoveryFailure: LocalizedError {
    public let message: String
    public let details: String
    public init(message: String, details: String) { self.message = message; self.details = details }
    public var errorDescription: String? { message }
}

/// Drain tool output without retaining unrelated filenames or device data.
public struct BackupDiagnostic {
    private var line = Data()
    private var dropping = false
    public private(set) var errorCode: Int?
    public private(set) var progress: Int?
    public private(set) var progressUpdates = 0
    public private(set) var activity: BackupActivity?
    public private(set) var activityUpdates = 0
    private var reportedFailure: (stage: String, kind: String, code: Int?)?
    private var payloadDetail = ""
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
        if text.hasPrefix("OURA_ACTIVITY "),
           let value = try? JSONDecoder().decode(BackupActivity.self, from: Data(text.dropFirst(14).utf8)),
           (0...1_000_000_000).contains(value.files), (0...(1 << 60)).contains(value.bytes),
           value.files >= (activity?.files ?? 0), value.bytes >= (activity?.bytes ?? 0) {
            activity = value; activityUpdates += 1; return
        }
        if text.hasPrefix("OURA_FAILURE "),
           let data = String(text.dropFirst(13)).data(using: .utf8),
           let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let stage = value["stage"] as? String, let kind = value["kind"] as? String,
           ["connect", "prepare", "transfer", "decrypt", "index", "payload", "unknown"].contains(stage),
           ["FileNotFoundError", "PermissionError", "OSError", "ValueError", "DatabaseError", "OperationalError", "BackupPasswordIsRequired", "InvalidPassword", "CorruptedEntryError", "MissingEntryError", "NotEnoughDiskSpaceError", "ConnectionTerminatedError", "ConnectionResetError", "ConnectionAbortedError", "TimeoutError", "PyMobileDevice3Exception", "OuraPayloadMissing", "OuraDatabaseMissing", "StorageLimitError", "UnknownError"].contains(kind) {
            reportedFailure = (stage, kind, value["deviceCode"] as? Int)
            payloadDetail = ""
            if kind == "OuraPayloadMissing", let payload = value["payload"] as? String,
               ["database", "journal", "shared-memory"].contains(payload),
               let state = value["state"] as? String, ["absent", "size-mismatch"].contains(state) {
                payloadDetail = "; \(payload)/\(state)"
            }
            return
        }
        if text.hasPrefix("OURA_PROGRESS "), let value = Int(text.dropFirst(14)), (0...100).contains(value) {
            progress = value; progressUpdates += 1; return
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
            case "StorageLimitError", "NotEnoughDiskSpaceError": message = "Recovery stopped at a storage limit. Check your Mac’s free space and use the latest helper before trying again."
            default:
                switch failure.stage {
                case "connect", "prepare": message = "Couldn’t prepare recovery from the device. Keep it connected and unlocked."
                case "transfer": message = "Couldn’t finish reading your device. Keep it connected, check for a backup prompt, and try again."
                case "decrypt": message = "Couldn’t unlock or open the backup index. For encrypted backups, verify the existing backup password."
                case "index": message = "Couldn’t read the backup’s file list. Check that you’re using the latest helper before trying again."
                case "payload": message = "Couldn’t read Oura’s database. Check your backup password if encryption is enabled, and use the latest helper."
                default: message = "Couldn’t recover a key. Keep your device connected and unlocked, then check the details below."
                }
            }
            return message
        }
        if errorCode == 902 { return "Recovery couldn’t finish. Update the helper before trying again." }
        if errorCode == 901 { return "Recovery cancelled." }
        return "Couldn’t finish reading your device. Keep it connected, approve any backup prompt, and check your Mac’s free space before trying again."
    }
    public func details(exitStatus: Int32) -> String {
        if let failure = reportedFailure {
            let code = failure.code.map { "; device code \($0)" } ?? ""
            return "\(failure.stage)/\(failure.kind)\(payloadDetail)\(code)"
        }
        if let errorCode { return "\(errorCode == 902 ? "Legacy collector code" : "Device error code"): \(errorCode)" }
        return "Tool exit status: \(exitStatus)"
    }
}
