"""Staged authenticated storage-key rotation; no key material in diagnostics."""
from __future__ import annotations
import base64
import hashlib
import hmac
import json
import re
import secrets
from cryptography.fernet import Fernet, InvalidToken

PREFIX = b'\x00gunnaire-keyring-v1\x00'

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
            if not clear.startswith(PREFIX):
                return clear, hashlib.sha256(token).hexdigest(), identifier, False
            try:
                value = json.loads(clear[len(PREFIX):], object_pairs_hook=unique_object)
                if (set(value) != {'v', 'domain', 'key_id', 'revision', 'data'} or type(value['v']) is not int or value['v'] != 1
                        or value['domain'] != self.domain or value['key_id'] != identifier
                        or not isinstance(value['revision'], str)
                        or not re.fullmatch('[0-9a-f]{64}', value['revision'])):
                    raise ValueError()
                raw = base64.b64decode(value['data'], validate=True)
                return raw, value['revision'], identifier, True
            except Exception:
                raise InvalidToken() from None
        raise InvalidToken()

    def decrypt(self, token: bytes) -> bytes:
        return self._open(token)[0]

    def revision(self, token: bytes) -> str:
        return self._open(token)[1]

    def _seal(self, raw: bytes, revision: str) -> bytes:
        value = {'v': 1, 'domain': self.domain, 'key_id': self.active,
                 'revision': revision, 'data': base64.b64encode(raw).decode('ascii')}
        return self.keys[self.active].encrypt(PREFIX + json.dumps(value, separators=(',', ':'), sort_keys=True).encode())

    def encrypt(self, raw: bytes) -> bytes:
        if not isinstance(raw, bytes):
            raise TypeError('Storage plaintext must be bytes')
        if not self.versioned_writes:
            return self.keys[self.active].encrypt(raw)
        return self._seal(raw, secrets.token_hex(32))

    def rotate(self, token: bytes) -> bytes:
        if not self.versioned_writes:
            raise KeyringError()  # No migration before writer activation.
        raw, revision, identifier, versioned = self._open(token)
        if versioned and identifier == self.active:
            return token
        return self._seal(raw, revision)

    def uses_active_envelope(self, token: bytes) -> bool:
        _, _, identifier, versioned = self._open(token)
        return versioned and identifier == self.active

    def fingerprint(self, data: bytes) -> str:
        return hmac.new(self.material[self.active], data, hashlib.sha256).hexdigest()

    def accepts_fingerprint(self, data: bytes, expected: str) -> bool:
        return isinstance(expected, str) and any(hmac.compare_digest(expected,
            hmac.new(material, data, hashlib.sha256).hexdigest()) for material in self.material.values())
