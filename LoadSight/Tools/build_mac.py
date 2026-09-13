#!/usr/bin/env python3
"""Build a local LoadSight app bundle without changing signing or release settings."""
import pathlib
import plistlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
scratch = pathlib.Path('/tmp/gunnaire-loadsight-build')
subprocess.run(['swift', 'build', '--package-path', str(root), '--scratch-path', str(scratch), '--product', 'LoadSightDesktop'], check=True)
binary_dir = subprocess.check_output(['swift', 'build', '--package-path', str(root), '--scratch-path', str(scratch), '--show-bin-path'], text=True).strip()
app = root / 'output/LoadSight.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True, exist_ok=True)
shutil.copy2(pathlib.Path(binary_dir) / 'LoadSightDesktop', macos / 'LoadSight')
info = {
    'CFBundleIdentifier': 'com.gunnaire.loadsight.local',
    'CFBundleName': 'LoadSight', 'CFBundleDisplayName': 'LoadSight',
    'CFBundleExecutable': 'LoadSight', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '14.0', 'NSHighResolutionCapable': True,
    'CFBundleDocumentTypes': [
        {'CFBundleTypeName': 'LoadSight Project', 'CFBundleTypeRole': 'Editor', 'LSHandlerRank': 'Owner',
         'LSItemContentTypes': ['com.gunnaire.loadsight.project']},
        {'CFBundleTypeName': 'LoadSight Project JSON', 'CFBundleTypeRole': 'Editor',
         'LSHandlerRank': 'Alternate', 'LSItemContentTypes': ['public.json']}],
    'UTExportedTypeDeclarations': [{'UTTypeIdentifier': 'com.gunnaire.loadsight.project',
        'UTTypeDescription': 'LoadSight Project', 'UTTypeConformsTo': ['com.apple.package'],
        'UTTypeTagSpecification': {'public.filename-extension': ['loadsight']}}],
}
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(info, f)
print(app)
