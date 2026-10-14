import SwiftUI
import AppKit
import KeyReader

@MainActor final class Helper: ObservableObject {
    @Published var connection: USBConnection = .checking
    @Published var consent = false
    @Published var busy = false
    @Published var backingUp = false
    @Published var status = ""
    @Published var transferProgress: Int?
    @Published var recoveryStarted: Date?
    @Published var lastTransferUpdate: Date?
    @Published var transferActivity: BackupActivity?
    @Published var lastActivity: Date?
    @Published var transferring = false
    @Published var keys: [RingKey] = []
    @Published var selected = ""
    @Published var reveal = false
    @Published var saved = ""
    @Published var backups: [URL] = []
    @Published var deleting: URL?
    @Published var showDelete = false
    @Published var copied = false
    @Published var showPassword = false
    @Published var password = ""
    @Published var restorePending = false
    @Published var restoring = false
    let encryption: BackupEncryption
    var filteredRuntime: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("USB/oura-usb"), FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let path = store.root.deletingLastPathComponent().appendingPathComponent("USB Runtime/bin/python3")
        return FileManager.default.isExecutableFile(atPath: path.path) ? path : nil
    }
    var filteredPrefix: [String] { filteredRuntime?.lastPathComponent == "oura-usb" ? [] : [filteredScript?.path ?? ""] }
    var filteredScript: URL? { Bundle.main.resourceURL?.appendingPathComponent("Source/Scripts/filtered_backup.py") }
    var canPrepareBackup: Bool {
        if restorePending { return false }
        if case .encrypted = connection { return true }
        return connection.canBackUp
    }
    private var process: Process?
    private var cancelled = false
    let store: ManagedBackups
    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        encryption = BackupEncryption(journal: support.appendingPathComponent("Oura Key Helper/encryption-recovery"))
        restorePending = encryption.pendingDevice != nil
        store = ManagedBackups(root: support.appendingPathComponent("Oura Key Helper/Temporary Backups"))
        for folder in store.list() { try? store.delete(folder) }
        backups = store.list()
        if !backups.isEmpty { status = "Some temporary data couldn’t be removed. Review it below." }
    }
    var chosen: RingKey? { keys.first { $0.id + $0.hex == selected } }
    func executable(_ name: String) -> URL? {
        ["/opt/homebrew/bin/", "/usr/local/bin/"].map { URL(fileURLWithPath: $0 + name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    func refreshConnection() async {
        guard !busy else { return }
        guard let tool = filteredRuntime else { connection = .missingTools; return }
        connection = await USBConnection.checkFiltered(using: tool, prefix: filteredPrefix)
    }
    func existing() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the iPhone backup folder containing Manifest.db. This backup will never be deleted by the helper."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        if panel.runModal() == .OK, let folder = panel.url { extract(folder) }
    }
    func extract(_ folder: URL, cleanup ownedFolder: URL? = nil) {
        busy = true; keys = []; saved = ""; reveal = false; copied = false; status = "Reading Oura’s ring key…"
        Task {
            do {
                let result = try await Task.detached { try KeyReader.read(folder) }.value
                keys = result; selected = result[0].id + result[0].hex
                status = "Found \(result.count == 1 ? "one ring key" : "\(result.count) ring keys")."
            } catch { status = error.localizedDescription }
            if let ownedFolder {
                do { try store.delete(ownedFolder); status += " Temporary data removed." }
                catch { status += " Cleanup needs attention. Remove the temporary data below." }
            }
            busy = false; backups = store.list()
        }
    }
    func encryptionCommand(_ arguments: [String], _ password: String?) async throws -> String {
        let name = arguments.contains("encryption") ? "idevicebackup2" : "ideviceinfo"
        guard let tool = executable(name) else { throw ReaderError.message("Install USB support before restoring encryption.") }
        return try await run(tool, arguments, capture: true, password: password, timeout: 45)
    }
    func restoreEncryption() {
        guard !busy else { return }
        let secret = password; password = ""; showPassword = false
        busy = true; backingUp = true; restoring = true
        Task {
            do {
                try await encryption.restore(password: secret, command: encryptionCommand)
                status = "Backup encryption is enabled again."
            } catch { status = "Encryption restoration needs attention. Reconnect the original phone and try again." }
            restorePending = encryption.pendingDevice != nil
            busy = false; backingUp = false; restoring = false
            await refreshConnection()
        }
    }
    func createBackup(temporaryPassword: String? = nil) {
        guard !busy else { return }
        guard let backupTool = filteredRuntime else {
            status = "Bundled USB support is missing. Reinstall the helper. Existing backups still work."
            return
        }
        guard canPrepareBackup else { status = connection.guidance; return }
        busy = true; backingUp = true; keys = []; saved = ""; reveal = false; copied = false; cancelled = false
        transferProgress = nil; lastTransferUpdate = nil; transferActivity = nil; lastActivity = nil; recoveryStarted = Date(); transferring = false
        status = "Checking the USB connection. Unlock your iPhone and approve Trust This Computer if prompted."
        Task {
            var temporary: URL?
            do {
                let listing = try await run(backupTool, filteredPrefix + ["--devices"], capture: true)
                let devices = listing.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
                guard devices.count == 1 else { throw ReaderError.message(devices.isEmpty ? "No USB iPhone was detected. Connect it, unlock it, approve Trust This Computer, and try again." : "More than one USB device is connected. Leave only the iPhone with official Oura connected, then try again.") }
                guard !cancelled else { throw ReaderError.message("Cancelled. No backup was started.") }
                let readiness = await USBConnection.checkFiltered(using: backupTool, prefix: filteredPrefix)
                if case .encrypted = readiness {
                    guard let secret = temporaryPassword, !secret.isEmpty else {
                        connection = readiness; throw ReaderError.message("Enter the existing backup password to decrypt Oura’s retained files.")
                    }
                } else if !readiness.canBackUp {
                    connection = readiness; throw ReaderError.message(readiness.guidance)
                }
                guard !cancelled else { throw ReaderError.message("Cancelled. No backup was started.") }
                let folder = try store.create(); temporary = folder; backups = store.list()
                status = "Connecting for recovery…"
                transferring = true
                _ = try await run(backupTool, filteredPrefix + [devices[0], folder.path], capture: false, folder: folder, password: temporaryPassword)
                guard !cancelled else { throw ReaderError.message("Cancelled.") }
                transferring = false
                status = "Reading Oura’s ring key…"
                let backup = folder.appendingPathComponent("Reader")
                let result = try await Task.detached { try KeyReader.read(backup) }.value
                keys = result; selected = result[0].id + result[0].hex
                status = "Ring key recovered."
            } catch {
                status = cancelled ? "Cancelled." : error.localizedDescription
            }
            transferring = false
            if let folder = temporary {
                do {
                    try store.delete(folder)
                    status += keys.isEmpty ? " Temporary data removed." : " Temporary data removed. Save or copy the key before closing."
                } catch { status += " Cleanup needs attention. Remove the temporary data below." }
            }
            busy = false; backingUp = false; process = nil; backups = store.list()
            await refreshConnection()
        }
    }
    private func run(_ executable: URL, _ arguments: [String], capture: Bool, folder: URL? = nil, password: String? = nil, timeout: Double? = nil) async throws -> String {
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let password {
            // Supported upstream interface: no password in argv, logs, or persistent storage.
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "BACKUP_PASSWORD_NEW")
            environment["BACKUP_PASSWORD"] = password
            process.environment = environment
        }
        // Preserve only numeric failure codes from backup output, never filenames or descriptions.
        let pipe = Pipe()
        process.standardOutput = pipe.fileHandleForWriting
        process.standardError = capture ? FileHandle.nullDevice : pipe.fileHandleForWriting
        self.process = process
        try process.run()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
        pipe.fileHandleForWriting.closeFile()
        let marker = folder?.appendingPathComponent(".backup-active-pid")
        if let marker { try? Data(String(process.processIdentifier).utf8).write(to: marker) }
        defer { if let marker { try? FileManager.default.removeItem(at: marker) } }
        let output = try await Task.detached { () async throws -> String in
            var data = Data()
            var diagnostic = BackupDiagnostic()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if capture { data.append(chunk) } else {
                    let previousProgress = diagnostic.progressUpdates
                    let previousActivity = diagnostic.activityUpdates
                    diagnostic.consume(chunk)
                    if folder != nil, diagnostic.progressUpdates != previousProgress || diagnostic.activityUpdates != previousActivity {
                        let percent = diagnostic.progress
                        let activity = diagnostic.activity
                        let hasProgress = diagnostic.progressUpdates != previousProgress
                        let hasActivity = diagnostic.activityUpdates != previousActivity
                        await MainActor.run {
                            if !self.cancelled {
                                if hasProgress { self.lastTransferUpdate = Date(); self.transferProgress = percent }
                                if hasActivity { self.lastActivity = Date(); self.transferActivity = activity }
                                self.status = "Reading device data…"
                            }
                        }
                    }
                }
            }
            diagnostic.finish()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ReaderError.message(diagnostic.failure(exitStatus: process.terminationStatus)) }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
        self.process = nil
        return output
    }
    func cancel() { guard !restoring else { return }; cancelled = true; if process?.isRunning == true { process?.interrupt() }; status = "Stopping and removing temporary data…" }
    func save() {
        guard let key = chosen else { return }
        let panel = NSSavePanel(); panel.message = "This file contains the ring’s existing authentication key. Keep it private."
        panel.nameFieldStringValue = "oura-ring-\(key.id.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(48)).key"
        if panel.runModal() == .OK, let destination = panel.url {
            do { try KeyReader.save(key, to: destination); saved = destination.path; status = "Key saved. You can close the helper." }
            catch { status = "Could not save the key: " + error.localizedDescription }
        }
    }
    func copy() { if let key = chosen { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key.hex, forType: .string); copied = true; status = "Key copied only because you requested it. Paste it into Open Oura’s ring-key field." } }
    func readManaged(_ folder: URL) {
        guard store.isOwned(folder) else { status = "This is not a helper-created backup."; return }
        let candidates = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Manifest.db").path)
        } ?? []
        guard candidates.count == 1 else { status = "This temporary backup is incomplete or contains no readable backup index. You can delete it or create a new one."; return }
        extract(candidates[0], cleanup: folder)
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
            let alert = NSAlert(); alert.messageText = "Finish the operation before quitting"
            alert.informativeText = "Keep your phone connected while encryption is being restored. During backup creation, you can choose Cancel and wait for restoration to finish."
            alert.addButton(withTitle: "Return to helper"); alert.runModal(); return .terminateCancel
        }
        if let helper = Self.helper, !helper.keys.isEmpty, helper.saved.isEmpty, !helper.copied {
            let alert = NSAlert(); alert.messageText = "Save or copy your key before closing"
            alert.informativeText = "Temporary data has been removed. The recovered key is only in memory."
            alert.addButton(withTitle: "Return to key"); alert.addButton(withTitle: "Discard key and quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
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
                            .disabled(helper.connection == .checking || helper.busy)
                    }
                    Text(helper.connection.guidance).font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("I own this ring or have the owner’s permission.", isOn: $helper.consent)
                    Text("Saves only Oura’s key database and backup metadata, then removes temporary data automatically.").font(.callout).foregroundStyle(.secondary)
                    Button("Recover ring key") {
                        if case .encrypted = helper.connection { helper.showPassword = true }
                        else { helper.createBackup() }
                    }.buttonStyle(.borderedProminent).disabled(!helper.canPrepareBackup || !helper.consent || helper.busy)
                    DisclosureGroup("Use an existing backup") {
                        Button("Choose backup…") { helper.existing() }.disabled(!helper.consent || helper.busy)
                    }
                }
                if helper.busy || !helper.status.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            if helper.busy && !helper.backingUp { ProgressView().controlSize(.small) }
                            Text(helper.status).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            if helper.backingUp && !helper.restoring { Button("Cancel") { helper.cancel() } }
                        }
                        if helper.backingUp, let started = helper.recoveryStarted {
                            Text("Allow about 10–15 minutes. Devices with more data may take longer.")
                                .font(.callout).foregroundStyle(.secondary)
                            if helper.transferring, let percent = helper.transferProgress {
                                ProgressView(value: Double(percent), total: 100).progressViewStyle(.linear)
                                    .accessibilityLabel("Device transfer").accessibilityValue("\(percent) percent")
                            } else {
                                ProgressView().progressViewStyle(.linear).accessibilityLabel("Recovery in progress")
                            }
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline) {
                                        if let activity = helper.transferActivity {
                                            Text("\(activity.files.formatted()) files processed · \(ByteCountFormatter.string(fromByteCount: activity.bytes, countStyle: .file)) received")
                                                .monospacedDigit()
                                        } else if let percent = helper.transferProgress {
                                            Text("\(percent)% transferred").monospacedDigit()
                                        }
                                        Spacer()
                                        Text("Elapsed")
                                        Text(started, style: .timer).monospacedDigit().fixedSize()
                                    }
                                    if helper.transferring {
                                        if let updated = helper.lastActivity {
                                            let age = max(0, Int(context.date.timeIntervalSince(updated)))
                                            if age >= 20 {
                                                Text("No new data for \(age) seconds. Check your device for a prompt.")
                                            } else {
                                                let freshness = age < 3 ? "Data is arriving." : "Last data received \(age) seconds ago."
                                                if helper.transferActivity?.indexReady == true {
                                                    Text("\(freshness) Checking Oura’s files for your key.")
                                                } else {
                                                    Text("\(freshness) Waiting for the backup index to identify Oura’s files.")
                                                }
                                            }
                                        } else {
                                            Text("Waiting for your device. Approve its backup prompt if shown.")
                                        }
                                    }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                if helper.restorePending {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Restore backup encryption", systemImage: "lock.trianglebadge.exclamationmark").font(.headline)
                        Text("Reconnect the original phone. Its encryption setting hasn’t been verified yet.").font(.callout).foregroundStyle(.secondary)
                        Button("Restore encryption…") { helper.showPassword = true }.disabled(helper.busy)
                    }
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
                if !helper.backups.isEmpty && !helper.backingUp {
                    GroupBox("Temporary data needs attention") {
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
                        Text("The first transfer can send other backup bytes; they are discarded without saving their contents. Backup metadata can describe other apps. Temporary data is removed after success, cancellation, or failure, and on reopening. Existing Finder backups are never deleted. This is not a full device backup.")
                        Text("No telemetry or uploads. Keys stay in memory until you explicitly copy or save them. Your device’s encryption setting stays unchanged. Deletion is not a guaranteed forensic secure erase.")
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
        .sheet(isPresented: $helper.showPassword, onDismiss: { helper.password = "" }) {
            VStack(alignment: .leading, spacing: 16) {
                Text(helper.restorePending ? "Restore backup encryption" : "Unlock your encrypted backup").font(.title2.weight(.semibold))
                Text(helper.restorePending
                     ? "Reconnect the original phone and enter its original backup password."
                     : "Enter your existing computer-backup password to decrypt Oura’s selected files locally. Your device’s encryption setting stays on.")
                SecureField("Current backup password", text: $helper.password)
                if !helper.restorePending {
                    Text("The password is not saved. Temporary backup data is removed when the operation ends.").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { helper.showPassword = false; helper.password = "" }
                    Button(helper.restorePending ? "Restore encryption" : "Recover ring key") {
                        if helper.restorePending { helper.restoreEncryption() }
                        else {
                            let secret = helper.password; helper.password = ""; helper.showPassword = false
                            helper.createBackup(temporaryPassword: secret)
                        }
                    }.buttonStyle(.borderedProminent).disabled(helper.password.isEmpty)
                }
            }.padding(24).frame(width: 470)
        }
        .alert("Delete this temporary backup?", isPresented: $helper.showDelete) {
            Button("Cancel", role: .cancel) { helper.deleting = nil }
            Button("Delete backup", role: .destructive) { helper.delete() }
        } message: { Text("Remove \(helper.deleting?.path ?? "this temporary backup")? Your iPhone and saved key file are unchanged.") }
    }
}
