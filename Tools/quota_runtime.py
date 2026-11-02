"""Ephemeral CI-only cgroup launcher; no production data or credentials."""
from pathlib import Path
import os
import platform
import subprocess
import sys
import time
import uuid

MEMORY_MAX = 512_000_000
HEADROOM_MAX = 409_600_000


def parse_pairs(text):
    return {key: int(value) for key, value in (line.split() for line in text.splitlines())}


def read_cgroup(path):
    quota, period = (path / 'cpu.max').read_text().split()
    limits = {
        'memoryMax': int((path / 'memory.max').read_text()),
        'swapMax': int((path / 'memory.swap.max').read_text()),
        'cpuQuota': int(quota), 'cpuPeriod': int(period),
    }
    if (limits['memoryMax'] != MEMORY_MAX or limits['swapMax'] != 0
            or limits['cpuPeriod'] <= 0 or limits['cpuQuota'] * 2 != limits['cpuPeriod']):
        raise RuntimeError('Kernel cgroup limits do not match the required quota')
    current = int((path / 'memory.current').read_text())
    peak = int((path / 'memory.peak').read_text())
    events = parse_pairs((path / 'memory.events').read_text())
    statistics = parse_pairs((path / 'memory.stat').read_text())
    if not {'anon', 'file', 'kernel'}.issubset(statistics) or any(value < 0 for value in statistics.values()):
        raise RuntimeError('Incomplete kernel memory breakdown')
    if (current < 0 or peak < current or not {'oom', 'oom_kill'}.issubset(events)
            or any(value < 0 for value in events.values())):
        raise RuntimeError('Invalid or incomplete kernel memory telemetry')
    return dict(limits, current=current, peak=peak, events=events, statistics=statistics)



def validate_ci_environment(environ, system):
    if (system != 'Linux' or environ.get('GITHUB_ACTIONS') != 'true'
            or environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'
            or environ.get('GITHUB_REPOSITORY') != 'Autbellum/GunnAire-Ops'
            or environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'
            or not environ.get('GITHUB_REF', '').startswith('refs/heads/validation/linux-quota-')):
        raise RuntimeError('Quota execution requires the approved isolated GitHub-hosted manual workflow')


def launch_command(unit, cwd, env, uid):
    return ['sudo', '-n', 'systemd-run', '--unit=' + unit, '--wait', '--pipe',
            '--service-type=exec', '--uid=' + str(uid), '--working-directory=' + str(cwd),
            '--property=MemoryAccounting=yes', '--property=MemoryMax=' + str(MEMORY_MAX),
            '--property=MemorySwapMax=0', '--property=CPUQuota=50%',
            '--property=KillMode=control-group', '--property=TimeoutStopSec=10',
            '/usr/bin/env', '-i', *[key + '=' + value for key, value in sorted(env.items())],
            sys.executable, 'gunnaire_backend.py']


class Runtime:
    def __init__(self, cwd, env, log, local=False):
        self.local = local
        self.cwd = Path(cwd).resolve()
        self.unit = None
        self.cgroup = None
        if local:
            self.process = subprocess.Popen([sys.executable, 'gunnaire_backend.py'],
                                            cwd=cwd, env=env, stdout=log, stderr=log)
        else:
            validate_ci_environment(os.environ, platform.system())
            if os.getuid() == 0:
                raise RuntimeError('Backend must run as an unprivileged hosted-runner user')
            if sys.version_info[:3] != (3, 14, 3):
                raise RuntimeError('Quota run requires production-compatible Python 3.14.3')
            if not Path('/sys/fs/cgroup/cgroup.controllers').is_file():
                raise RuntimeError('cgroup v2 unavailable; no unconstrained fallback')
            self.unit = 'gunnaire-quota-' + uuid.uuid4().hex + '.service'
            self.process = subprocess.Popen(launch_command(self.unit, cwd, env, os.getuid()),
                                            stdout=log, stderr=log)

    def poll(self):
        return self.process.poll()

    def attach(self):
        if self.local:
            return
        name = subprocess.check_output(['systemctl', 'show', self.unit,
                                        '--property=ControlGroup', '--value'], text=True).strip()
        expected = '/system.slice/' + self.unit
        if name != expected:
            raise RuntimeError('Unexpected or unavailable service cgroup')
        self.cgroup = Path('/sys/fs/cgroup') / name.lstrip('/')
        read_cgroup(self.cgroup)  # Verify actual kernel limits, not command intent.
        self.pid = int(subprocess.check_output(['systemctl', 'show', self.unit,
                                               '--property=MainPID', '--value'], text=True))
        if self.pid > 0 and (Path(f'/proc/{self.pid}/cwd').resolve() != self.cwd
                or Path(f'/proc/{self.pid}/cmdline').read_bytes().split(b'\0')[:-1]
                != [sys.executable.encode(), b'gunnaire_backend.py']):
            raise RuntimeError('Service does not execute the exact candidate entrypoint')
        if self.pid <= 0 or f'0::{name}' not in Path(f'/proc/{self.pid}/cgroup').read_text().splitlines():
            raise RuntimeError('Backend is not in the verified service cgroup')
        if f'0::{name}' in Path('/proc/self/cgroup').read_text().splitlines():
            raise RuntimeError('Workload client must remain outside the server cgroup')

    def sample(self):
        if self.local:
            rss = int(subprocess.check_output(['ps', '-o', 'rss=', '-p',
                                               str(self.process.pid)], text=True).strip()) * 1024
            return {'current': rss, 'peak': rss, 'events': {}}
        return read_cgroup(self.cgroup)

    def status(self):
        if self.local:
            return {'processReturnCode': self.poll()}
        result = subprocess.run(['systemctl', 'show', self.unit, '--property=Result',
                                 '--property=ExecMainCode', '--property=ExecMainStatus',
                                 '--property=MemoryPeak'], capture_output=True, text=True, timeout=10)
        return {'queryReturnCode': result.returncode,
                'properties': dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)}

    def close(self):
        if self.unit:
            # Only this invocation's unique transient unit; no persistent service changes.
            subprocess.run(['sudo', '-n', 'systemctl', 'stop', self.unit], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        elif self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
            raise RuntimeError('Runtime cleanup timed out')
        finally:
            if self.unit:
                subprocess.run(['sudo', '-n', 'systemctl', 'reset-failed', self.unit], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
