#!/usr/bin/env python3
"""Exercise a real synthetic file backup/restore; never claim snapshot recovery."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--share', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    share = args.share.resolve(strict=True)
    if not share.is_mount():
        raise SystemExit('The backup target must be an existing mounted share')
    run_id = str(uuid.uuid4())
    destination = share / 'ReleaseEvidence' / 'restore-tests' / run_id
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    data = ('GunnAire synthetic restore acceptance; no customer records.\n' + run_id + '\n').encode()
    expected = hashlib.sha256(data).hexdigest()
    with tempfile.TemporaryDirectory(prefix='gunnaire-restore-') as temporary:
        source = Path(temporary) / 'synthetic.txt'
        source.write_bytes(data)
        source.chmod(0o600)
        backup = destination / 'synthetic.txt'
        shutil.copyfile(source, backup)
        if hashlib.sha256(backup.read_bytes()).hexdigest() != expected:
            raise SystemExit('NAS backup hash mismatch')
        source.unlink()  # Only this newly created synthetic source is removed.
        restored = Path(temporary) / 'restored.txt'
        shutil.copyfile(backup, restored)
        actual = hashlib.sha256(restored.read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit('Restored file hash mismatch')
    report = {'schema_version': 1, 'observed_at': dt.datetime.now(dt.timezone.utc).isoformat(),
              'run_id': run_id, 'target': str(share), 'backup': str(backup.relative_to(share)),
              'expected_sha256': expected, 'restored_sha256': actual,
              'file_backup_restore_passed': True, 'snapshot_restore_tested': False,
              'configuration_restore_tested': False, 'off_nas_backup_tested': False,
              'scope': 'Synthetic file copied to mounted NAS, original removed, copied back and verified'}
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps(report, indent=2) + '\n')
    (destination / 'restore-evidence.json').write_text(json.dumps(report, indent=2) + '\n')
    print(args.evidence)


if __name__ == '__main__':
    main()
