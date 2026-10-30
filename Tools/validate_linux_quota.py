"""Synthetic exact-entrypoint workload; never loads production data or credentials."""
from pathlib import Path
import base64, concurrent.futures, hashlib, http.client, json, os, socket, subprocess, sys, threading, time, urllib.parse
from unittest import mock
from cryptography.fernet import Fernet
TREE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TREE))
from Tools.quota_runtime import Runtime, MEMORY_MAX, HEADROOM_MAX
from Tools.quota_checks import verdict
import argparse, importlib.metadata, platform, ssl
from Backend import gunnaire_backend as b, backup_backend
from Backend.test_staff_workspace_media import StaffWorkspaceMediaHTTPTests, content_http

def run(output, waves=15, local=False):
    if waves not in (15, 45):
        raise ValueError('Use the unchanged 15 or 45 wave workload')
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    sample_errors = []
    sampler = None
    monitor_thread = None
    log = None
    f = StaffWorkspaceMediaHTTPTests()
    f.setUp()
    fixture_key = Fernet.generate_key()
    f.cipher = Fernet(fixture_key)
    process = None
    stop = threading.Event()
    samples = []
    held = []
    rows = []
    health = []

    def install(identifier, payload, verified=True):
        content_http.fixtures.set_value(content_http.fixtures.row(f.records, 'attachment'), 'fileSizeBytes', 64 * 1024 ** 2)
        b.STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
        path = b.STORAGE_ROOT / (identifier + '.pdf')
        h = hashlib.sha256()
        with path.open('wb') as out:
            for _ in range(64):
                block = b'x' * 1024 ** 2
                out.write(block)
                h.update(block)
        with b.db() as c:
            c.execute('INSERT INTO documents(id,filename,content_type,kind,stored_path,created_at,file_size_bytes,file_sha256) VALUES(?,?,?,?,?,?,?,?)', (identifier, 'fixture.pdf', 'application/pdf', 'service_report', str(path), b.utc_now(), 64 * 1024 ** 2, h.hexdigest()))
        return payload
    try:
        with mock.patch.object(f, 'install_document', side_effect=install):
            f.seed_with_media()
        baseline_path = f.content_path + '/chunks?' + urllib.parse.urlencode(dict(f.scope, offset='0'))
        status, baseline = f.request(token=f.tokens['Admin'], path=baseline_path)
        if status != 200:
            raise RuntimeError('Fixture replica baseline unavailable')
        replica_digest = baseline['chunkSHA256']
        f.server.shutdown()
        f.server.server_close()
        f.thread.join(5)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        env = {'PATH': os.environ['PATH'], 'PYTHONDONTWRITEBYTECODE': '1', 'GUNNAIRE_BACKEND_HOST': '127.0.0.1', 'GUNNAIRE_BACKEND_PORT': str(port), 'GUNNAIRE_BACKEND_AUTH_MODE': 'google-id-token', 'GUNNAIRE_GOOGLE_CLIENT_ID': 'fixture.apps.googleusercontent.com', 'GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY': fixture_key.decode(), 'GUNNAIRE_PRIMARY_ADMIN_EMAIL': 'owner@gunnaire.com', 'GUNNAIRE_BACKEND_DATA_DIR': f.directory.name, 'GUNNAIRE_BACKEND_DB': str(b.DB_PATH), 'GUNNAIRE_BACKEND_STORAGE': str(b.STORAGE_ROOT), 'GUNNAIRE_BACKUP_WORKER_STARTUP_DELAY_SECONDS': '2'}
        if not local:
            env['LD_LIBRARY_PATH'] = str(Path(sys.base_prefix) / 'lib')
            # Evict only our synthetic file cache before the first server read.
            # Never drop global host caches or production data pages.
            for fixture_file in Path(f.directory.name).rglob('*'):
                if fixture_file.is_file() and not fixture_file.is_symlink():
                    with fixture_file.open('rb') as fixture_handle:
                        os.fsync(fixture_handle.fileno())
                        os.posix_fadvise(fixture_handle.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
        log = open(output / 'server.log', 'w')
        process = Runtime(TREE / 'Backend', env, log, local=local)

        def request(method, path, token=None, body=None, slow=False):
            c = http.client.HTTPConnection('127.0.0.1', port, timeout=15)
            start = time.monotonic()
            try:
                c.connect()
                if slow:
                    c.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
                headers = {'Content-Type': 'application/json'}
                if token:
                    headers['Authorization'] = 'Bearer ' + token
                c.request(method, path, body, headers)
                r = c.getresponse()
                if slow and r.status == 200:
                    time.sleep(3)
                h = hashlib.sha256()
                count = 0
                small = []
                while (block := r.read(65536)):
                    count += len(block)
                    h.update(block)
                    if count < 65536:
                        small.append(block)
                    if slow and r.status == 200:
                        time.sleep(0.001)
                result = {'status': r.status, 'bytes': count, 'sha256': h.hexdigest(), 'seconds': round(time.monotonic() - start, 3)}
                if small:
                    try:
                        result['json'] = json.loads(b''.join(small))
                    except ValueError:
                        pass
                return result
            except (OSError, http.client.HTTPException) as e:
                return {'error': type(e).__name__, 'seconds': round(time.monotonic() - start, 3)}
            finally:
                c.close()
        for _ in range(200):
            if request('GET', '/health').get('status') == 200:
                break
            if process.poll() is not None:
                raise RuntimeError('Server stopped at startup')
            time.sleep(0.05)
        else:
            raise RuntimeError('Startup deadline')
        process.attach()
        started = time.monotonic()

        def sample():
            while not stop.is_set() and process.poll() is None:
                try:
                    value = process.sample()
                    samples.append(dict(seconds=round(time.monotonic() - started, 3), **value))
                    if value['current'] > MEMORY_MAX:
                        if local: process.close()
                        return
                except Exception as error:
                    sample_errors.append(type(error).__name__)
                    return
                stop.wait(0.05)
        sampler = threading.Thread(target=sample)
        sampler.start()

        def monitor():
            while not stop.is_set():
                health.append(request('GET', '/health'))
                stop.wait(0.2)
        monitor_thread = threading.Thread(target=monitor)
        monitor_thread.start()
        for _ in range(8):
            sock = socket.create_connection(('127.0.0.1', port), timeout=2)
            sock.sendall(b'GET /health HTTP/1.1\r\n')
            held.append(sock)
        paths = [('/api/documents/' + f.document_id + '/download', f.tokens['Admin']), (f.media_path(bytes_path=True) + '?' + urllib.parse.urlencode(dict(f.scope, attachmentID=f.attachment_id)), f.tokens['Field Technician'])]
        replica = f.content_path + '/chunks?' + urllib.parse.urlencode(dict(f.scope, offset='0'))
        payload = b'u' * 12 * 1024 ** 2
        digest = hashlib.sha256(payload).hexdigest()
        body = json.dumps({'filename': 'load.pdf', 'contentType': 'application/pdf', 'dataBase64': base64.b64encode(payload).decode()}).encode()
        metadata = json.dumps({'email': 'invalid', 'padding': 'x' * (1024 ** 2 - 100)}).encode()
        for round_number in range(waves):
            barrier = threading.Barrier(25)

            def action(kind, i):
                barrier.wait(15)
                if kind == 'download':
                    r = request('GET', *paths[i % 2], slow=True)
                elif kind == 'upload':
                    r = request('POST', '/api/documents', f.tokens['Admin'], body)
                elif kind == 'metadata':
                    r = request('POST', '/api/users', f.tokens['Admin'], metadata)
                else:
                    r = request('GET', replica, f.tokens['Admin'])
                return {'round': round_number, 'kind': kind, 'routeIndex': i % 2, **r}
            with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
                futures = [pool.submit(action, kind, i) for kind, count in [('download', 8), ('upload', 8), ('metadata', 4), ('replica', 4)] for i in range(count)]
                barrier.wait(15)
                rows.extend((x.result(30) for x in futures))
            if process.poll() is not None:
                break
            time.sleep(1)
        retries = []
        upload_ids = []
        if process.poll() is None:
            for r in rows:
                if r['kind'] == 'upload' and r.get('status') == 201:
                    upload_ids.append(r['json']['id'])
            for r in rows:
                if r['kind'] == 'download' and r.get('status') == 503:
                    retries.append(request('GET', *paths[r['routeIndex']]))
            readbacks = [request('GET', '/api/documents/' + i + '/download', f.tokens['Admin']) for i in upload_ids]
            time.sleep(3)
        else:
            readbacks = []
        stop.set()
        sampler.join(3)
        monitor_thread.join(16)
        backups = []
        for path in (Path(f.directory.name) / 'backups').glob('gunnaire-auto-backup-*'):
            if path.is_dir():
                backups.append(backup_backend.verify_backup(path))
        if process.poll() is None:
            try:
                samples.append(dict(seconds=round(time.monotonic() - started, 3), **process.sample()))
            except Exception as error:
                sample_errors.append(type(error).__name__)
        expected = hashlib.sha256(b'x' * 64 * 1024 ** 2).hexdigest()
        checks = verdict(rows, retries, readbacks, health, samples, backups, waves, expected, digest, replica_digest, process.poll() is None, sample_errors)
        checks['certifiPatched'] = tuple(int(x) for x in importlib.metadata.version('certifi').split('.')) >= (2026, 10, 19)
        report = {'sourceSHA':subprocess.check_output(['git','rev-parse','HEAD'],cwd=TREE,text=True).strip(),'mode': 'local-smoke-NOT-Linux-quota' if local else 'linux-cgroup-v2', 'waves': waves, 'budgetBytes': MEMORY_MAX, 'headroomTargetBytes': HEADROOM_MAX, 'checks': checks, 'passed': all(checks.values()), 'peakBytes': max((r['peak'] for r in samples), default=0), 'durationSeconds': round(time.monotonic() - started, 3), 'sampleErrors': sample_errors, 'runtime': {'python': platform.python_version(), 'openssl': ssl.OPENSSL_VERSION, 'certifi': importlib.metadata.version('certifi')}, 'samples': samples, 'requests': rows, 'downloadRetries': retries, 'uploadReadbacks': readbacks, 'health': health, 'backup': backups}
        (output / 'report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps({k: v for k, v in report.items() if k not in ['samples', 'requests', 'downloadRetries', 'uploadReadbacks', 'health', 'backup']}, indent=2))
        return report
    finally:
        stop.set()
        for sock in held:
            sock.close()
        if sampler:
            sampler.join(5)
        if monitor_thread:
            monitor_thread.join(20)
        try:
            if process is not None:
                try:
                    (output / 'runtime-status.json').write_text(json.dumps(process.status(), indent=2))
                finally:
                    process.close()
        finally:
            if log:
                log.close()
            f.tearDown()
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--waves', type=int, choices=(15, 45), default=15)
    parser.add_argument('--local-smoke', action='store_true', help='No cgroup claim; synthetic local logic validation only')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output directory already exists; preserve existing evidence')
    try:
        result = run(args.output, args.waves, args.local_smoke)
    except Exception as error:
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / 'failure.json').write_text(json.dumps({'passed': False, 'errorType': type(error).__name__, 'reason': str(error) if type(error) is RuntimeError else 'See retained fixture log'}))
        raise SystemExit(1)
    raise SystemExit(0 if result['passed'] else 1)
