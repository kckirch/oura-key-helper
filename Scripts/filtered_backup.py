#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Retain Oura's key database only; never print keys, paths, or device error descriptions."""
import asyncio
import base64
from contextlib import asynccontextmanager, suppress
import shutil
import hashlib
import io
import json
import logging
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import sys
import tempfile
import time
import uuid

DOMAIN = 'AppDomain-com.ouraring.oura'
NAMES = {'assa.sqlite', 'assa.sqlite-wal', 'assa.sqlite-shm'}
PATTERN = re.compile(r'^AppDomain-com\.ouraring\.oura(?:/|-)(?:[^/]+/)*assa\.sqlite(?:-wal|-shm)?$')


class OuraPayloadMissing(Exception):
    def __init__(self, name='assa.sqlite', expected=0, actual=None):
        self.payload = {'assa.sqlite': 'database', 'assa.sqlite-wal': 'journal', 'assa.sqlite-shm': 'shared-memory'}.get(name, 'database')
        self.state = 'absent' if actual is None else 'size-mismatch'
        self.expected, self.actual = expected, actual
class OuraDatabaseMissing(Exception): pass
class StorageLimitError(OSError): pass
class EarlyKeyReady(Exception): pass

SAFE_STAGES = {'connect', 'prepare', 'transfer', 'decrypt', 'index', 'payload', 'unknown'}
SAFE_KINDS = {'FileNotFoundError', 'PermissionError', 'OSError', 'ValueError', 'DatabaseError', 'OperationalError', 'BackupPasswordIsRequired', 'InvalidPassword', 'CorruptedEntryError', 'MissingEntryError', 'NotEnoughDiskSpaceError', 'ConnectionTerminatedError', 'ConnectionResetError', 'ConnectionAbortedError', 'TimeoutError', 'PyMobileDevice3Exception', 'OuraPayloadMissing', 'OuraDatabaseMissing', 'StorageLimitError'}

def safe_failure(error, stage):
    kind = type(error).__name__
    result = {'stage': stage if stage in SAFE_STAGES else 'unknown', 'kind': kind if kind in SAFE_KINDS else 'UnknownError'}
    if isinstance(error, OuraPayloadMissing):
        result.update(payload=error.payload, state=error.state)
        if isinstance(error.expected, int) and 0 <= error.expected <= 1 << 60: result['expectedBytes'] = error.expected
        if isinstance(error.actual, int) and 0 <= error.actual <= 1 << 60: result['receivedBytes'] = error.actual
    # Parse only the numeric protocol code; never return exception text or traceback.
    match = re.search(r"['\"]ErrorCode['\"]:\s*(-?\d+)", str(error))
    if match:
        code = int(match.group(1))
        if -(2**31) <= code < 2**31: result['deviceCode'] = code
    return result


def keep_file(file):
    name = file.device_name
    return bool(name and PATTERN.fullmatch(name) and '..' not in name.split('/'))


class OuraFilter:
    def __init__(self, container=None):
        self.container_uuid = None
        if isinstance(container, str):
            try: self.container_uuid = str(uuid.UUID(Path(container).name)).upper()
            except ValueError: pass
    def __call__(self, file):
        if keep_file(file): return True
        name = file.device_name
        if not name or not self.container_uuid: return False
        if not name.startswith(('/.b/', '/.ba/', '/var/mobile/Containers/Data/Application/', '/private/var/mobile/Containers/Data/Application/')): return False
        parts = name.split('/')
        return '..' not in parts and Path(name).name in NAMES and self.container_uuid in [p.upper() for p in parts]
    def needs_attribution(self, file):
        name = file.device_name
        if not name or self(file): return False
        parts = name.split('/')
        if not name.startswith(('/.b/', '/.ba/')) or '..' in parts or Path(name).name not in NAMES: return False
        # Oura's account folder is also a UUID; only a container path identifies another app.
        container = re.search(r'(?:^|/)Containers/Data/Application/([^/]+)(?:/|$)', name)
        if container and self.container_uuid and container.group(1).upper() != self.container_uuid: return False
        return True


def selected_file_ids(backup):
    with sqlite3.connect(f'file:{backup._manifest_db.path}?mode=ro&immutable=1', uri=True) as db:
        rows = db.execute(
            "SELECT fileID FROM Files WHERE domain = ? AND (relativePath = 'assa.sqlite' OR relativePath GLOB '*/assa.sqlite' OR relativePath = 'assa.sqlite-wal' OR relativePath GLOB '*/assa.sqlite-wal' OR relativePath = 'assa.sqlite-shm' OR relativePath GLOB '*/assa.sqlite-shm')", (DOMAIN,)).fetchall()
    ids = [row[0] for row in rows]
    if any(not isinstance(value, str) or not re.fullmatch(r'[0-9a-fA-F]{40}', value) for value in ids):
        raise ValueError('Invalid Oura file identifier')
    return ids


class CandidateBuffers:
    def __init__(self, limit=64 * 1024 * 1024):
        self.limit, self.written, self.files, self.handles = limit, 0, {}, {}
    def account(self, size):
        if self.written + size > self.limit: raise StorageLimitError()
        self.written += size
    def remember(self, path, data):
        inode = path.stat().st_ino
        if inode not in self.handles:
            if len(self.handles) >= 64: raise StorageLimitError()
            self.handles[inode] = path.open('rb')  # Keep unlinked placeholders alive; inode IDs must not be recycled.
        self.files[inode] = data
    def copy_identity(self, source, target):
        if source.is_dir():
            for path in source.rglob('*'):
                if path.is_file(): self.copy_identity(path, target / path.relative_to(source))
        elif source.exists() and target.exists():
            data = self.files.get(source.stat().st_ino)
            if data is not None: self.remember(target, data)
    def restore_verified(self, backup, budget):
        restored = []
        for file_id in selected_file_ids(backup):
            entry = backup.get_entry_by_id(file_id)
            if entry.domain != DOMAIN or Path(entry.relative_path).name not in NAMES: raise ValueError('Invalid attribution')
            path = entry.real_path
            if path.is_symlink() or not path.resolve().is_relative_to(budget.root.resolve()): raise ValueError('Unsafe candidate path')
            if not path.exists(): continue
            data = self.files.get(path.stat().st_ino)
            if data is None: continue
            budget.account(len(data))
            path.write_bytes(data)  # Still encrypted when the original backup is encrypted.
            restored.append(path)
        self.clear()
        return restored
    def clear(self):
        self.files.clear()
        for handle in self.handles.values(): handle.close()
        self.handles.clear()


def make_readable(backup_path, destination, password, phase=None):
    """Create a tiny reader-compatible index, decrypting only retained Oura payloads."""
    from pyiosbackup import Backup
    phase = phase if phase is not None else {}
    phase['stage'] = 'decrypt'
    budget = StorageBudget(destination.parent, limit=1024 * 1024 * 1024)
    manifest = backup_path / 'Manifest.db'
    if manifest.exists(): budget.account(manifest.stat().st_size)
    backup = Backup.from_path(backup_path, password=password)
    phase['stage'] = 'index'
    destination.mkdir(mode=0o700)
    size_mismatch = None
    with sqlite3.connect(destination / 'Manifest.db') as index:
        index.execute('CREATE TABLE Files (fileID TEXT, domain TEXT, relativePath TEXT)')
        # The pinned library's iter_entries() decodes every app's archived metadata.
        # Select file IDs with SQLite first; decode only our own three payload types.
        file_ids = selected_file_ids(backup)
        if not file_ids: raise OuraDatabaseMissing()
        phase['stage'] = 'payload'
        for file_id in file_ids:
            entry = backup.get_entry_by_id(file_id)
            if entry.domain != DOMAIN or Path(entry.relative_path).name not in NAMES:
                continue
            if entry.relative_path.startswith('/') or '..' in entry.relative_path.split('/'):
                raise ValueError('Unsafe Oura path')
            file_id = hashlib.sha1((DOMAIN + '-' + entry.relative_path).encode()).hexdigest()
            # Entry.read_bytes decrypts just this payload; no extract_all/unback call.
            try: content = entry.read_bytes()
            except FileNotFoundError: raise OuraPayloadMissing(Path(entry.relative_path).name, entry.size) from None
            if len(content) != entry.size:
                error = OuraPayloadMissing(Path(entry.relative_path).name, entry.size, len(content))
                if Path(entry.relative_path).name != 'assa.sqlite': raise error
                size_mismatch = error
            budget.account(len(content))
            (destination / file_id).write_bytes(content)
            index.execute('INSERT INTO Files VALUES (?, ?, ?)', (file_id, DOMAIN, entry.relative_path))
    (destination / 'Manifest.plist').write_bytes(plistlib.dumps({'IsEncrypted': False}))
    if size_mismatch is not None:
        # A live SQLite file can change size after indexing; never accept a broken snapshot.
        try: valid = reader_has_key(destination)
        except sqlite3.Error: valid = False
        if not valid: raise size_mismatch


class StorageBudget:
    def __init__(self, root, limit=512 * 1024 * 1024, reserve=256 * 1024 * 1024):
        self.root, self.limit, self.reserve, self.written = root, limit, reserve, 0
    def check(self, size):
        if self.written + size > self.limit or shutil.disk_usage(self.root).free - size < self.reserve:
            raise StorageLimitError()
    def account(self, size):
        self.check(size)
        self.written += size


class BudgetWriter:
    def __init__(self, destination, budget): self.destination, self.budget = destination, budget
    def write(self, chunk):
        self.budget.account(len(chunk))
        return self.destination.write(chunk)


class TransferActivity:
    def __init__(self):
        self.files, self.bytes, self.index_ready, self.last_report = 0, 0, False, 0
    def report(self):
        now = time.monotonic()
        if now - self.last_report < 1: return
        self.last_report = now
        print('OURA_ACTIVITY ' + json.dumps({'files': self.files, 'bytes': self.bytes, 'indexReady': self.index_ready}), flush=True)
    def write(self, chunk):
        self.bytes += len(chunk)
        self.report()
        return len(chunk)


class ActivityWriter:
    def __init__(self, destination, activity): self.destination, self.activity = destination, activity
    def write(self, chunk):
        if self.destination is not None: self.destination.write(chunk)
        return self.activity.write(chunk)


def reader_has_key(reader):
    """Verify locally without returning, logging, or saving the key separately."""
    with sqlite3.connect(reader / 'Manifest.db') as index:
        entries = dict(index.execute('SELECT relativePath, fileID FROM Files WHERE domain = ?', (DOMAIN,)))
    with tempfile.TemporaryDirectory(dir=reader.parent) as temp:
        found = False
        budget = StorageBudget(reader.parent, limit=1024 * 1024 * 1024)
        for offset, name in enumerate(entries):
            if Path(name).name != 'assa.sqlite': continue
            target = Path(temp) / str(offset)
            target.mkdir()
            for suffix in ['', '-wal', '-shm']:
                if name + suffix in entries:
                    budget.account((reader / entries[name + suffix]).stat().st_size)
                    shutil.copyfile(reader / entries[name + suffix], target / ('assa.sqlite' + suffix))
            immutable = '' if (target / 'assa.sqlite-wal').exists() else '&immutable=1'
            with sqlite3.connect(f'file:{target}/assa.sqlite?mode=ro{immutable}', uri=True) as db:
                if db.execute('PRAGMA quick_check').fetchall() != [('ok',)]: return False
                rows = db.execute('SELECT id, auth_key FROM ringconfiguration WHERE auth_key IS NOT NULL')
                for ring_id, value in rows:
                    if ring_id is None: continue
                    if isinstance(value, bytes) and len(value) == 16: found = True
                    if isinstance(value, str):
                        value = value.strip()
                        if re.fullmatch(r'[0-9a-fA-F]{32}', value): found = True
                        with suppress(ValueError):
                            if len(base64.b64decode(value, validate=True)) == 16: found = True
    return found


class EarlyRecovery:
    def __init__(self, root, password, candidates, budget):
        self.root, self.password, self.candidates, self.budget = root, password, candidates, budget
        self.received = set()
        self.manifest_signature = None
        self.backup = None

    @staticmethod
    def signature(path):
        info = path.stat()
        return info.st_ino, info.st_size, info.st_mtime_ns

    def received_file(self, path, allow_empty=False):
        if path.is_file():
            signature = self.signature(path)
            if signature[1] == 0 and signature[0] not in self.candidates.files and not allow_empty: return
            self.received.add(signature)
        # Only complete, received manifest files can identify a consistent snapshot.
        metadata = [self.root / name for name in ['Manifest.db', 'Manifest.plist']]
        if not all(p.is_file() and self.signature(p) in self.received for p in metadata): return
        try:
            from pyiosbackup import Backup
            signature = tuple(self.signature(p) for p in metadata)
            if signature != self.manifest_signature:
                self.budget.check(metadata[0].stat().st_size)
                self.backup = Backup.from_path(self.root, password=self.password)
                self.manifest_signature = signature
            file_ids = selected_file_ids(self.backup)
            if not file_ids: return
            payloads = []
            for file_id in file_ids:
                entry = self.backup.get_entry_by_id(file_id)
                source = entry.real_path
                if source.is_symlink() or not source.resolve().is_relative_to(self.root.resolve()): return
                if not source.is_file() or self.signature(source) not in self.received: return
                payloads.append((file_id, source))
            with tempfile.TemporaryDirectory(dir=self.root.parent / '.scratch') as temp:
                snapshot = Path(temp) / 'Snapshot'
                snapshot.mkdir()
                for name in ['Manifest.db', 'Manifest.plist', 'Info.plist', 'Status.plist']:
                    os.link(self.root / name, snapshot / name)
                for file_id, source in payloads:
                    target = snapshot / source.relative_to(self.root)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    buffered = self.candidates.files.get(source.stat().st_ino)
                    if buffered is not None:
                        self.budget.account(len(buffered))
                        target.write_bytes(buffered)
                    else: os.link(source, target)
                reader = Path(temp) / 'Reader'
                make_readable(snapshot, reader, self.password)
                if not reader_has_key(reader): return
                reader.rename(self.root.parent / 'Reader')
        except Exception:
            # Optional fast path: incomplete metadata/payloads never abort normal collection.
            return
        raise EarlyKeyReady()


def filtered_service_type():
    from pymobiledevice3.services.mobilebackup2 import Mobilebackup2Service
    from pymobiledevice3.services.device_link import DeviceLink, CODE_SUCCESS
    from pymobiledevice3.services.mobilebackup2 import BackupFile
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
            self.candidates.copy_identity(source, resolve_device_path(self.root_path, message[2]))
            target = resolve_device_path(self.root_path, message[2])
            pairs = [(source, target)] if source.is_file() else [(p, target / p.relative_to(source)) for p in source.rglob('*') if p.is_file()]
            for original, copied in pairs:
                if self.early.signature(original) in self.early.received:
                    self.early.received_file(copied, allow_empty=True)
        async def dl_loop(self, progress_callback=None):
            result = await super().dl_loop(progress_callback)
            self.completed = True
            return result
        def cleanup_discarded_files(self):
            if self.completed and self.candidates.files:
                from pyiosbackup import Backup
                manifest = self.backup_path / 'Manifest.db'
                StorageBudget(self.root_path, limit=1024 * 1024 * 1024).check(manifest.stat().st_size)
                backup = Backup.from_path(self.backup_path, password=self.password)
                for path in self.candidates.restore_verified(backup, self.budget):
                    self._discarded_files.discard(path.resolve().relative_to(self.root_path))
            self.candidates.clear()
            super().cleanup_discarded_files()
        async def _consume_file_transfer(self, size, code, destination=None):
            buffer = None
            if destination is not None:
                destination = BudgetWriter(destination, self.budget)
            elif self.pending_candidate is not None:
                buffer = io.BytesIO()
                destination = BudgetWriter(buffer, self.candidates)
            result = await super()._consume_file_transfer(size, code, ActivityWriter(destination, self.activity))
            if result[1] == CODE_SUCCESS:
                if buffer is not None: self.candidates.remember(self.pending_candidate, buffer.getvalue())
                self.activity.files += 1
                self.activity.report()
            return result
    class FilteredService(Mobilebackup2Service):
        @asynccontextmanager
        async def device_link(self, backup_directory, filter_callback=None, password=''):
            if not isinstance(filter_callback, OuraFilter): raise ValueError('Unfiltered collection is forbidden')
            await self.connect()
            dl = FilteredDeviceLink(self._service, backup_directory)
            dl.budget = StorageBudget(backup_directory)
            dl.candidates = CandidateBuffers()
            dl.activity = TransferActivity()
            dl.completed = False
            dl.pending_candidate = None
            dl.kept_path = None
            dl.backup_path = backup_directory / self.lockdown.udid
            dl.password = password
            dl.early = EarlyRecovery(dl.backup_path, password, dl.candidates, dl.budget)
            def received(file_name, device_name):
                path = resolve_device_path(backup_directory, file_name)
                dl.early.received_file(path, allow_empty=(path == dl.kept_path))
                dl.activity.index_ready = dl.early.manifest_signature is not None
            dl.post_file_receive = received
            def preserve(file_name, device_name):
                candidate = filter_callback.needs_attribution(BackupFile(file_name=file_name, device_name=device_name))
                dl.pending_candidate = resolve_device_path(backup_directory, file_name) if candidate else None
                keep = self.should_preserve_backup_file(file_name, device_name, filter_callback)
                dl.kept_path = resolve_device_path(backup_directory, file_name) if keep else None
                return keep
            dl.preserve_file = preserve
            await dl.version_exchange()
            await self.version_exchange(dl)
            try: yield dl
            finally:
                with suppress(Exception): await dl.disconnect()
    return FilteredService


async def collect(device, folder, password, phase):
    from pymobiledevice3.lockdown import create_using_usbmux
    scratch = folder / '.scratch'
    scratch.mkdir(mode=0o700)
    # Third-party manifest decryption uses temporary files: keep them inside our owned folder.
    tempfile.tempdir = str(scratch)
    phase['stage'] = 'connect'
    lockdown = await create_using_usbmux(serial=device, connection_type='USB', autopair=False)
    try:
        phase['stage'] = 'prepare'
        from pymobiledevice3.services.installation_proxy import InstallationProxyService
        async with InstallationProxyService(lockdown) as apps:
            app = await apps.lookup({'BundleIDs': ['com.ouraring.oura'], 'ReturnAttributes': ['Container']})
        container = (app or {}).get('com.ouraring.oura', {}).get('Container')
        selection = OuraFilter(container)
        def progress(value):
            if isinstance(value, (int, float)) and 0 <= value <= 100:
                print('OURA_PROGRESS ' + str(int(value)), flush=True)
        phase['stage'] = 'transfer'
        async with filtered_service_type()(lockdown) as service:
            try:
                await service.backup(full=True, backup_directory=folder, filter_callback=selection, progress_callback=progress, password=password)
            except EarlyKeyReady:
                return
        make_readable(folder / device, folder / 'Reader', password, phase)
    finally:
        with suppress(Exception): await lockdown.close()


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
    phase = {'stage': 'connect'}
    try:
        asyncio.run(collect(device, folder, secret, phase))
    except KeyboardInterrupt:
        print('ErrorCode 901: Cancelled', flush=True)
        return 1
    except Exception as error:
        # Avoid library exception messages, which may contain unrelated paths or device data.
        print('OURA_FAILURE ' + json.dumps(safe_failure(error, phase['stage'])), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
