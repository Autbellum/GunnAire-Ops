#!/usr/bin/env python3
"""Create a local, reviewable source overlay without staging or publishing files."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCOPES = ('LoadSight/', 'Plugins/gunnaire-ops/')
EXACT = ('.github/workflows/loadsight-regression.yml',)


def source_paths():
    raw = subprocess.check_output(['git', 'ls-files', '--cached', '--others',
                                   '--exclude-standard', '-z'], cwd=ROOT)
    paths = sorted(set(p for p in raw.decode().split('\0') if p and
                       (p.startswith(SCOPES) or p in EXACT)))
    for name in paths:
        path = ROOT / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'Source must be a regular file: {name}')
        if any(part in {'.git', '.build', '.swiftpm', 'output', '__pycache__',
                        'xcuserdata', 'tmp', 'node_modules'} or part.endswith('.xcresult')
               for part in pathlib.PurePosixPath(name).parts):
            raise ValueError(f'Generated or personal file selected: {name}')
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--reviewed-base', required=True,
                        help='Exact GitHub commit reviewed; recorded, not fetched or merged')
    args = parser.parse_args()
    if len(args.reviewed_base) != 40 or any(c not in '0123456789abcdef' for c in args.reviewed_base):
        parser.error('--reviewed-base must be a full lowercase Git commit hash')
    output = args.output.resolve()
    if args.output.exists() or args.output.is_symlink():
        parser.error('output already exists')
    if any(output.is_relative_to(ROOT / scope) for scope in SCOPES):
        parser.error('output must be outside the packaged source directories')
    paths = source_paths()
    if not paths:
        parser.error('no source files found')
    manifest = {'schemaVersion': 1, 'reviewedGitHubBase': args.reviewed_base,
                'localHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip(),
                'scope': 'Standalone LoadSight app, SDK, CLI, plugin and their CI; Ops host edits excluded',
                'files': []}
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryFile() as temporary:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name in paths:
                path = ROOT / name
                data = path.read_bytes()
                mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (0o100000 | mode) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, data)
                manifest['files'].append({'path': name, 'bytes': len(data),
                    'sha256': hashlib.sha256(data).hexdigest(), 'mode': oct(mode)})
            # Refuse a source snapshot changed while it was being captured.
            if source_paths() != paths or any(hashlib.sha256((ROOT / entry['path']).read_bytes()).hexdigest()
                    != entry['sha256'] for entry in manifest['files']):
                raise RuntimeError('Sources changed during capture; rerun to capture a consistent snapshot')
            archive.writestr('GITHUB_SOURCE_MANIFEST.json', json.dumps(manifest, indent=2) + '\n')
        temporary.seek(0)
        with output.open('xb') as destination:
            while chunk := temporary.read(1024 * 1024):
                destination.write(chunk)
    print(json.dumps({'archive': str(output), 'files': len(paths),
                      'sha256': hashlib.sha256(output.read_bytes()).hexdigest()}, indent=2))


if __name__ == '__main__':
    main()
