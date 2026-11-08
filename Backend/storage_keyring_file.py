"""Opt-in protected file transport for storage keys, never provider credentials.

The file is read once during startup. Atomic replacement takes effect only on
restart; no per-request disk reads or automatic key generation/activation.
"""
import json
import os
from pathlib import Path
import stat

try:
    from Backend.storage_keyring import StorageKeyring, unique_object
except ModuleNotFoundError:
    from storage_keyring import StorageKeyring, unique_object


def load(path, legacy_keys):
    directory = descriptor = None
    try:
        target = Path(path)
        if not target.is_absolute() or '..' in target.parts:
            raise ValueError()
        directory = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        for part in target.parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        parent = os.fstat(directory)
        if parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) != 0o700:
            raise ValueError()
        descriptor = os.open(target.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or not 1 <= info.st_size <= 16384):
            raise ValueError()
        raw = bytearray()
        while len(raw) <= 16384:
            block = os.read(descriptor, min(4096, 16385 - len(raw)))
            if not block:
                break
            raw.extend(block)
        if len(raw) > 16384:
            raise ValueError()
        data = json.loads(raw, object_pairs_hook=unique_object)
        if (set(data) != {'version', 'readers'} or type(data['version']) is not int or data['version'] != 1
                or set(data['readers']) != {'qbo', 'google', 'push'}):
            raise ValueError()
        settings = {domain: json.dumps(value, separators=(',', ':')) for domain, value in data['readers'].items()}
        for domain, configuration in settings.items():
            StorageKeyring(domain, legacy_keys[domain], configuration)
        return settings
    except Exception:
        raise ValueError('Protected storage keyring file is invalid or unavailable') from None
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if directory is not None:
            os.close(directory)
