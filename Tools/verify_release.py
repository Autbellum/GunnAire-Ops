#!/usr/bin/env python3
"""One fail-closed, commit-bound source verification and portable package path.

Automated source verification never confers deployment or physical acceptance.
Run with the project QA virtual environment; PyYAML is a verification dependency.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'LocalAI'))
from local_ai import load_policy, scrub_environment
from qa_runner import run_command

VERSION = '2026.09.12.1'
REQUIRED = ('PRODUCTION_CLOSEOUT.md', 'PRODUCTION_ACCEPTANCE.md', 'ROLLBACK_RUNBOOK.md',
            'Synology/DSM_SECURITY_LOGGING_PREP.md', 'Firewall/setup_local_reporting.sh',
            'DEPLOYMENT_EVIDENCE/acceptance-register.json')


def git(*args: str) -> bytes:
    return subprocess.check_output(['git', *args], cwd=ROOT)


def safe_relative(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(path.parts) and path.as_posix() == name and not path.is_absolute() and '..' not in path.parts and '\\' not in name and '\n' not in name


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_unchanged(commit: str) -> bool:
    return git('rev-parse', 'HEAD').decode().strip() == commit and not git('status', '--porcelain').strip()


def source_checks(files: dict[str, bytes]) -> list[str]:
    try:
        import yaml
    except ImportError:
        yaml = None
    problems = []
    for required in REQUIRED:
        if required not in files:
            problems.append(f'missing required component: {required}')
    for name, data in files.items():
        if not safe_relative(name):
            problems.append(f'unsafe archive path: {name!r}')
            continue
        try:
            if name.endswith('.py'):
                compile(data, name, 'exec')
            elif name.endswith('.json'):
                json.loads(data)
            elif name.endswith(('.plist', '.plist.template', '.entitlements', '.xcprivacy')):
                plistlib.loads(data)
            elif name.endswith(('.yaml', '.yml')):
                if yaml is not None:
                    yaml.safe_load(data)
                else:
                    subprocess.run(['/usr/bin/ruby', '-rpsych', '-e', 'Psych.parse_stream(STDIN.read)'],
                                   input=data, capture_output=True, check=True, timeout=10)
        except Exception as exc:
            problems.append(f'{name}: {type(exc).__name__}: {exc}')
        # Explicit, narrow synthetic fixtures are excluded, never all test directories.
        text = data.decode('utf-8', errors='replace')
        for number, line in enumerate(text.splitlines(), 1):
            if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bgh[pousr]_[A-Za-z0-9]{30,}|\bsk-(?:proj-)?[A-Za-z0-9_-]{40,}', line):
                if not (name.startswith(('Backend/test_', 'LocalAI/tests/', 'Firewall/tests/')) and 'synthetic' in line.lower()):
                    problems.append(f'{name}:{number}: potential embedded credential (value omitted)')
    return problems


def package(files: dict[str, bytes], manifest: dict, destination: Path) -> tuple[str, str]:
    payload = dict(files)
    payload['RELEASE_MANIFEST.json'] = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    sums = {name: digest(data) for name, data in sorted(payload.items())}
    payload['SHA256SUMS'] = ''.join(f'{value}  {name}\n' for name, value in sums.items()).encode()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, 'x', zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(payload.items()):
            if not safe_relative(name):
                raise ValueError('Unsafe package path')
            info = zipfile.ZipInfo(name, (2026, 9, 12, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (0o100755 if name.endswith('.sh') else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
    with zipfile.ZipFile(destination) as archive:
        if set(archive.namelist()) != set(payload):
            raise ValueError('Package membership mismatch')
        for name, expected in sums.items():
            if digest(archive.read(name)) != expected:
                raise ValueError(f'Checksum mismatch: {name}')
        recorded = json.loads(archive.read('RELEASE_MANIFEST.json'))
        if not re.fullmatch(r'[0-9a-f]{40}', recorded['commit']) or recorded['version'] != VERSION:
            raise ValueError('Invalid release manifest identity')
    return destination.name, digest(destination.read_bytes())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-destination', help='Explicit test destination; required for an accepted native test run')
    args = parser.parse_args()
    commit = git('rev-parse', 'HEAD').decode().strip()
    branch = git('branch', '--show-current').decode().strip()
    if git('status', '--porcelain').strip():
        print('Refusing to label uncommitted source as a commit-bound release.', file=sys.stderr)
        return 2
    archived = git('archive', '--format=zip', commit)
    with zipfile.ZipFile(io.BytesIO(archived)) as archive:
        files = {name: archive.read(name) for name in archive.namelist() if not name.endswith('/')}
    output = Path(tempfile.mkdtemp(prefix=f'closeout-{VERSION}-', dir=ROOT / 'dist'))
    manifest = {'schema_version': 1, 'version': VERSION, 'commit': commit, 'branch': branch,
                'created_at': dt.datetime.now(dt.timezone.utc).isoformat(),
                'status': 'PARTIALLY DEPLOYED', 'tests': [], 'package': None,
                'acceptance_reference': 'PRODUCTION_ACCEPTANCE.md',
                'deployment_evidence': sorted(p for p in files if p.startswith('DEPLOYMENT_EVIDENCE/'))}
    problems = source_checks(files)
    try:
        acceptance = json.loads(files['DEPLOYMENT_EVIDENCE/acceptance-register.json'])
        for key in ('targets', 'prerequisites', 'unresolved_blockers'):
            if not isinstance(acceptance[key], list) or not acceptance[key]:
                raise ValueError(f'Nonempty {key} required')
        manifest['actual_deployment_state'] = acceptance['targets']
        manifest['deployment_prerequisites'] = acceptance['prerequisites']
        manifest['unresolved_blockers'] = acceptance['unresolved_blockers']
    except (KeyError, ValueError, TypeError) as exc:
        problems.append(f'Invalid acceptance register: {exc}')
    manifest['source_check_errors'] = problems
    env = scrub_environment(os.environ, load_policy())
    env.update(PYTHONDONTWRITEBYTECODE='1', GUNNAIRE_TEST_MODE='1',
               GUNNAIRE_ALLOW_PROVIDER_WRITES='0', GUNNAIRE_ALLOW_PRODUCTION_NETWORK='0')
    commands = [(f'{scope}-tests', [sys.executable, '-m', 'unittest', 'discover', '-s', scope, '-p', 'test_*.py', '-q'], 1800)
                for scope in ('LocalAI/tests', 'Firewall/tests', 'Tools', 'Backend')]
    commands += [('routing-audit', [sys.executable, 'LocalAI/audit_ai_routing.py', '--root', '.', '--strict'], 180),
                 ('firewall-validation', [sys.executable, 'Firewall/validate_plan.py'], 180),
                 ('generated-freshness', ['make', 'checklist-check'], 180),
                 ('swift-logic', ['swift', 'test', '--package-path', 'LoadSight'], 1800)]
    commands += [('shell-' + name, ['bash', '-n', name], 30) for name in files if name.endswith('.sh')]
    if args.native_destination:
        commands.append(('native-app-logic', ['xcodebuild', '-project', 'GunnAire Ops.xcodeproj', '-scheme', 'GunnAire Ops',
                         '-destination', args.native_destination, '-derivedDataPath', str(output / 'native'),
                         '-resultBundlePath', str(output / 'native.xcresult'), '-only-testing:GunnAire OpsTests',
                         '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=NO', 'test'], 5400))
    else:
        problems.append('Native app tests require an explicit --native-destination; no silent skip allowed')
    for index, (scope, command, timeout) in enumerate(commands):
        print(f'Checking {scope}', flush=True)
        if scope == 'Backend-tests' and sys.platform == 'darwin':
            command = ['/usr/bin/sandbox-exec', '-p',
                       '(version 1)(allow default)(deny network*)(allow network-inbound (local tcp "localhost:*"))(allow network-outbound (remote tcp "localhost:*"))',
                       *command]
        result = run_command(command, cwd=ROOT, timeout_seconds=timeout, environment=env)
        result['command'] = [str(value).replace(str(output), '<release-output>').replace(str(ROOT), '<repository>') for value in result['command']]
        log = f'{index:02d}.log'
        (output / log).write_text(result.pop('output'), encoding='utf-8')
        manifest['tests'].append({'scope': scope, 'log': log, **result})
        if scope == 'native-app-logic' and result['passed']:
            try:
                raw = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                               '--path', str(output / 'native.xcresult')], timeout=60)
                summary = json.loads(raw)
                (output / 'native-summary.json').write_bytes(raw)
                if summary.get('result') != 'Passed' or summary.get('failedTests') != 0 or summary.get('passedTests', 0) <= 0 or summary.get('skippedTests') != 0:
                    problems.append('Native result did not prove a nonempty, unskipped passing run')
            except (OSError, subprocess.SubprocessError, ValueError) as exc:
                problems.append(f'Native evidence extraction failed: {type(exc).__name__}')
    if not source_unchanged(commit):
        problems.append('Source changed during verification; no commit-bound package may be issued')
    manifest['automated_checks_passed'] = not problems and all(r['passed'] for r in manifest['tests'])
    if manifest['automated_checks_passed']:
        name, sha = package(files, manifest, output / f'GunnAire-{VERSION}.zip')
        manifest['package'] = {'name': name, 'sha256': sha}
        (output / 'PACKAGE_SHA256SUMS').write_text(f'{sha}  {name}\n')
    (output / 'RELEASE_MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(output / 'RELEASE_MANIFEST.json')
    return 0 if manifest['automated_checks_passed'] else 1


if __name__ == '__main__':
    (ROOT / 'dist').mkdir(exist_ok=True)
    raise SystemExit(main())
