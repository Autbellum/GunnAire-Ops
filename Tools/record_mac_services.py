#!/usr/bin/env python3
"""Record allowlisted, read-only local deployment facts, never tokens or environment."""
import datetime as dt
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def main():
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                         urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    def get(url):
        with opener.open(url, timeout=10) as response:
            return json.load(response)
    with opener.open('http://127.0.0.1:11436/', timeout=10) as response:
        workbench_http = response.status
    state = get('http://127.0.0.1:11436/api/state')
    tags = get('http://127.0.0.1:11434/api/tags')
    services = []
    for label in ('com.gunnaire.local-ai-workbench', 'com.gunnaire.synology-local-ai', 'com.gunnaire.localai.health'):
        raw = subprocess.run(['launchctl', 'print', f'gui/{os.getuid()}/{label}'], capture_output=True, text=True)
        facts = [line.strip() for line in raw.stdout.splitlines()
                 if line.strip().startswith(('state =', 'program =', 'last exit code =', 'runs ='))]
        plist = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
        services.append({'label': label, 'launchctl_exit': raw.returncode, 'facts': facts,
                         'plist_sha256': hashlib.sha256(plist.read_bytes()).hexdigest()})
    listeners = subprocess.run(['/usr/sbin/lsof', '-nP', '-iTCP:11434', '-sTCP:LISTEN', '-Fn'], capture_output=True, text=True)
    doctor = json.loads((Path.home() / 'Library/Logs/GunnAireLocalAI/doctor-scheduled.json').read_text())
    evidence = {
        'schema_version': 1, 'observed_at': dt.datetime.now(dt.timezone.utc).isoformat(),
        'status': 'PARTIALLY DEPLOYED', 'services': services, 'scheduled_health': doctor,
        'ollama_version': get('http://127.0.0.1:11434/api/version')['version'],
        'models': [{k: model[k] for k in ('name', 'digest', 'size', 'modified_at')} for model in tags['models']],
        'ollama_listeners': [line[1:] for line in listeners.stdout.splitlines() if line.startswith('n')],
        'model_storage': str((Path.home() / '.ollama/models').resolve()),
        'workbench_http': workbench_http, 'workbench_idle': all(state.get(k) is None for k in ('active', 'maintenance', 'release_active')),
        'service_restart_tested': True, 'reboot_tested': False,
        'rollback_directory': str(Path.home() / '.gunnaire-local-ai/service-rollback-20260912.Cymefu'),
        'model_role_selection': 'Measured advisory candidates: Devstral coder, GPT-OSS independent reviewer, Qwen3 challenger, Qwen2.5 fast triage. Heuristic scores do not qualify autonomous production decisions.',
        'benchmark_caution': 'Generated tests and suggested commands in model responses are proposals, not executed evidence. No suggested security command was applied.'
    }
    target = ROOT / 'DEPLOYMENT_EVIDENCE/mac-services.json'
    target.write_text(json.dumps(evidence, indent=2) + '\n')
    print(target)
    return 0 if doctor['status'] == 'ok' and workbench_http == 200 and all(s['launchctl_exit'] == 0 for s in services) else 1


if __name__ == '__main__':
    raise SystemExit(main())
