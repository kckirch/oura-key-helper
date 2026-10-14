#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Retain Oura's key database only; never print keys, paths, or device error descriptions."""
import asyncio
from contextlib import asynccontextmanager, suppress
import shutil
import hashlib
import json
import logging
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import sys
import tempfile

DOMAIN = 'AppDomain-com.ouraring.oura'
NAMES = {'assa.sqlite', 'assa.sqlite-wal', 'assa.sqlite-shm'}
PATTERN = re.compile(r'^AppDomain-com\.ouraring\.oura(?:/|-)(?:[^/]+/)*assa\.sqlite(?:-wal|-shm)?$')


def keep_file(file):
    name = file.device_name
    return bool(name and PATTERN.fullmatch(name) and '..' not in name.split('/'))


def make_readable(backup_path, destination, password):
    """Create a tiny reader-compatible index, decrypting only retained Oura payloads."""
    from pyiosbackup import Backup
    budget = StorageBudget(destination.parent, limit=1024 * 1024 * 1024)
    manifest = backup_path / 'Manifest.db'
    if manifest.exists(): budget.account(manifest.stat().st_size)
    backup = Backup.from_path(backup_path, password=password)
    destination.mkdir(mode=0o700)
    with sqlite3.connect(destination / 'Manifest.db') as index:
        index.execute('CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT)')
        for entry in backup.iter_entries():
            if entry.domain != DOMAIN or Path(entry.relative_path).name not in NAMES:
                continue
            if entry.relative_path.startswith('/') or '..' in entry.relative_path.split('/'):
                raise ValueError('Unsafe Oura path')
            file_id = hashlib.sha1((DOMAIN + '-' + entry.relative_path).encode()).hexdigest()
            # Entry.read_bytes decrypts just this payload; no extract_all/unback call.
            content = entry.read_bytes()
            budget.account(len(content))
            (destination / file_id).write_bytes(content)
            index.execute('INSERT INTO Files VALUES (?, ?, ?)', (file_id, DOMAIN, entry.relative_path))
    (destination / 'Manifest.plist').write_bytes(plistlib.dumps({'IsEncrypted': False}))


class StorageBudget:
    def __init__(self, root, limit=512 * 1024 * 1024, reserve=256 * 1024 * 1024):
        self.root, self.limit, self.reserve, self.written = root, limit, reserve, 0
    def check(self, size):
        if self.written + size > self.limit or shutil.disk_usage(self.root).free - size < self.reserve:
            raise OSError('Filtered storage budget exceeded')
    def account(self, size):
        self.check(size)
        self.written += size


class BudgetWriter:
    def __init__(self, destination, budget): self.destination, self.budget = destination, budget
    def write(self, chunk):
        self.budget.account(len(chunk))
        return self.destination.write(chunk)


def filtered_service_type():
    from pymobiledevice3.services.mobilebackup2 import Mobilebackup2Service
    from pymobiledevice3.services.device_link import DeviceLink
    from pymobiledevice3.safe_paths import resolve_device_path
    class FilteredDeviceLink(DeviceLink):
        async def get_free_disk_space(self, message):
            self.budget.check(0)
            # Capacity of the discard sink, not physical storage. Saved chunks stay strictly budgeted.
            self._reported_free_space = 1 << 60
            await self.status_response(0, status_dict=self._reported_free_space)
        async def copy_item(self, message):
            source = resolve_device_path(self.root_path, message[1])
            if source.exists():
                size = sum(p.stat().st_size for p in source.rglob('*') if p.is_file()) if source.is_dir() else source.stat().st_size
                self.budget.account(size)
            await super().copy_item(message)
        async def _consume_file_transfer(self, size, code, destination=None):
            writer = BudgetWriter(destination, self.budget) if destination is not None else None
            return await super()._consume_file_transfer(size, code, writer)
    class FilteredService(Mobilebackup2Service):
        @asynccontextmanager
        async def device_link(self, backup_directory, filter_callback=None, password=''):
            if filter_callback is not keep_file: raise ValueError('Unfiltered collection is forbidden')
            await self.connect()
            dl = FilteredDeviceLink(self._service, backup_directory,
                preserve_file=lambda file_name, device_name: self.should_preserve_backup_file(file_name, device_name, filter_callback))
            dl.budget = StorageBudget(backup_directory)
            await dl.version_exchange()
            await self.version_exchange(dl)
            try: yield dl
            finally:
                with suppress(Exception): await dl.disconnect()
    return FilteredService


async def collect(device, folder, password):
    from pymobiledevice3.lockdown import create_using_usbmux
    scratch = folder / '.scratch'
    scratch.mkdir(mode=0o700)
    # Third-party manifest decryption uses temporary files: keep them inside our owned folder.
    tempfile.tempdir = str(scratch)
    lockdown = await create_using_usbmux(serial=device, connection_type='USB', autopair=False)
    try:
        def progress(value):
            if isinstance(value, (int, float)) and 0 <= value <= 100:
                print('OURA_PROGRESS ' + str(int(value)), flush=True)
        async with filtered_service_type()(lockdown) as service:
            await service.backup(full=True, backup_directory=folder, filter_callback=keep_file, progress_callback=progress)
        make_readable(folder / device, folder / 'Reader', password)
    finally:
        await lockdown.close()


async def usb_devices():
    from pymobiledevice3.usbmux import list_devices
    return [d for d in await list_devices() if d.connection_type == 'USB']


async def probe():
    devices = await usb_devices()
    if not devices: return {'state': 'none'}
    if len(devices) > 1: return {'state': 'multiple', 'count': len(devices)}
    name = ''
    lockdown = None
    try:
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.installation_proxy import InstallationProxyService
        lockdown = await create_using_usbmux(serial=devices[0].serial, connection_type='USB', autopair=False)
        name = await lockdown.get_value(key='DeviceName') or ''
        domain = await lockdown.get_value(domain='com.apple.mobile.backup')
        if not isinstance(domain, dict) or not isinstance(domain.get('WillEncrypt', False), bool):
            return {'state': 'needsTrust', 'name': name}
        async with InstallationProxyService(lockdown) as apps:
            result = await apps.lookup({'BundleIDs': ['com.ouraring.oura'], 'ReturnAttributes': ['CFBundleIdentifier']})
        if not isinstance(result, dict): return {'state': 'ouraCheckUnavailable', 'name': name}
        if not result: return {'state': 'missingOura', 'name': name}
        if 'com.ouraring.oura' not in result: return {'state': 'ouraCheckUnavailable', 'name': name}
        return {'state': 'encrypted' if domain.get('WillEncrypt', False) else 'connected', 'name': name}
    except Exception:
        return {'state': 'needsTrust', 'name': name}
    finally:
        if lockdown: await lockdown.close()


def main():
    os.umask(0o077)
    logging.disable(logging.CRITICAL)
    import warnings
    warnings.filterwarnings('ignore')
    if sys.argv[1:] == ['--probe']:
        try: print(json.dumps(asyncio.run(probe())))
        except Exception: print(json.dumps({'state': 'unavailable'}))
        return 0
    if sys.argv[1:] == ['--devices']:
        for device in asyncio.run(usb_devices()): print(device.serial)
        return 0
    device, path = sys.argv[1:]
    folder = Path(path).resolve()
    if not folder.is_dir() or (folder / '.oura-helper-owned').read_text() != folder.name:
        raise ValueError('Not helper-owned')
    secret = os.environ.pop('BACKUP_PASSWORD', '')
    try:
        asyncio.run(collect(device, folder, secret))
    except KeyboardInterrupt:
        print('ErrorCode 901: Cancelled', flush=True)
        return 1
    except Exception as error:
        # Avoid library exception messages, which may contain unrelated paths or device data.
        print('ErrorCode 902: ' + type(error).__name__, flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
