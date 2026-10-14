import Foundation

public enum USBConnection: Equatable {
    case checking, missingTools, none, unavailable
    case connected(String), encrypted(String), needsTrust(String), missingOura(String), ouraCheckUnavailable(String)
    case multiple(Int)

    public var canBackUp: Bool { if case .connected = self { return true }; return false }
    public var deviceDetected: Bool {
        switch self {
        case .connected, .encrypted, .needsTrust, .missingOura, .ouraCheckUnavailable: return true
        default: return false
        }
    }
    public var title: String {
        switch self {
        case .checking: return "Checking USB connection…"
        case .missingTools: return "Connection check unavailable"
        case .none: return "No phone detected"
        case .unavailable: return "Couldn’t check the USB connection"
        case .connected(let name): return "Connected: " + (name.isEmpty ? "iPhone" : name) + " · Oura installed"
        case .encrypted(let name): return "Connected: " + (name.isEmpty ? "iPhone" : name) + " · encrypted backup"
        case .needsTrust(let name): return (name.isEmpty ? "Phone detected" : "Detected: " + name) + " · unlock or approve Trust"
        case .missingOura(let name): return "Connected: " + (name.isEmpty ? "iPhone" : name) + " · Oura not installed"
        case .ouraCheckUnavailable(let name): return "Connected: " + (name.isEmpty ? "iPhone" : name) + " · Oura check unavailable"
        case .multiple(let count): return "\(count) USB devices detected"
        }
    }
    public var guidance: String {
        switch self {
        case .missingTools: return "Install USB support: brew install libimobiledevice ideviceinstaller. Existing backups still work."
        case .multiple: return "Connect only the device that syncs your ring in official Oura."
        case .encrypted: return "Create a temporary backup using your current backup password. Encryption will be restored afterward."
        case .needsTrust: return "Unlock your phone and approve Trust This Computer in Finder, then check again."
        case .missingOura: return "Install official Oura and sync your ring, then check again."
        case .ouraCheckUnavailable: return "Couldn’t verify official Oura. Unlock your phone and check again."
        case .connected: return "Sync your ring in official Oura before starting."
        default: return "Connect your unlocked iPhone with a USB data cable."
        }
    }
    public static func check(using tool: URL?, info: URL?, installer: URL?) async -> USBConnection {
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
            guard let info, let installer else { return .missingTools }
            guard let encryption = output(info, ["-u", devices[0], "-q", "com.apple.mobile.backup", "-k", "WillEncrypt"]),
                  ["true", "false"].contains(encryption) else { return .needsTrust(name) }
            // Request only official Oura's identifier, not a list of installed apps.
            guard let result = output(installer, ["-u", devices[0], "list", "--bundle-identifier", "com.ouraring.oura", "--attribute", "CFBundleIdentifier", "--xml"]),
                  let installed = ouraInstalled(in: result) else { return .ouraCheckUnavailable(name) }
            guard installed else { return .missingOura(name) }
            if encryption == "true" { return .encrypted(name) }
            return .connected(name)
        }.value
    }
    public static func ouraInstalled(in response: String) -> Bool? {
        guard let object = try? PropertyListSerialization.propertyList(from: Data(response.utf8), format: nil) else { return nil }
        let identifier = "com.ouraring.oura"
        if let records = object as? [[String: Any]] {
            if records.isEmpty { return false }
            if records.contains(where: { $0["CFBundleIdentifier"] as? String == identifier }) { return true }
        } else if let record = object as? [String: Any] {
            if record.isEmpty { return false }
            if record["CFBundleIdentifier"] as? String == identifier { return true }
            if let app = record[identifier] as? [String: Any], app["CFBundleIdentifier"] as? String == identifier { return true }
        }
        return nil
    }

}
