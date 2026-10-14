# Oura Key Helper

A small open-source Mac companion to recover an existing Oura ring authentication key from the official iPhone/iPad app. No ring reset or jailbreak is required by the USB extraction flow.

## Current status

**Prototype 0.2.0.** The native reader has recovered a known working key from an official Oura database. Twenty-seven Swift tests, four Python filtering/decryption-adapter tests, and a Python-to-Swift extraction fixture pass. A live iPad test verified low-storage transfer of thousands of files, but the diagnostic window ended before key recovery. Complete filtered collection and encrypted-backup decryption still require hardware validation. Apple Silicon build, ad-hoc signed, not notarized.

## Use

1. Connect the unlocked device that already syncs your ring in official Oura. Approve Trust/backup authorization on the device when prompted.
2. Confirm ownership or permission, then choose **Recover ring key**.
3. If computer backups are encrypted, enter that device's existing backup password locally. It is used to decrypt selected files; **the phone's encryption setting stays unchanged**. An unknown password cannot be bypassed.
4. The helper reads the key into memory and automatically removes its temporary backup data. Choose **Save key file** or **Copy key** before closing. The helper does not save a key automatically.

Existing Finder backups can also be selected under **Use an existing backup**. The helper never deletes those backups; the Swift existing-backup reader currently supports unencrypted backups only.

## Install

Download the Apple Silicon Mac app, unzip, and open it. The filtered USB component is included: normal users do not need Homebrew, Python, or a separate runtime installation. This prototype is ad-hoc signed, not notarized.

For development, `Scripts/setup-usb.sh` explicitly creates a local Python build environment using the locked dependency versions. It is not run by the distributed GUI. Build instructions are in `THIRD-PARTY.md`.

## What filtering actually does

The pinned `pymobiledevice3` backend receives Apple's backup stream through our bounded discard-sink adapter. iOS normally preflights space for a full backup, so the adapter advertises logical stream capacity while enforcing a 512 MiB saved-transfer budget and a 256 MiB real free-space reserve before every saved chunk. It refuses unfiltered operation. Decryption and reader copies need additional temporary space. This adapter is experimental and must be validated on devices. The device may still send **all backup bytes on the first run**. Filtering reduces files written to the Mac; it does not promise an Oura-only USB transfer or a faster first transfer.

- Retained app payloads: only `AppDomain-com.ouraring.oura/.../assa.sqlite`, `assa.sqlite-wal`, and `assa.sqlite-shm`. Other payload bytes are drained without saving their contents. The upstream protocol may create empty placeholder files during transfer; the helper removes its whole temporary folder afterward.
- Metadata: backup metadata such as `Manifest.db`, `Manifest.plist`, `Info.plist`, and `Status.plist` is retained temporarily. It can describe other apps/device information. This metadata is not an Oura-only file listing.
- Encrypted backups: `pyiosbackup` unlocks the manifest using the supplied password and decrypts only the selected Oura payloads. Manifest scratch files are directed inside the helper-owned temporary folder. No full extraction or restore is performed.
- Reader: a small Oura-only index feeds the Swift reader, which queries `SELECT id, auth_key FROM ringconfiguration WHERE auth_key IS NOT NULL`. It accepts a 16-byte binary/Base64 key or 32 hexadecimal characters. It does not generate or guess a key.
- Connection checks: USB identifiers/name, backup encryption state, and a targeted official-Oura installation query. Other app contents are not read by these checks.
- Passwords: secure field, cleared on submission/dismissal; not saved. Passed in the child process environment rather than arguments. Other software running as the same user may inspect process memory/environment. Swift strings are not guaranteed to be securely zeroed.
- No analytics, telemetry, cloud upload, or automatic clipboard copy is implemented. **View source** opens the bundled source locally.

The default backend does not change backup encryption. The older encryption-recovery mechanism remains available solely to finish an interrupted operation from an earlier helper version.

## Cleanup and key lifetime

Helper-created folders live under `~/Library/Application Support/Oura Key Helper/Temporary Backups/` with private permissions and ownership markers. They are removed after success, cancellation, or failure. On reopening, leftover owned folders are removed when their recorded process is no longer active. Cleanup failures remain visible and offer manual deletion. Existing backups are never eligible for this cleanup.

After successful extraction, keys remain **only in app memory** until explicitly saved or copied. Closing without either action requires a discard confirmation. A saved `.key` file has owner-only permissions. Clipboard contents and saved files are independent of temporary-data cleanup.

Deletion is ordinary file removal, not a guaranteed forensic secure erase. Force quit/system failure can leave files or a running backup process; reopening retries safe cleanup. A filtered collection is not a full device backup and must not be used for device restore.

## Build and verify

```sh
swift test
"$HOME/Library/Application Support/Oura Key Helper/USB Runtime/bin/python3" Scripts/test_filtered_backup.py
bash Scripts/build-usb.sh
"$HOME/Library/Application Support/Oura Key Helper/USB Runtime/bin/python3" Scripts/runtime-sources.py
bash build.sh
open 'dist/Oura Key Helper.app'
```

Quit the app before rebuilding. Source includes no actual ring keys, phone databases, official Oura app, or proprietary models. Tests use synthetic data.

## Sources and dependency scope

- [NOOP's existing-key recipe](https://github.com/ryanbr/noop/blob/main/docs/OURA_PROTOCOL.md#37-advanced-pairing-using-the-rings-genuine-app-issued-auth_key-optional-user-recipe).
- [ringverse's Oura database schema](https://github.com/ringverse/protocol/blob/main/oura/storage.md).
- [pymobiledevice3 filtering documentation](https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/cli-recipes.md) and [backup implementation](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/mobilebackup2.py).

The separate USB component and exact GPL/LGPL dependency sources are bundled. See `THIRD-PARTY.md` for licenses and rebuild instructions. This is an independent interoperability prototype, not an official Oura product. Oura/iOS changes can prevent extraction.
