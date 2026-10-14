# Read the key from a jailbroken device

An existing jailbreak lets you read Oura’s app data directly, without a device backup. You’ll need Filza or another way to locate the app’s data container, plus a terminal with SQLite installed. You can run the query on the device or connect from your Mac over SSH.

Use a device and ring you own or have permission to access. This guide doesn’t cover installing a jailbreak or setting up SSH.

## Find the database

1. Open the official Oura app, sign in, and sync the ring.
2. In Filza’s app/container browser, find **Oura** (`com.ouraring.oura`) and open its **data** container.
3. Locate `assa.sqlite`. On our iPad it was in `Documents/<ACCOUNT_UUID>/assa.sqlite`. The path can vary between app versions. The app container UUID and account UUID are different values.

Keep the ring paired. There’s no need to reset it or reinstall Oura.

## Read the key

Open a terminal on the device, or connect from your Mac:

```sh
ssh YOUR_USER@DEVICE_ADDRESS
```

Use your configured SSH account with permission to read Oura’s database. Replace the path below with the one you found in Filza. `sqlite3` must be installed on the device and available in your shell.

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

Use the **authentication_key** column. The `id` is a database entry ID, not the key. If multiple entries appear, check which ring/account they belong to.

Binary keys are printed as hex by this query. Text values may be hex or Base64. Open Oura expects a 16-byte key written as 32 hex characters.

## Convert Base64 to hex

Run this on a Mac with Python 3 installed, then paste the key value at the hidden prompt. It accepts either format and checks the decoded length.

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

Paste the result into Open Oura’s ring-key field. Keep the key out of screenshots, shared logs, issues, and online converters. These commands don’t save a database or key file, but their output remains in your terminal scrollback.

## Database journals

Query the original database with SQLite so it can read any accompanying write-ahead log (WAL). Copying only `assa.sqlite` while the app is writing to it can leave out recent changes. Don’t use `immutable=1` to skip the journal.

If you need a portable copy, use SQLite’s [online backup mechanism](https://www.sqlite.org/backup.html) to create a consistent snapshot. Delete the copy when finished. The helper’s backup-folder picker doesn’t accept a bare SQLite database.

If the query fails, unlock the device and check the path, read permissions, and SQLite installation. Don’t change permissions across app containers.

## References and testing

The database location and table are documented in [ringverse’s storage notes](https://github.com/ringverse/protocol/blob/1826a352611c7220708b555a15de13e28e24b33a/oura/storage.md). [NOOP’s existing-key recipe](https://github.com/ryanbr/noop/blob/3a0b74b2da11617cc4d3ce6452c8c5b990a7798f/docs/OURA_PROTOCOL.md#37-advanced-pairing-using-the-rings-genuine-app-issued-auth_key-optional-user-recipe) describes the Base64 key representation and backup alternative.

Direct extraction worked on our jailbroken iPad. The command examples were checked with synthetic databases, including binary, Base64, and hex keys and an update in the WAL. They haven’t been tested on every jailbreak or Oura version.
