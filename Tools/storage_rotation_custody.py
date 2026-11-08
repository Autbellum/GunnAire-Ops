"""Protected local custody primitive. No CLI, network or secret-bearing output.

Call only with an already-approved private nonsynchronized parent directory.
Values are supplied in memory; never use command arguments or logging for them.
This prepares custody, not a Render/provider transfer or credential rotation.
"""
import json
import os
import stat
from cryptography.fernet import Fernet


def prepare(parent, name, old_keys):
    """Create a new 0700 directory and 0600 bundle without overwrite/symlink use.

    Retain old material for backup recovery. Prepared reader settings keep old
    writes; activation is separate. Return only a fixed nonsecret status.
    """
    descriptor = destination = file_descriptor = None
    try:
        if (not isinstance(name,str) or not name or name in ('.','..')
                or '/' in name or set(old_keys) != {'qbo','google','push'}):
            raise ValueError()
        # Traverse every component with O_NOFOLLOW, not just the final parent.
        parts=os.path.abspath(parent).split(os.sep)
        descriptor=os.open(os.sep,os.O_RDONLY|os.O_DIRECTORY)
        for part in parts:
            if not part:continue
            next_descriptor=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=descriptor)
            os.close(descriptor);descriptor=next_descriptor
        info=os.fstat(descriptor)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError()
        for value in old_keys.values():Fernet(value.encode('ascii'))
        os.mkdir(name,0o700,dir_fd=descriptor)
        destination=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=descriptor)
        os.fchmod(destination,0o700)
        bundle={'version':1,'readers':{}}
        for domain,old in old_keys.items():
            bundle['readers'][domain]={'version':1,'active':'old','write_format':'legacy',
                'keys':{'old':old,'new':Fernet.generate_key().decode('ascii')}}
        file_descriptor=os.open('custody.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=destination)
        os.fchmod(file_descriptor,0o600)
        data=json.dumps(bundle,separators=(',',':')).encode('ascii')
        offset=0
        while offset<len(data):offset+=os.write(file_descriptor,data[offset:])
        os.fsync(file_descriptor)
        os.fsync(destination)
        os.fsync(descriptor)
        return {'custody_prepared':True,'live_credentials_changed':False}
    except Exception:
        # Never echo exception arguments, key material, paths, or input.
        # A partial private directory is retained for explicit recovery review.
        raise ValueError('Protected custody preparation failed; no live credentials changed') from None
    finally:
        for fd in (file_descriptor,destination,descriptor):
            if fd is not None:os.close(fd)


def install_readers(parent, name, bundle, live_keys):
    """Install a new reader-only bundle in a newly created private directory.

    Never overwrite a prior installation or generate keys. Caller supplies the
    running process's keys in memory and owns secure stdin/SSH transport. This
    does not alter process settings or activate new writes. Partial installation
    is retained on failure for explicit inspection, not silently retried.
    """
    directory = child = descriptor = None
    try:
        if (not isinstance(name, str) or not name or name in ('.', '..') or '/' in name
                or set(bundle) != {'version', 'readers'} or type(bundle['version']) is not int
                or bundle['version'] != 1 or set(bundle['readers']) != {'qbo', 'google', 'push'}
                or set(live_keys) != {'qbo', 'google', 'push'}):
            raise ValueError()
        for domain, settings in bundle['readers'].items():
            if (set(settings) != {'version', 'active', 'write_format', 'keys'}
                    or type(settings['version']) is not int or settings['version'] != 1
                    or settings['active'] != 'old' or settings['write_format'] != 'legacy'
                    or set(settings['keys']) != {'old', 'new'}
                    or settings['keys']['old'] != live_keys[domain]
                    or settings['keys']['old'] == settings['keys']['new']):
                raise ValueError()
            for value in settings['keys'].values(): Fernet(value.encode('ascii'))
        data = json.dumps(bundle, separators=(',', ':')).encode('ascii')
        if len(data) > 16384: raise ValueError()
        parts = os.path.abspath(parent).split(os.sep)
        directory = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY)
        for part in parts:
            if not part: continue
            next_descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory); directory = next_descriptor
        info = os.fstat(directory)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o022:
            raise ValueError()
        os.mkdir(name, 0o700, dir_fd=directory)
        child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
        os.fchmod(child, 0o700)
        descriptor = os.open('readers.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=child)
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(data): offset += os.write(descriptor, data[offset:])
        os.fsync(descriptor); os.fsync(child); os.fsync(directory)
        return {'reader_file_installed': True, 'old_keys_match_running_process': True,
                'process_settings_changed': False, 'new_writes_activated': False}
    except Exception:
        raise ValueError('Protected reader installation failed; inspect private destination before retry') from None
    finally:
        for fd in (descriptor, child, directory):
            if fd is not None: os.close(fd)
