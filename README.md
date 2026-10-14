# Oura Key Helper

Recover an Oura ring’s existing authentication key from the official iPhone or iPad app. Built for importing an existing pairing into [Open Oura](https://github.com/Th0rgal/open_oura).

The Mac app uses Apple’s USB backup service. No jailbreak or ring reset is needed.

## Download

Get the app from [Releases](https://github.com/kckirch/oura-key-helper/releases).

Requires an Apple Silicon Mac running macOS 13 or later. USB support is bundled; you don’t need to install Python or Homebrew. Builds are currently ad-hoc signed and not notarized.

## Usage

1. Sync your ring in the official Oura app on the iPhone or iPad you’ll connect.
2. Connect that device to your Mac with a USB data cable. Unlock it and approve Trust if prompted.
3. Open Oura Key Helper, confirm you have permission to access the ring, and click **Recover ring key**. Approve the device’s backup prompt. If backups are encrypted, enter the existing backup password.
4. When recovery finishes, copy or save the key and paste it into Open Oura.

Allow about 10–15 minutes; devices with more data may take longer. Our iPad runs took about 10–11 minutes. The progress panel shows elapsed time and activity, with file counts under **Details**.

You can also select an existing, unencrypted Finder backup under **Use an existing backup**. The helper leaves that backup alone.

## How it works

The helper reads Oura’s `assa.sqlite` database from the backup stream and extracts `auth_key` from the `ringconfiguration` table. It keeps Oura’s database, any required journal files, and backup metadata temporarily. Other file contents are discarded as they arrive. Backup metadata can include information about other apps.

Temporary data is deleted after recovery, cancellation, or failure. Leftovers from an interrupted run are checked on the next launch; anything that can’t be removed is shown in the app. Recovered keys stay in memory until you copy or save them. Saved files and clipboard contents are yours to manage. There are no uploads or telemetry, and the device’s backup encryption setting is left unchanged.

## Limitations

- **Filtering saves disk space, not transfer time.** iOS can still send the full backup stream. Oura’s database arrived near the end in our tests. Experimental early stopping did not shorten that run.
- Recovery from an unencrypted device backup has been tested on an iPad. Encrypted-backup support has synthetic tests but still needs a hardware test. An existing backup password is required.
- Oura app updates can change the database layout or exclude it from backups.
- This is a key-recovery tool. Its temporary files are not a usable device backup. File deletion is ordinary deletion, not secure erasure.

## Already jailbroken?

You can skip the backup transfer and read Oura’s database directly using Filza and a read-only SQLite query over SSH. See [the jailbreak guide](docs/jailbreak.md) for the commands and Base64-to-hex conversion. This is a manual alternative; the Mac app doesn’t use SSH.

## Build from source

Requires macOS, Swift 5.9 or later with the macOS SDK, and Python 3.12. Run from the repository root. Quit the helper before rebuilding it.

```sh
OURA_HELPER_PYTHON=python3.12 bash Scripts/setup-usb.sh
runtime_python="$HOME/Library/Application Support/Oura Key Helper/USB Runtime/bin/python3"
"$runtime_python" -m pip install PyInstaller==6.16.0

swift test
"$runtime_python" Scripts/test_filtered_backup.py
bash Scripts/build-usb.sh
"$runtime_python" Scripts/runtime-sources.py
bash build.sh
open 'dist/Oura Key Helper.app'
```

The app is written in SwiftUI. `Sources/KeyReader` handles the local backup reader; `Scripts/filtered_backup.py` handles USB collection. Tests use synthetic data. The build includes source and dependency licenses in the app’s **View source** folder.

For bug reports, include the helper version, iOS/iPadOS version, and the error’s **Details**. Don’t attach authentication keys or device backups.

## Credits

The recovery method came from [NOOP’s existing-key recipe](https://github.com/ryanbr/noop/blob/3a0b74b2da11617cc4d3ce6452c8c5b990a7798f/docs/OURA_PROTOCOL.md#37-advanced-pairing-using-the-rings-genuine-app-issued-auth_key-optional-user-recipe), which cites [ringverse’s Oura storage notes](https://github.com/ringverse/protocol/blob/1826a352611c7220708b555a15de13e28e24b33a/oura/storage.md) for the database location and key table.

- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3/tree/v11.30.0) provides the USB backup transport. Its [filtering documentation](https://github.com/doronz88/pymobiledevice3/blob/v11.30.0/docs/guides/cli-recipes.md) explains the first-transfer limitation.
- [pyiosbackup](https://github.com/matan1008/pyiosbackup/tree/v0.2.4) reads backup manifests and decrypts selected files.
- SQLite’s [WAL format](https://www.sqlite.org/fileformat2.html#walformat), [CLI](https://www.sqlite.org/cli.html), and [backup API](https://www.sqlite.org/backup.html) document journal handling and consistent database reads.

This project adds the Mac interface, filtered collection, validation, and cleanup. It is independent of Oura and does not include Oura’s app or proprietary models.

## License

The native Swift app is [MIT licensed](LICENSE). The USB adapter is [GPL-3.0-or-later](LICENSE-GPL-3.0). See [THIRD-PARTY.md](THIRD-PARTY.md) for bundled dependencies and source distribution details.
