# Oura Key Helper

A small open-source Mac companion to recover an existing Oura ring authentication key from the official iPhone/iPad app. No ring reset or jailbreak is required by the USB extraction flow.

## Current status

**Prototype 0.2.9 (experimental speed path).** A live iPad test recovered the existing ring key through standard trusted USB backup services and automatically removed all helper-created backup data. No SSH or jailbreak interfaces were used. The test also confirmed that the received database was internally complete despite a stale size in its backup index; SQLite integrity validation and key reading both succeeded. Thirty-one Swift tests and fifteen Python adapter tests pass, including UUID account folders, WAL handling, stale-size snapshots, and rejection of corrupted databases even when their key table remains readable. Encrypted-backup decryption still needs hardware validation. Apple Silicon build, ad-hoc signed, not notarized.

## Use

1. Connect the unlocked device that already syncs your ring in official Oura. Approve Trust/backup authorization on the device when prompted.
2. Confirm ownership or permission, then choose **Recover ring key**.
3. If computer backups are encrypted, enter that device's existing backup password locally. It is used to decrypt selected files; **the phone's encryption setting stays unchanged**. An unknown password cannot be bypassed.
During recovery, concise copy suggests allowing about 10–15 minutes and notes that devices with more data may take longer. This is rough planning guidance, not a calculated ETA or a maximum. A native progress bar shows the device percentage when available. Elapsed time and live activity stay visible; expandable Details contains actual files processed, bytes received, index state, and last activity. Technical failure codes are separated from actionable error text. Activity messages contain only counters and an index-ready flag, never file paths or keys. After 20 seconds without new data, the helper says how long it has been quiet and suggests checking device prompts. Received bytes measure USB traffic, not saved disk usage; elapsed time alone does not prove activity.

4. The helper reads the key into memory and automatically removes its temporary backup data. Choose **Copy key** or **Save key file** before closing. A single result has no ring selector; the database ring ID is separately labeled under Details. The helper does not save a key automatically.

Existing Finder backups can also be selected under **Use an existing backup**. The helper never deletes those backups; the Swift existing-backup reader currently supports unencrypted backups only.

## Install

Download the Apple Silicon Mac app, unzip, and open it. The filtered USB component is included: normal users do not need Homebrew, Python, or a separate runtime installation. This prototype is ad-hoc signed, not notarized.

For development, `Scripts/setup-usb.sh` explicitly creates a local Python build environment using the locked dependency versions. It is not run by the distributed GUI. Build instructions are in `THIRD-PARTY.md`.

## What filtering actually does

The pinned `pymobiledevice3` backend receives Apple's backup stream through our bounded discard-sink adapter. iOS normally preflights space for a full backup, so the adapter advertises logical stream capacity while enforcing a 512 MiB saved-transfer budget and a 256 MiB real free-space reserve before every saved chunk. It refuses unfiltered operation. Decryption and reader copies need additional temporary space. This adapter is experimental and must be validated on devices. The device may still send **all backup bytes on the first run**. Filtering reduces files written to the Mac; it does not promise an Oura-only USB transfer or a faster first transfer.

- Retained app payloads: only `AppDomain-com.ouraring.oura/.../assa.sqlite`, `assa.sqlite-wal`, and `assa.sqlite-shm`. Ambiguous staging paths named `assa.sqlite` or its sidecars are buffered in memory (64 MiB total maximum) until the manifest identifies their app. Oura bytes are saved only after attribution by the manifest or an exact domain/path file-ID hash match; other candidates are released. Other payload bytes are drained without saving their contents. The upstream protocol may create empty placeholder files during transfer; the helper removes its whole temporary folder afterward.
- Before-index recovery (unencrypted backups): match the arriving filename to `SHA1("AppDomain-com.ouraring.oura-" + relativePath)`. A completed database and a completed, nonempty WAL for that same path are required. Validate WAL page size, salts, cumulative checksums, and its final commit, then run SQLite integrity and key checks on a private copy. SQLite rebuilds its transient shared-memory index. Missing/empty/corrupt journals, invalid keys, and encrypted backups keep the existing collection path. This can return the first recoverable database before discovering other account folders; it does not enumerate every historical account. Sanitized timing events report only fixed event names and elapsed seconds. A live fresh-run test matched Oura’s database at 627.9 seconds after collector initialization; total run time was 659.7 seconds including preparation. The final index listed only the database, with no WAL. Normal recovery succeeded and temporary data was removed, but this run did not take the shortcut or demonstrate a speed improvement.
- Index-based early stopping: after the complete manifest and all selected database files/sidecars arrive, the helper tries a private Oura-only reader copy. It ends the USB session early only when a valid existing ring key can be read. Missing metadata, an incomplete journal, or an invalid key keeps normal collection running. If iOS sends the manifest late, this may save little time. It does not claim to complete a reusable device backup.
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

## First-run speed limits

The host filter reduces storage, not what iOS transmits. No Oura-only device-side Backup request has been verified. A standard USB House Arrest container request for Oura was denied on the test iPad; no jailbreak/root interface was used. Existing unencrypted backups avoid a new transfer when they contain a still-valid key.

The local reader now selects Oura rows with parameterized SQLite before decoding archived file metadata, rather than iterating every app's entries. A fixture with 10,000 unrelated entries verifies only the selected Oura entry is decoded. This reduces local processing work; it does not establish a faster first USB transfer.

Oura's targeted installation metadata supplies its container UUID when available. Opaque account-folder candidates remain bounded in memory until attributed. Version 0.2.7 completed two fresh USB recoveries, including one measured at 631 seconds. Before-index recovery aims to avoid waiting for the final manifest, but only when its stricter database/journal checks succeed. See [SQLite's WAL format](https://www.sqlite.org/fileformat2.html#walformat) for frame validation and transient shared-memory behavior.

## Failure diagnostics

The backend reports only a fixed recovery stage, an allowlisted exception category, and a numeric device code when present. Raw exception text, paths, keys, and tracebacks are not shown or saved. The UI distinguishes transfer, backup-index/decryption, and missing/truncated Oura-payload failures. Legacy code 902 is a helper catch-all, not an Apple device error, and cannot establish the failed attempt's cause. Journal lengths must match manifest metadata. A main database size mismatch is accepted only after SQLite integrity and key validation; incomplete or corrupt snapshots fail. Cleanup still runs after failure.
