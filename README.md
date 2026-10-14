# Oura Key Helper

A small, open-source Mac companion for recovering an **existing** Oura ring key from the official iPhone app's local backup. No jailbreak, ring reset, or cloud account access is required by the extraction process.

**Prototype:** twenty-three fixture tests pass, and the reader has also recovered a known working key from a privately captured official Oura database. However, this version has not yet been verified against a fresh backup from the current official Oura app. Oura can change its schema or exclude files from backups. Existing encrypted backups are detected and refused. For a new backup, an explicit password sheet can temporarily disable computer backup encryption, then restore and verify it using the same password. This flow has fixture coverage but has not been tested on a real phone. An Apple Silicon Mac build is supplied locally. It is not notarized.

## Use

1. Open Oura Key Helper and confirm that you own the ring/account or have the owner's permission.
2. The live connection status shows **No phone detected**, the connected device name, or a multiple-device/setup message. It refreshes every three seconds and has a **Check again** button. The official Oura installation is checked too. Backup creation stays disabled until one USB device is detected, official Oura is installed, and its backup is supported. Choose **Read existing backup** and select the folder containing `Manifest.db`, or connect your unlocked iPhone and choose **Create temporary backup**. Approve **Trust This Computer** on the iPhone when needed.
3. If encryption is enabled, enter the **current backup password in the helper**, then choose **Turn off & create backup**. This changes the phone’s computer-backup setting temporarily. Keep it connected and approve device prompts. The helper attempts restoration after success, failure, or cancellation; if interrupted or force-quit, a persistent **Restore encryption** action appears on reopening. The password is not saved, so re-enter the original password for recovery. Existing backup files retain their original encryption.

4. For backup creation, review the separate consent dialog. The backup may copy **other phone data**, not only Oura. Backup creation requires `libimobiledevice` installed with Homebrew:

   ```sh
   brew install libimobiledevice ideviceinstaller
   ```

5. When a key is found, select the ring, then explicitly save or copy its key. Paste the 32-character value into Open Oura's existing ring-key field. A saved `.key` file is plain hexadecimal text with owner-only file permissions.
6. Choose **Delete this backup** to permanently remove a helper-created backup. Deletion is confirmed separately. Your phone, existing Finder backups, and any separately saved key file are unchanged.

An initial full backup may take time and significant disk space. The application does not promise a small Oura-only backup. Use a data-capable USB cable and keep the phone unlocked when prompted. No ring-key validity claim is made until a compatible app successfully authenticates with it.

## Exactly what it accesses

- Existing backup: `Manifest.plist` for the encryption flag, and `Manifest.db` to locate the exact `AppDomain-com.ouraring.oura` app domain.
- Oura files: only `assa.sqlite` and its matching SQLite WAL/SHM files. They are copied into an owner-only temporary directory so SQLite can read them without altering the original backup. The directory is removed when extraction returns.
- Oura database query: `SELECT id, auth_key FROM ringconfiguration WHERE auth_key IS NOT NULL`. Other health tables and other apps' payloads are not queried.
- Keys: a 16-byte binary key, a Base64-encoded 16-byte key, or 32 hexadecimal characters are accepted. Missing or malformed keys produce an error; none are generated or guessed.
- Connection status: `idevice_id` reads the USB device list and, when one device is present, its name. `ideviceinfo` also checks the backup encryption flag; if that key is absent, a successfully read backup-domain dictionary confirms the default unencrypted state, matching `idevicebackup2`; unverified connections cannot start a backup; encrypted connections require explicit temporary-encryption consent. No app data is accessed by this check. `ideviceinstaller` queries only `com.ouraring.oura`, requesting only `CFBundleIdentifier`, to check whether official Oura is installed. Other apps are not enumerated, and app contents are not read by this check. Installation alone does not prove that Oura has synced the ring.
- New backup: the user-installed `idevice_id -l` detects USB devices, and `idevicebackup2 -u DEVICE backup --full FOLDER` creates the backup. These tools communicate with Apple's device services. They do not restore the phone. Only the explicit temporary-encryption flow sends `encryption off` and `encryption on`, verifying `WillEncrypt` afterward. Only one connected USB device is accepted.
- Temporary backups: stored beneath `~/Library/Application Support/Oura Key Helper/Temporary Backups/`. Ownership markers identify folders created by this helper. The folder list survives reopening the app. Incomplete and cancelled backups are retained until the user chooses deletion.
- Output: files are written only for the requested temporary backup, transient Oura database copy, ownership/process markers, a device-only encryption recovery reminder, and explicitly chosen key export. Keys are never logged or copied to the clipboard automatically.
- Password handling: the secure field is cleared on submission/dismissal. The password stays in process memory for restoration and is passed through the upstream `BACKUP_PASSWORD` child environment, never command arguments, logs, or disk. Other software running as the same user may inspect process memory/environment; this is not a hardened secret enclave. Swift strings are not guaranteed to be securely zeroed.
- No analytics, telemetry, cloud upload, or network requests are implemented by the helper. **View source** opens the source included in its app bundle locally.

Deleting files is not a guaranteed forensic secure erase, particularly on SSDs. A key already copied to the clipboard or saved elsewhere is independent of backup deletion. A force quit may leave a backup process or temporary files behind; deletion is refused while the recorded backup process remains active. Reopen the app to review retained helper-owned backups. Existing backups cannot be deleted through this interface.

## Review the source

- `Sources/KeyReader/KeyReader.swift`: exact file scope, read-only SQL, key decoding/export, and guarded backup deletion.
- `Sources/OuraKeyHelper/App.swift`: consent, USB backup command, status, cancellation, export, and deletion UI.
- `Tests/KeyReaderTests/KeyReaderTests.swift`: synthetic fixtures, original-file preservation, encrypted backup refusal, exclusion of other app domains, symlink/path controls, export permissions, and deletion guards.
- `build.sh`: local compilation, app packaging, bundled reviewable source, and ad-hoc signing.

Nothing proprietary from Oura is shipped: no official app, model weights, actual ring keys, phone backup, or health data. Tests use clearly synthetic key bytes.

## Build and test

With Apple's Swift toolchain and macOS SDK installed:

```sh
swift test
bash build.sh
open 'dist/Oura Key Helper.app'
```

The backup-creation dependency is separate, user-installed software. No Homebrew installation or dependency download is initiated by the helper itself. `libimobiledevice` and `ideviceinstaller` are not bundled in this project; its source and license are available upstream.

## Evidence and limits

- [ringverse's iOS backup schema](https://github.com/ringverse/protocol/blob/main/oura/storage.md) identifies `assa.sqlite`, the Oura app domain, and `ringconfiguration.auth_key`.
- [NOOP's documented existing-key backup route](https://github.com/ryanbr/noop/blob/main/docs/OURA_PROTOCOL.md#37-advanced-pairing-using-the-rings-genuine-app-issued-auth_key-optional-user-recipe).
- [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) supplies cross-platform backup tools without jailbreaking.

These are protocol/schema references, not a guarantee that every current iOS/Oura version is compatible. This is an independent interoperability tool, not an official Oura product.
