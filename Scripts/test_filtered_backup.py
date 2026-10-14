import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location('filtered', Path(__file__).with_name('filtered_backup.py'))
filtered = importlib.util.module_from_spec(spec)
spec.loader.exec_module(filtered)

class FilterTests(unittest.TestCase):
    def test_only_exact_oura_database_and_sidecars_are_retained(self):
        from pymobiledevice3.services.mobilebackup2 import Mobilebackup2Service
        from pymobiledevice3.services.mobilebackup2 import BackupFile
        for name in filtered.NAMES:
            self.assertTrue(filtered.keep_file(BackupFile(device_name=f'{filtered.DOMAIN}/UUID/{name}')))
            self.assertTrue(filtered.keep_file(BackupFile(device_name=f'{filtered.DOMAIN}-UUID/{name}')))
        for path in ['AppDomain-other/UUID/assa.sqlite', 'AppDomain-com.ouraring.oura.fake/UUID/assa.sqlite', f'{filtered.DOMAIN}/UUID/health.sqlite', f'{filtered.DOMAIN}/../assa.sqlite', 'UUID/assa.sqlite', f'{filtered.DOMAIN}/UUID/assa.sqlite/photo']:
            self.assertFalse(filtered.keep_file(BackupFile(device_name=path)))
        self.assertFalse(filtered.keep_file(BackupFile(device_name=None)))
        self.assertTrue(Mobilebackup2Service.should_preserve_backup_file('device/Manifest.db', '', filtered.keep_file))
        self.assertFalse(Mobilebackup2Service.should_preserve_backup_file('device/abc', 'AppDomain-other/photo.jpg', filtered.keep_file))

    def test_staged_paths_require_the_exact_oura_container(self):
        from pymobiledevice3.services.mobilebackup2 import BackupFile
        owner = '11111111-2222-3333-4444-555555555555'
        other = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        callback = filtered.OuraFilter('/private/var/mobile/Containers/Data/Application/' + owner)
        for name in filtered.NAMES:
            self.assertTrue(callback(BackupFile(device_name=f'/.ba/mobile/Containers/Data/Application/{owner}/ACCOUNT/{name}')))
            self.assertFalse(callback(BackupFile(device_name=f'/.ba/mobile/Containers/Data/Application/{other}/ACCOUNT/{name}')))
        self.assertFalse(callback(BackupFile(device_name=f'/.b/6/ACCOUNT/assa.sqlite')))
        self.assertFalse(callback(BackupFile(device_name=f'AppDomain-other/{owner}/assa.sqlite')))
        self.assertFalse(callback(BackupFile(device_name=f'/.b/{owner}/../assa.sqlite')))
        self.assertFalse(filtered.OuraFilter('invalid')(BackupFile(device_name='/.b/6/assa.sqlite')))

    def test_readable_copy_never_reads_other_payloads(self):
        from unittest.mock import patch
        import sqlite3
        import plistlib
        selected = 'a' * 40
        decoded = []
        entry = SimpleNamespace(domain=filtered.DOMAIN, relative_path='UUID/assa.sqlite', size=len(b'fixture-oura-db'), read_bytes=lambda: b'fixture-oura-db')
        def read_entry(file_id):
            decoded.append(file_id)
            self.assertEqual(file_id, selected)
            return entry
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'Reader'
            manifest = Path(temp) / 'Manifest.db'
            with sqlite3.connect(manifest) as db:
                db.execute('CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT)')
                db.executemany('INSERT INTO Files VALUES (?, ?, ?)', [('b' * 40, 'AppDomain-other', f'data/{i}.db') for i in range(10000)])
                db.execute('INSERT INTO Files VALUES (?, ?, ?)', (selected, filtered.DOMAIN, entry.relative_path))
                db.execute('INSERT INTO Files VALUES (?, ?, ?)', ('c' * 40, filtered.DOMAIN, 'UUID/health.sqlite'))
            fake = SimpleNamespace(_manifest_db=SimpleNamespace(path=manifest), get_entry_by_id=read_entry, iter_entries=lambda: self.fail('Full index decoded'))
            with patch('pyiosbackup.Backup.from_path', return_value=fake) as opened:
                filtered.make_readable(Path(temp), output, 'fixture-password')
            opened.assert_called_once_with(Path(temp), password='fixture-password')
            self.assertEqual(decoded, [selected])
            with sqlite3.connect(output / 'Manifest.db') as db:
                rows = db.execute('SELECT fileID, domain, relativePath FROM Files').fetchall()
            self.assertEqual(len(rows), 1)
            self.assertEqual((output / rows[0][0]).read_bytes(), b'fixture-oura-db')
            self.assertFalse(plistlib.loads((output / 'Manifest.plist').read_bytes())['IsEncrypted'])


class StorageTests(unittest.TestCase):
    def test_budget_stops_before_writing_and_never_counts_discarded_payloads(self):
        import io
        from unittest.mock import patch
        target = io.BytesIO()
        budget = filtered.StorageBudget(Path('/unused'), limit=8, reserve=2)
        with patch.object(filtered.shutil, 'disk_usage', return_value=SimpleNamespace(free=100)):
            writer = filtered.BudgetWriter(target, budget)
            writer.write(b'12345678')
            with self.assertRaises(OSError): writer.write(b'9')
        self.assertEqual(target.getvalue(), b'12345678')
        self.assertEqual(budget.written, 8)
        with patch.object(filtered.shutil, 'disk_usage', return_value=SimpleNamespace(free=1)):
            with self.assertRaises(OSError): budget.check(0)

    def test_service_rejects_unfiltered_collection_before_connecting(self):
        import asyncio
        async def run():
            service = filtered.filtered_service_type()
            with self.assertRaises(ValueError):
                async with service.device_link(object(), Path('/unused'), filter_callback=None): pass
        asyncio.run(run())

class DiagnosticTests(unittest.TestCase):
    def test_size_mismatch_requires_integrity_and_an_existing_key(self):
        import sqlite3
        from unittest.mock import patch
        for corrupt in [False, True]:
            with self.subTest(corrupt=corrupt), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source = root / 'fixture.sqlite'
                with sqlite3.connect(source) as db:
                    db.execute('CREATE TABLE ringconfiguration (id TEXT, auth_key BLOB)')
                    db.execute('INSERT INTO ringconfiguration VALUES (?, ?)', ('fixture-ring', b'0123456789abcdef'))
                    db.execute('CREATE TABLE measurements (payload BLOB)')
                    db.execute('INSERT INTO measurements VALUES (zeroblob(32768))')
                content = source.read_bytes()
                expected = len(content) + 4096
                if corrupt:
                    content = content[:-4096] + b'\xff' * 4096
                    truncated = root / 'truncated.sqlite'
                    truncated.write_bytes(content)
                    with sqlite3.connect(f'file:{truncated}?mode=ro&immutable=1', uri=True) as db:
                        self.assertEqual(db.execute('SELECT length(auth_key) FROM ringconfiguration').fetchone(), (16,))
                manifest = root / 'Manifest.db'
                with sqlite3.connect(manifest) as db:
                    db.execute('CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT)')
                    db.execute('INSERT INTO Files VALUES (?, ?, ?)', ('a'*40, filtered.DOMAIN, 'UUID/assa.sqlite'))
                entry = SimpleNamespace(domain=filtered.DOMAIN, relative_path='UUID/assa.sqlite', size=expected, read_bytes=lambda: content)
                fake = SimpleNamespace(_manifest_db=SimpleNamespace(path=manifest), get_entry_by_id=lambda _: entry)
                with patch('pyiosbackup.Backup.from_path', return_value=fake):
                    if corrupt:
                        with self.assertRaises(filtered.OuraPayloadMissing): filtered.make_readable(root, root/'Reader', '')
                    else:
                        filtered.make_readable(root, root/'Reader', '')
                        self.assertTrue(filtered.reader_has_key(root/'Reader'))

    def test_missing_or_truncated_selected_payload_has_a_specific_failure(self):
        from unittest.mock import patch
        import sqlite3
        for missing in [False, True]:
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                manifest = root / 'Manifest.db'
                with sqlite3.connect(manifest) as db:
                    db.execute('CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT)')
                    db.execute('INSERT INTO Files VALUES (?, ?, ?)', ('a'*40, filtered.DOMAIN, 'UUID/assa.sqlite'))
                def content():
                    if missing: raise FileNotFoundError('/private/not-for-logs')
                    return b''
                entry = SimpleNamespace(domain=filtered.DOMAIN, relative_path='UUID/assa.sqlite', size=16, read_bytes=content)
                fake = SimpleNamespace(_manifest_db=SimpleNamespace(path=manifest), get_entry_by_id=lambda _: entry)
                phase = {}
                with patch('pyiosbackup.Backup.from_path', return_value=fake), self.assertRaises(filtered.OuraPayloadMissing):
                    filtered.make_readable(root, root/'Reader', '', phase)
                self.assertEqual(phase['stage'], 'payload')

    def test_diagnostics_keep_only_safe_stage_kind_and_numeric_code(self):
        error = ValueError("secret key /private/health.db {'ErrorCode': 104, 'ErrorDescription': 'private'}")
        result = filtered.safe_failure(error, 'transfer')
        self.assertEqual(result, {'stage': 'transfer', 'kind': 'ValueError', 'deviceCode': 104})
        self.assertNotIn('secret', str(result)); self.assertNotIn('private', str(result))
        self.assertEqual(filtered.safe_failure(RuntimeError('private'), 'private'), {'stage': 'unknown', 'kind': 'UnknownError'})

class CandidateTests(unittest.TestCase):
    def test_opaque_candidates_are_bounded_and_known_other_apps_are_rejected(self):
        from pymobiledevice3.services.mobilebackup2 import BackupFile
        callback = filtered.OuraFilter('/var/mobile/Containers/Data/Application/11111111-2222-3333-4444-555555555555')
        self.assertTrue(callback.needs_attribution(BackupFile(device_name='/.b/6/ACCOUNT/assa.sqlite')))
        self.assertTrue(callback.needs_attribution(BackupFile(device_name='/.b/6/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/assa.sqlite')))
        self.assertFalse(callback.needs_attribution(BackupFile(device_name='/.b/6/ACCOUNT/photo.jpg')))
        self.assertFalse(callback.needs_attribution(BackupFile(device_name='AppDomain-other/assa.sqlite')))
        self.assertFalse(callback.needs_attribution(BackupFile(device_name='/.ba/mobile/Containers/Data/Application/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/assa.sqlite')))
        buffers = filtered.CandidateBuffers(limit=4)
        buffers.account(4)
        with self.assertRaises(filtered.StorageLimitError): buffers.account(1)

    def test_wire_upload_keeps_candidates_in_memory_and_restores_only_manifest_verified_oura(self):
        import asyncio, struct, sqlite3
        from unittest.mock import AsyncMock, patch
        from pymobiledevice3.services.device_link import DeviceLink
        async def run():
            with tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                ours, other, photo = 'a'*40, 'b'*40, 'c'*40
                frames = []
                for device_name, file_name, data in [
                    ('/.b/6/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/assa.sqlite', f'device/Snapshot/aa/{ours}', b'fixture-ciphertext-oura'),
                    ('/.b/7/OTHER/assa.sqlite', f'device/Snapshot/bb/{other}', b'other-candidate'),
                    ('/.b/8/photo.jpg', f'device/Snapshot/cc/{photo}', b'unrelated-photo')]:
                    for name in [device_name, file_name]: frames += [struct.pack('>I', len(name.encode())), name.encode()]
                    frames += [struct.pack('>I', len(data)+1), struct.pack('>B', 0xC), data, struct.pack('>I', 1), struct.pack('>B', 0)]
                frames += [struct.pack('>I', 0), b'']
                wire = AsyncMock(); wire.recvall = AsyncMock(side_effect=frames)
                service = filtered.filtered_service_type()(SimpleNamespace(udid='device'))
                service._service = wire; service.connect = AsyncMock(); service.version_exchange = AsyncMock()
                with patch.object(DeviceLink, 'version_exchange', AsyncMock()), patch.object(DeviceLink, 'disconnect', AsyncMock()):
                    async with service.device_link(root, filter_callback=filtered.OuraFilter()) as dl:
                        await dl.upload_files(['DLMessageUploadFiles'])
                        self.assertEqual(len(dl.candidates.files), 2)
                        self.assertEqual((root/f'device/Snapshot/aa/{ours}').read_bytes(), b'')
                        await dl.move_items(['DLMessageMoveItems', {'device/Snapshot': 'device/Finished'}])
                        payload = root/f'device/Finished/aa/{ours}'
                        manifest = root/'device/Manifest.db'
                        with sqlite3.connect(manifest) as db:
                            db.execute('CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT)')
                            db.execute('INSERT INTO Files VALUES (?, ?, ?)', (ours, filtered.DOMAIN, 'ACCOUNT/assa.sqlite'))
                            db.execute('INSERT INTO Files VALUES (?, ?, ?)', (other, 'AppDomain-other', 'OTHER/assa.sqlite'))
                        entry = SimpleNamespace(domain=filtered.DOMAIN, relative_path='ACCOUNT/assa.sqlite', real_path=payload)
                        def read_entry(file_id):
                            self.assertEqual(file_id, ours)
                            return entry
                        backup = SimpleNamespace(_manifest_db=SimpleNamespace(path=manifest), get_entry_by_id=read_entry)
                        dl.completed = True
                        with patch('pyiosbackup.Backup.from_path', return_value=backup): dl.cleanup_discarded_files()
                        self.assertEqual(payload.read_bytes(), b'fixture-ciphertext-oura')
                        self.assertFalse((root/f'device/Finished/bb/{other}').exists())
                        self.assertFalse((root/f'device/Finished/cc/{photo}').exists())
                        self.assertEqual(dl.candidates.files, {})
        asyncio.run(run())

class EarlyRecoveryTests(unittest.TestCase):
    def test_stops_only_after_complete_journal_and_verified_key(self):
        import sqlite3
        from unittest.mock import patch
        for buffered, empty_journal in [(False, False), (True, False), (False, True), (True, True)]:
            with self.subTest(buffered=buffered, empty_journal=empty_journal), tempfile.TemporaryDirectory() as temp:
                folder = Path(temp)
                root = folder / 'device'
                root.mkdir()
                (folder / '.scratch').mkdir()
                fixture = sqlite3.connect(folder / 'fixture.sqlite')
                fixture.execute('PRAGMA journal_mode=WAL')
                fixture.execute('CREATE TABLE ringconfiguration (id TEXT, auth_key BLOB)')
                fixture.commit()
                fixture.execute('PRAGMA wal_checkpoint(TRUNCATE)')
                fixture.execute('INSERT INTO ringconfiguration VALUES (?, ?)', ('fixture-ring', b'0123456789abcdef'))
                fixture.commit()
                if empty_journal: fixture.execute('PRAGMA wal_checkpoint(TRUNCATE)')
                database = (folder / 'fixture.sqlite').read_bytes()
                journal = (folder / 'fixture.sqlite-wal').read_bytes()
                fixture.close()
                payloads = {'a'*40: ('UUID/assa.sqlite', database), 'b'*40: ('UUID/assa.sqlite-wal', journal)}
                with sqlite3.connect(root / 'Manifest.db') as index:
                    index.execute('CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT)')
                    index.executemany('INSERT INTO Files VALUES (?, ?, ?)', [(key, filtered.DOMAIN, name) for key, (name, _) in payloads.items()])
                for name in ['Manifest.plist', 'Info.plist', 'Status.plist']:
                    (root / name).write_bytes(b'fixture-metadata')
                candidates = filtered.CandidateBuffers()
                early = filtered.EarlyRecovery(root, '', candidates, filtered.StorageBudget(folder))
                def open_backup(path, password):
                    def entry(key):
                        name, content = payloads[key]
                        source = path / key
                        return SimpleNamespace(domain=filtered.DOMAIN, relative_path=name, size=len(content), real_path=source, read_bytes=source.read_bytes)
                    return SimpleNamespace(_manifest_db=SimpleNamespace(path=path / 'Manifest.db'), get_entry_by_id=entry)
                source = root / ('a'*40)
                source.write_bytes(b'' if buffered else database)
                if buffered: candidates.remember(source, database)
                with patch('pyiosbackup.Backup.from_path', side_effect=open_backup):
                    early.received_file(source)
                    early.received_file(root / 'Manifest.db')
                    early.received_file(root / 'Manifest.plist')
                    self.assertFalse((folder / 'Reader').exists())
                    wal = root / ('b'*40)
                    wal.write_bytes(journal)
                    # Presence alone is insufficient; only the success callback marks it complete.
                    early.received_file(root / 'Status.plist')
                    self.assertFalse((folder / 'Reader').exists())
                    with self.assertRaises(filtered.EarlyKeyReady): early.received_file(wal, allow_empty=True)
                self.assertTrue(filtered.reader_has_key(folder / 'Reader'))
                candidates.clear()

    def test_invalid_keys_cannot_trigger_early_success(self):
        import sqlite3
        with tempfile.TemporaryDirectory() as temp:
            reader = Path(temp) / 'Reader'
            reader.mkdir()
            with sqlite3.connect(reader / 'Manifest.db') as index:
                index.execute('CREATE TABLE Files (relativePath TEXT, fileID TEXT, domain TEXT)')
                index.execute('INSERT INTO Files VALUES (?, ?, ?)', ('UUID/assa.sqlite', 'a'*40, filtered.DOMAIN))
            with sqlite3.connect(reader / ('a'*40)) as db:
                db.execute('CREATE TABLE ringconfiguration (id TEXT, auth_key TEXT)')
                db.execute('INSERT INTO ringconfiguration VALUES (?, ?)', ('fixture-ring', 'not-a-key'))
            self.assertFalse(filtered.reader_has_key(reader))

class ActivityTests(unittest.TestCase):
    def test_discarded_bytes_report_real_activity_without_retaining_contents(self):
        import io
        import json
        from unittest.mock import patch
        activity = filtered.TransferActivity()
        saved = io.BytesIO()
        with patch.object(filtered.time, 'monotonic', side_effect=[10, 10.1, 11.1]), patch('builtins.print') as output:
            filtered.ActivityWriter(saved, activity).write(b'ours')
            filtered.ActivityWriter(None, activity).write(b'discarded')
            activity.files = 2
            activity.report()
        self.assertEqual(saved.getvalue(), b'ours')
        self.assertEqual(output.call_count, 2)
        message = output.call_args.args[0]
        self.assertTrue(message.startswith('OURA_ACTIVITY '))
        self.assertEqual(json.loads(message[14:]), {'files': 2, 'bytes': 13, 'indexReady': False})
        self.assertNotIn('ours', message)
        self.assertNotIn('discarded', message)

if __name__ == '__main__': unittest.main()
