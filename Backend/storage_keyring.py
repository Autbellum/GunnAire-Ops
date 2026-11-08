"""Staged authenticated storage-key rotation; no key material in diagnostics."""
from __future__ import annotations
import base64
import hashlib
import hmac
import json
import re
import secrets
import threading
from concurrent.futures import ThreadPoolExecutor
from functools import wraps
from cryptography.fernet import Fernet, InvalidToken

PREFIX = b'\x00gunnaire-keyring-v1\x00'
BINARY_PREFIX = b'\x00gunnaire-keyring-v2\x00'
# JSON/base64/Fernet temporarily hold several copies. Bound allocation across
# all independently constructed keyrings and domains, without rejecting writes.
# No database/provider work is performed while holding this slot.
ALLOCATION_SLOT = threading.BoundedSemaphore(1)
_ALLOCATION_WORKER = ThreadPoolExecutor(max_workers=1, thread_name_prefix='storage-crypto')


def allocated(operation):
    """Use one allocator thread as well as one operation at a time.

    A semaphore alone permits every caller thread to retain its own allocator
    arena after a large temporary allocation. Admission precedes submission, so
    there is at most one queued/running crypto operation, not an unbounded queue.
    Caller-owned inputs/results and their original lifetime remain unchanged.
    """
    @wraps(operation)
    def bounded(*args, **kwargs):
        with ALLOCATION_SLOT:
            return _ALLOCATION_WORKER.submit(operation, *args, **kwargs).result()
    return bounded

def unique_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError()
        result[name] = value
    return result

class KeyringError(ValueError):
    def __init__(self):
        super().__init__('Storage keyring is invalid or unavailable')

class StorageKeyring:
    def __init__(self, domain: str, legacy_key: str, configuration: str = ''):
        self.domain = domain
        self.versioned_writes = False
        try:
            if not configuration:
                self.active = 'legacy'
                self.keys = {'legacy': Fernet(legacy_key.encode('ascii'))}
                self.material = {'legacy': base64.urlsafe_b64decode(legacy_key)}
                return
            data = json.loads(configuration, object_pairs_hook=unique_object)
            if (set(data) != {'version', 'active', 'write_format', 'keys'} or type(data['version']) is not int or data['version'] != 1
                    or data['write_format'] not in ('legacy', 'versioned')
                    or not isinstance(data['keys'], dict) or not 1 <= len(data['keys']) <= 3
                    or any(not isinstance(k, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,40}', k) for k in data['keys'])
                    or data['active'] not in data['keys']):
                raise ValueError()
            if data['write_format'] == 'legacy' and data['keys'][data['active']] != legacy_key:
                raise ValueError()  # Reader-rollout phase must retain the existing writer.
            self.active = data['active']
            self.keys = {k: Fernet(v.encode('ascii')) for k, v in data['keys'].items()}
            self.material = {k: base64.urlsafe_b64decode(v) for k,v in data['keys'].items()}
            if len(set(self.material.values())) != len(self.material):
                raise ValueError()
            self.versioned_writes = data['write_format'] == 'versioned'
        except Exception:
            raise KeyringError() from None

    def _open(self, token: bytes):
        if not isinstance(token, bytes):
            raise InvalidToken()
        for identifier, key in self.keys.items():
            try:
                clear = key.decrypt(token)
            except InvalidToken:
                continue
            binary = clear.startswith(BINARY_PREFIX)
            if not binary and not clear.startswith(PREFIX):
                return clear, hashlib.sha256(token).hexdigest(), identifier, False
            try:
                if binary:
                    offset = len(BINARY_PREFIX)
                    size = int.from_bytes(clear[offset:offset + 4], 'big')
                    if not 1 <= size <= 1024 or len(clear) < offset + 4 + size:
                        raise ValueError()
                    end = offset + 4 + size
                    value = json.loads(clear[offset + 4:end], object_pairs_hook=unique_object)
                    expected = {'v', 'domain', 'key_id', 'revision'}
                else:
                    value = json.loads(clear[len(PREFIX):], object_pairs_hook=unique_object)
                    expected = {'v', 'domain', 'key_id', 'revision', 'data'}
                if (set(value) != expected or type(value['v']) is not int or value['v'] != (2 if binary else 1)
                        or value['domain'] != self.domain or value['key_id'] != identifier
                        or not isinstance(value['revision'], str)
                        or not re.fullmatch('[0-9a-f]{64}', value['revision'])):
                    raise ValueError()
                raw = clear[end:] if binary else base64.b64decode(value['data'], validate=True)
                return raw, value['revision'], identifier, True
            except Exception:
                raise InvalidToken() from None
        raise InvalidToken()

    @allocated
    def decrypt(self, token: bytes) -> bytes:
        return self._open(token)[0]

    @allocated
    def encrypt_text(self, text: str, encoding: str = 'utf-8') -> str:
        raw = text.encode(encoding)
        token = (self._seal(raw, secrets.token_hex(32)) if self.versioned_writes
                 else self.keys[self.active].encrypt(raw))
        return token.decode('ascii')

    @allocated
    def decrypt_text(self, text: str, encoding: str = 'utf-8') -> str:
        return self._open(text.encode('ascii'))[0].decode(encoding)

    @allocated
    def revision_text(self, text: str) -> str:
        return self._open(text.encode('ascii'))[1]

    @allocated
    def rotate_text(self, text: str) -> str:
        if not self.versioned_writes:
            raise KeyringError()
        token = text.encode('ascii')
        raw, revision, identifier, versioned = self._open(token)
        if versioned and identifier == self.active:
            return text
        return self._seal(raw, revision).decode('ascii')

    @allocated
    def revision(self, token: bytes) -> str:
        return self._open(token)[1]

    def _seal(self, raw: bytes, revision: str) -> bytes:
        # Authenticate the small metadata header and raw payload together.
        # Avoid nested base64: Fernet already supplies the transport encoding.
        value = {'v': 2, 'domain': self.domain, 'key_id': self.active, 'revision': revision}
        header = json.dumps(value, separators=(',', ':'), sort_keys=True).encode()
        if len(header) > 1024:
            raise KeyringError()
        return self.keys[self.active].encrypt(BINARY_PREFIX + len(header).to_bytes(4, 'big') + header + raw)

    @allocated
    def encrypt(self, raw: bytes) -> bytes:
        if not isinstance(raw, bytes):
            raise TypeError('Storage plaintext must be bytes')
        if not self.versioned_writes:
            return self.keys[self.active].encrypt(raw)
        return self._seal(raw, secrets.token_hex(32))

    @allocated
    def rotate(self, token: bytes) -> bytes:
        if not self.versioned_writes:
            raise KeyringError()  # No migration before writer activation.
        raw, revision, identifier, versioned = self._open(token)
        if versioned and identifier == self.active:
            return token
        return self._seal(raw, revision)

    @allocated
    def uses_active_envelope(self, token: bytes) -> bool:
        _, _, identifier, versioned = self._open(token)
        return versioned and identifier == self.active

    def fingerprint(self, data: bytes) -> str:
        return hmac.new(self.material[self.active], data, hashlib.sha256).hexdigest()

    def accepts_fingerprint(self, data: bytes, expected: str) -> bool:
        return isinstance(expected, str) and any(hmac.compare_digest(expected,
            hmac.new(material, data, hashlib.sha256).hexdigest()) for material in self.material.values())
