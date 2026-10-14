import Foundation

public enum USBConnection: Equatable {
    case checking, missingTools, none, unavailable
    case connected(String), encrypted(String), needsTrust(String)
    case multiple(Int)

    public var canBackUp: Bool { if case .connected = self { return true }; return false }
    public var title: String {
        switch self {
        case .checking: return "Checking USB connection…"
        case .missingTools: return "Connection check unavailable"
        case .none: return "No phone detected"
        case .unavailable: return "Couldn’t check the USB connection"
        case .connected(let name): return name.isEmpty ? "Device connected" : "Connected: " + name
        case .encrypted(let name): return "Connected: " + (name.isEmpty ? "iPhone" : name) + " · encrypted backup"
        case .needsTrust(let name): return (name.isEmpty ? "Phone detected" : "Detected: " + name) + " · unlock or approve Trust"
        case .multiple(let count): return "\(count) USB devices detected"
        }
    }
    public var guidance: String {
        switch self {
        case .missingTools: return "Install backup support with Homebrew: brew install libimobiledevice. You can still read an existing backup."
        case .multiple: return "Leave only the phone that already syncs your ring in official Oura connected."
        case .encrypted: return "Backup encryption is enabled. This prototype cannot read encrypted backups, so creating one is paused. No encryption settings have been changed. You can still choose an existing unencrypted backup."
        case .needsTrust: return "Unlock your phone. Select it in Finder and approve Trust This Computer if prompted, then check again. Backup creation waits until the connection can be verified."
        case .connected: return "Keep the phone unlocked and approve Trust This Computer if prompted. Use the device where official Oura already syncs your ring."
        default: return "Connect your iPhone with a data-capable USB cable, unlock it, and approve Trust This Computer if prompted."
        }
    }
    public static func check(using tool: URL?, info: URL? = nil) async -> USBConnection {
        guard let tool else { return .missingTools }
        return await Task.detached {
            func output(_ executable: URL, _ arguments: [String]) -> String? {
                let process = Process(); process.executableURL = executable; process.arguments = arguments
                let pipe = Pipe(); process.standardOutput = pipe.fileHandleForWriting; process.standardError = FileHandle.nullDevice
                do { try process.run(); pipe.fileHandleForWriting.closeFile() } catch { return nil }
                // A connection check must never stall the interface or target the backup process.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let listing = output(tool, ["-l"]) else { return .unavailable }
            let devices = listing.split(whereSeparator: \.isNewline).map(String.init)
            if devices.isEmpty { return .none }
            if devices.count > 1 { return .multiple(devices.count) }
            let name = output(tool, [devices[0]]) ?? ""
            if let info {
                guard let encryption = output(info, ["-u", devices[0], "-q", "com.apple.mobile.backup", "-k", "WillEncrypt"]) else { return .needsTrust(name) }
                if encryption == "true" { return .encrypted(name) }
                guard encryption == "false" else { return .needsTrust(name) }
            }
            return .connected(name)
        }.value
    }
}
