# Oura Key Helper

A small open-source Mac companion to recover an existing Oura ring authentication key from the official iPhone/iPad app. No ring reset or jailbreak is required by the USB extraction flow.

Choose the [standard USB flow](#use) for an ordinary iPhone/iPad, or the [direct database route](#faster-route-for-an-already-jailbroken-device) if your own device is already jailbroken and you have access to its app data.

## Current status

**Prototype 0.2.9 (experimental speed path).** A live iPad test recovered the existing ring key through standard trusted USB backup services and automatically removed all helper-created backup data. No SSH or jailbreak interfaces were used. The test also confirmed that the received database was internally complete despite a stale size in its backup index; SQLite integrity validation and key reading both succeeded. Thirty-one Swift tests and fifteen Python adapter tests pass, including UUID account folders, WAL handling, stale-size snapshots, and rejection of corrupted databases even when their key table remains readable. Encrypted-backup decryption still needs hardware validation. Apple Silicon build, ad-hoc signed, not notarized.

## Use

1. Connect the unlocked device that already syncs your ring in official Oura. Approve Trust/backup authorization on the device when prompted.
2. Confirm ownership or permission, then choose **Recover ring key**.
3. If computer backups are encrypted, enter that device's existing backup password locally. It is used to decrypt selected files; **the device's encryption setting stays unchanged**. An unknown password cannot be bypassed.

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

## Sources, credit, and what we verified

This helper builds on published interoperability research and existing backup libraries. We did not discover the original Oura key-storage location or invent the backup-extraction method.

| Source | What it contributed |
| --- | --- |
| [NOOP’s existing-key recipe, §3.7](https://github.com/ryanbr/noop/blob/3a0b74b2da11617cc4d3ce6452c8c5b990a7798f/docs/OURA_PROTOCOL.md#37-advanced-pairing-using-the-rings-genuine-app-issued-auth_key-optional-user-recipe) | The starting point: recover the official app’s existing key from a trusted local iOS backup instead of resetting the ring. It describes Base64 key storage and credits ringverse for the schema. |
| [ringverse’s iOS storage notes](https://github.com/ringverse/protocol/blob/1826a352611c7220708b555a15de13e28e24b33a/oura/storage.md) | The Oura app domain, account-specific `assa.sqlite` location, and `ringconfiguration.id` / `auth_key` query. This is the underlying schema reference cited by NOOP. |
| [pymobiledevice3 11.30.0 backup implementation](https://github.com/doronz88/pymobiledevice3/blob/v11.30.0/pymobiledevice3/services/mobilebackup2.py) and [filtering recipes](https://github.com/doronz88/pymobiledevice3/blob/v11.30.0/docs/guides/cli-recipes.md) | The standard trusted USB backup transport and host-side filtering hooks. Filtering saves Mac storage; the first backup can still transmit unrelated bytes. |
| [pyiosbackup 0.2.4](https://github.com/matan1008/pyiosbackup/tree/v0.2.4) | Reading backup manifests and decrypting selected files using the device’s existing backup password. It is a dependency, not a password bypass. |
| [SQLite’s WAL format](https://www.sqlite.org/fileformat2.html#walformat), [read-only CLI](https://www.sqlite.org/cli.html), and [backup API](https://www.sqlite.org/backup.html) | Database/journal consistency, frame checksums, and reading a database without ignoring its journal. |
| [Open Oura](https://github.com/Th0rgal/open_oura) | The companion app/use case that motivated this helper. Key recovery does not extract or bundle Oura’s proprietary models. |

Our work here is the native Mac workflow, bounded retention adapter, file attribution, validation, progress/error presentation, and automatic cleanup. Our local tests confirmed the database/key formats accepted by the reader and recovered a matching existing key through both earlier jailbreak access and later standard USB backup tests. The UUID-folder filtering fix, stale manifest-size handling, and roughly 10–11 minute runs are **our device observations**, not claims established by the upstream research. They do not establish compatibility or timing for every Oura/iOS version. The experimental shortcut did not speed up the measured iPad run. See the code and synthetic tests for the exact checks.

These references were checked on October 14, 2026. Research links above are pinned where practical; implementation dependencies are locked in [`Scripts/requirements-usb.lock`](Scripts/requirements-usb.lock). Attribution is separate from licensing: the separate USB component and exact GPL/LGPL dependency sources are bundled; see [`THIRD-PARTY.md`](THIRD-PARTY.md). This is an independent interoperability prototype, not an official Oura product.

## Faster route for an already-jailbroken device

If you already have legitimate access to **your own Oura app container**, you can query its small key table directly instead of waiting for Apple’s backup stream. Once the correct database is located, this avoids the full-device transfer; it is not a measured speed guarantee. This is a manual alternative: the Mac helper does not install a jailbreak, connect over SSH, or accept a bare database through its backup-folder picker.

1. Open official Oura on the jailbroken device, sign in to the account that syncs the ring, and complete a sync. Do not reset the ring or remove/reinstall Oura for this procedure.
2. Use Filza’s app/container browser to locate **official Oura** (`com.ouraring.oura`) and its **data** container. Find `assa.sqlite` inside that container. On our device it was under `Documents/<ACCOUNT_UUID>/assa.sqlite`; other app versions may use another relative location. The app container UUID and account UUID are different identifiers. Do not substitute a path from another app.
3. In a terminal on the device, or after `ssh YOUR_USER@DEVICE_ADDRESS` from your Mac, use a configured account with permission to read that file. The device needs the SQLite command-line tool; its location depends on the jailbreak/package installation. Set the exact path you found and run this **SELECT-only** query:

```sh
oura_db='/var/mobile/Containers/Data/Application/CONTAINER_UUID/Documents/ACCOUNT_UUID/assa.sqlite'
sqlite3 -readonly "$oura_db" <<'SQL'
.headers on
.mode list
SELECT id,
       CASE WHEN typeof(auth_key) = 'blob'
            THEN lower(hex(auth_key))
            ELSE auth_key END AS authentication_key
FROM ringconfiguration
WHERE auth_key IS NOT NULL;
SQL
```

The command prints database IDs and keys locally. **The `id` column is not the key.** A binary key is rendered as hexadecimal by this query; a text key may already be hexadecimal or may be Base64. If there are multiple databases/rows, identify the correct ring/account instead of assuming the first one is current.

4. For Open Oura’s hexadecimal key field, normalize the value locally. On a Mac with Python 3 installed, this accepts a 32-character hex value or Base64, checks for exactly 16 decoded bytes, and prints 32 hex characters. Paste only the key value at its hidden prompt:

```sh
python3 - <<'PYTHON'
import base64
import getpass
import string

value = getpass.getpass('Paste authentication key (hidden): ').strip()
try:
    is_hex = len(value) == 32 and all(c in string.hexdigits for c in value)
    raw = bytes.fromhex(value) if is_hex else base64.b64decode(value, validate=True)
except ValueError:
    raise SystemExit('Not a valid hexadecimal or Base64 key.')
if len(raw) != 16:
    raise SystemExit('Expected a 16-byte authentication key.')
print(raw.hex())
PYTHON
```

5. Paste the hex key into Open Oura. Treat the output like a password: keep it out of screenshots, issues, shared logs, and online decoders. These commands do not create an exported database or key file, but output remains in your terminal scrollback and anything you explicitly copy/save.

**Keep SQLite’s journal handling intact.** Query the original database with SQLite so it can read any accompanying WAL; do not copy only `assa.sqlite` while Oura is writing to it or use `immutable=1` to ignore a WAL. If you need a portable database copy, use SQLite’s [online backup mechanism](https://www.sqlite.org/backup.html) to create a consistent snapshot, and remove that sensitive copy when finished. A future Oura schema change, protected data while locked, missing read permission, or a device without a usable SQLite CLI can prevent this manual route. Unlock the device and check the path/permissions; do not change permissions across app containers.

This direct-access route was used earlier on our own jailbroken iPad. The exact portable command examples above were checked with synthetic SQLite data, not rerun on every supported jailbreak. The consumer USB flow remains independent of jailbreak access.

## First-run speed limits

The host filter reduces storage, not what iOS transmits. No Oura-only device-side Backup request has been verified. A standard USB House Arrest container request for Oura was denied on the test iPad; no jailbreak/root interface was used. Existing unencrypted backups avoid a new transfer when they contain a still-valid key.

The local reader now selects Oura rows with parameterized SQLite before decoding archived file metadata, rather than iterating every app's entries. A fixture with 10,000 unrelated entries verifies only the selected Oura entry is decoded. This reduces local processing work; it does not establish a faster first USB transfer.

Oura's targeted installation metadata supplies its container UUID when available. Opaque account-folder candidates remain bounded in memory until attributed. Version 0.2.7 completed two fresh USB recoveries, including one measured at 631 seconds. Before-index recovery aims to avoid waiting for the final manifest, but only when its stricter database/journal checks succeed. See [SQLite's WAL format](https://www.sqlite.org/fileformat2.html#walformat) for frame validation and transient shared-memory behavior.

## Failure diagnostics

The backend reports only a fixed recovery stage, an allowlisted exception category, and a numeric device code when present. Raw exception text, paths, keys, and tracebacks are not shown or saved. The UI distinguishes transfer, backup-index/decryption, and missing/truncated Oura-payload failures. Legacy code 902 is a helper catch-all, not an Apple device error, and cannot establish the failed attempt's cause. Journal lengths must match manifest metadata. A main database size mismatch is accepted only after SQLite integrity and key validation; incomplete or corrupt snapshots fail. Cleanup still runs after failure.
