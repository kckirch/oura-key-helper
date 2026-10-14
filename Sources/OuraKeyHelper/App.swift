import SwiftUI
import AppKit
import KeyReader

@MainActor final class Helper: ObservableObject {
    @Published var connection: USBConnection = .checking
    @Published var consent = false
    @Published var busy = false
    @Published var backingUp = false
    @Published var status = ""
    @Published var keys: [RingKey] = []
    @Published var selected = ""
    @Published var reveal = false
    @Published var saved = ""
    @Published var backups: [URL] = []
    @Published var deleting: URL?
    @Published var showDelete = false
    @Published var showBackupConsent = false
    private var process: Process?
    private var cancelled = false
    let store: ManagedBackups
    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = ManagedBackups(root: support.appendingPathComponent("Oura Key Helper/Temporary Backups"))
        backups = store.list()
    }
    var chosen: RingKey? { keys.first { $0.id + $0.hex == selected } }
    func executable(_ name: String) -> URL? {
        ["/opt/homebrew/bin/", "/usr/local/bin/"].map { URL(fileURLWithPath: $0 + name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    func refreshConnection() async {
        guard let deviceTool = executable("idevice_id"), let infoTool = executable("ideviceinfo"), let installer = executable("ideviceinstaller"), executable("idevicebackup2") != nil else {
            connection = .missingTools; return
        }
        connection = await USBConnection.check(using: deviceTool, info: infoTool, installer: installer)
    }
    func existing() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the iPhone backup folder containing Manifest.db. This backup will never be deleted by the helper."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        if panel.runModal() == .OK, let folder = panel.url { extract(folder) }
    }
    func extract(_ folder: URL) {
        busy = true; keys = []; saved = ""; reveal = false; status = "Reading Oura’s ring key…"
        Task {
            do {
                let result = try await Task.detached { try KeyReader.read(folder) }.value
                keys = result; selected = result[0].id + result[0].hex
                status = "Found \(result.count == 1 ? "one ring key" : "\(result.count) ring keys")."
            } catch { status = error.localizedDescription }
            busy = false; backups = store.list()
        }
    }
    func createBackup() {
        guard let backupTool = executable("idevicebackup2"), let deviceTool = executable("idevice_id"), let infoTool = executable("ideviceinfo"), let installer = executable("ideviceinstaller") else {
            status = "Backup creation needs libimobiledevice. Install it with Homebrew: brew install libimobiledevice ideviceinstaller. You can still read an existing backup."
            return
        }
        guard connection.canBackUp else { status = connection.guidance; return }
        busy = true; backingUp = true; keys = []; saved = ""; reveal = false; cancelled = false
        status = "Checking the USB connection. Unlock your iPhone and approve Trust This Computer if prompted."
        Task {
            var temporary: URL?
            do {
                let listing = try await run(deviceTool, ["-l"], capture: true)
                let devices = listing.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
                guard devices.count == 1 else { throw ReaderError.message(devices.isEmpty ? "No USB iPhone was detected. Connect it, unlock it, approve Trust This Computer, and try again." : "More than one USB device is connected. Leave only the iPhone with official Oura connected, then try again.") }
                guard !cancelled else { throw ReaderError.message("Cancelled. No backup was started.") }
                let readiness = await USBConnection.check(using: deviceTool, info: infoTool, installer: installer)
                guard readiness.canBackUp else { connection = readiness; throw ReaderError.message(readiness.guidance) }
                guard !cancelled else { throw ReaderError.message("Cancelled. No backup was started.") }
                let folder = try store.create(); temporary = folder; backups = store.list()
                status = "Creating a temporary phone backup…"
                _ = try await run(backupTool, ["-u", devices[0], "backup", "--full", folder.path], capture: false, folder: folder)
                guard !cancelled else { throw ReaderError.message("Backup cancelled. The partial backup is listed below; you can delete it now.") }
                backingUp = false
                status = "Backup complete. Reading Oura’s ring key table…"
                let backup = folder.appendingPathComponent(devices[0])
                let result = try await Task.detached { try KeyReader.read(backup) }.value
                keys = result; selected = result[0].id + result[0].hex
                status = "Ring key found. Save it before deleting the backup."
            } catch {
                status = (cancelled ? "Backup cancelled." : error.localizedDescription) + (temporary != nil ? " Your temporary backup remains listed below; you can delete it now." : "")
            }
            busy = false; backingUp = false; process = nil; backups = store.list()
        }
    }
    private func run(_ executable: URL, _ arguments: [String], capture: Bool, folder: URL? = nil) async throws -> String {
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        // Backup output may contain unrelated filenames. Discard it instead of logging or showing it.
        let pipe = capture ? Pipe() : nil
        process.standardOutput = pipe?.fileHandleForWriting ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.process = process
        try process.run()
        pipe?.fileHandleForWriting.closeFile()
        let marker = folder?.appendingPathComponent(".backup-active-pid")
        if let marker { try? Data(String(process.processIdentifier).utf8).write(to: marker) }
        defer { if let marker { try? FileManager.default.removeItem(at: marker) } }
        let output = try await Task.detached { () -> String in
            let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ReaderError.message("The device backup did not complete. Check the cable, free disk space, and the iPhone’s trust/passcode prompt, then retry. No encryption settings were changed.") }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
        self.process = nil
        return output
    }
    func cancel() { cancelled = true; if process?.isRunning == true { process?.interrupt() }; status = "Stopping the backup. Its partial files will remain available to delete when the process stops." }
    func save() {
        guard let key = chosen else { return }
        let panel = NSSavePanel(); panel.message = "This file contains the ring’s existing authentication key. Keep it private."
        panel.nameFieldStringValue = "oura-ring-\(key.id.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(48)).key"
        if panel.runModal() == .OK, let destination = panel.url {
            do { try KeyReader.save(key, to: destination); saved = destination.path; status = "Key saved. It is independent of the backup, which you can now delete." }
            catch { status = "Could not save the key: " + error.localizedDescription }
        }
    }
    func copy() { if let key = chosen { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key.hex, forType: .string); status = "Key copied only because you requested it. Paste it into Open Oura’s ring-key field." } }
    func readManaged(_ folder: URL) {
        guard store.isOwned(folder) else { status = "This is not a helper-created backup."; return }
        let candidates = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Manifest.db").path)
        } ?? []
        guard candidates.count == 1 else { status = "This temporary backup is incomplete or contains no readable backup index. You can delete it or create a new one."; return }
        extract(candidates[0])
    }
    func viewSource() {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Source") { NSWorkspace.shared.open(url) }
    }
    func delete() {
        guard let folder = deleting else { return }
        do { try store.delete(folder); backups = store.list(); status = "Temporary backup deleted. Your phone and any saved key file are unchanged." }
        catch { status = error.localizedDescription }
        deleting = nil
    }
}

@MainActor final class QuitGuard: NSObject, NSApplicationDelegate {
    static weak var helper: Helper?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.helper?.backingUp == true {
            let alert = NSAlert(); alert.messageText = "Stop the backup before quitting"
            alert.informativeText = "Return to the helper and choose Cancel. When the backup stops, you can delete its temporary files or keep them for later."
            alert.addButton(withTitle: "Return to helper"); alert.runModal(); return .terminateCancel
        }
        return .terminateNow
    }
}
@main struct OuraKeyHelperApp: App {
    @NSApplicationDelegateAdaptor(QuitGuard.self) private var quitGuard
    @StateObject private var helper = Helper()
    var body: some Scene {
        WindowGroup {
            ContentView(helper: helper)
                .frame(minWidth: 620, idealWidth: 680, minHeight: 460, idealHeight: 580)
                .onAppear { QuitGuard.helper = helper; NSApplication.shared.activate(ignoringOtherApps: true) }
        }.windowResizability(.contentMinSize)
    }
}
struct ContentView: View {
    @ObservedObject var helper: Helper
    @State private var showPrivacy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "iphone.and.arrow.forward").font(.system(size: 34)).foregroundStyle(.blue).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recover your Oura ring key").font(.title2.weight(.semibold))
                        Text("Import your existing pairing into Open Oura.").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if helper.connection == .checking { ProgressView().controlSize(.small) }
                        Label(helper.connection.title, systemImage: helper.connection.deviceDetected ? "iphone" : "cable.connector")
                            .font(.headline)
                        Spacer()
                        Button("Check again") { Task { await helper.refreshConnection() } }
                            .disabled(helper.connection == .checking)
                    }
                    Text(helper.connection.guidance).font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("I own this ring or have the owner’s permission.", isOn: $helper.consent)
                    HStack(spacing: 12) {
                        Button("Read existing backup…") { helper.existing() }
                        Button("Create temporary backup…") { helper.showBackupConsent = true }.buttonStyle(.borderedProminent).disabled(!helper.connection.canBackUp)
                    }.disabled(!helper.consent || helper.busy)
                }
                if helper.busy || !helper.status.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        if helper.busy { ProgressView().controlSize(.small) }
                        Text(helper.status).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if helper.backingUp { Button("Cancel") { helper.cancel() } }
                    }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                if !helper.keys.isEmpty {
                    GroupBox("Recovered ring key") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Ring", selection: $helper.selected) {
                                ForEach(Array(helper.keys.enumerated()), id: \.offset) { _, key in Text(key.id).tag(key.id + key.hex) }
                            }
                            Toggle("Show key", isOn: $helper.reveal)
                            if helper.reveal, let key = helper.chosen { Text(key.hex).font(.body.monospaced()).textSelection(.enabled).privacySensitive() }
                            HStack { Button("Save key file…") { helper.save() }.buttonStyle(.borderedProminent); Button("Copy key") { helper.copy() } }
                            if !helper.saved.isEmpty { Text("Saved at \(helper.saved)").font(.caption).textSelection(.enabled) }
                            Text("Paste the key into Open Oura’s ring-key field.").font(.callout).foregroundStyle(.secondary)
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !helper.backups.isEmpty {
                    GroupBox("Temporary backups") {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(helper.backups, id: \.path) { folder in
                                VStack(alignment: .leading, spacing: 8) {
                                    if let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
                                        Text(created, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.subheadline.weight(.medium))
                                    }
                                    DisclosureGroup("File location") {
                                        Text(folder.path).font(.caption).textSelection(.enabled)
                                    }
                                    HStack {
                                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                                        Button("Read this backup") { helper.readManaged(folder) }.disabled(helper.busy)
                                        Spacer()
                                        Button("Delete this backup", role: .destructive) { helper.deleting = folder; helper.showDelete = true }.disabled(helper.busy)
                                    }
                                }
                            }
                            Text("Deleting a backup keeps your saved key.").font(.caption).foregroundStyle(.secondary)
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                DisclosureGroup("Privacy & data", isExpanded: $showPrivacy) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Extraction reads the backup index and Oura’s ring-key database. Connection checks read the device name, backup encryption flag, and official Oura’s install status.")
                        Text("Creating a phone backup can copy other app data. It stays on this Mac until you delete it. Existing Finder backups are never deleted.")
                        Text("No telemetry or uploads. Keys are revealed, copied, or saved only when you choose. Deletion is not a guaranteed forensic secure erase.")
                    }.font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                }
                HStack {
                    Text("Prototype · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("View source") { helper.viewSource() }
                }
            }.padding(28)
        }
        .task {
            while !Task.isCancelled {
                await helper.refreshConnection()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
            }
        }
        .alert("Create a temporary phone backup?", isPresented: $helper.showBackupConsent) {
            Button("Cancel", role: .cancel) {}
            Button("Create backup") { helper.createBackup() }
        } message: {
            Text("This can copy other phone data, not just Oura. It stays at \(helper.store.root.path) until you delete it. Your existing backups and encryption settings are unchanged.")
        }
        .alert("Delete this temporary backup?", isPresented: $helper.showDelete) {
            Button("Cancel", role: .cancel) { helper.deleting = nil }
            Button("Delete backup", role: .destructive) { helper.delete() }
        } message: { Text("Remove \(helper.deleting?.path ?? "this temporary backup")? Your iPhone and saved key file are unchanged.") }
    }
}
