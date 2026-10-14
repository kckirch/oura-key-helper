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
        entry = SimpleNamespace(domain=filtered.DOMAIN, relative_path='UUID/assa.sqlite', read_bytes=lambda: b'fixture-oura-db')
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

if __name__ == '__main__': unittest.main()
