#!/usr/bin/env python3
"""Real HTTP/auth/Ollama acceptance with isolated synthetic users and database.

This does not sign into Google/Apple or configure a native app's production URL.
Never substitutes a fake model, provider response, principal, or authorization check.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    # Must happen before importing backend configuration. No inherited provider access.
    for key in list(os.environ):
        if key.startswith('GUNNAIRE_') or any(word in key.upper() for word in ('TOKEN', 'SECRET', 'PASSWORD', 'API_KEY')):
            os.environ.pop(key, None)
    with tempfile.TemporaryDirectory(prefix='gunnaire-live-ai-') as temporary:
        os.environ.update(GUNNAIRE_BACKEND_DATA_DIR=temporary, GUNNAIRE_BACKEND_AUTH_MODE='google-id-token',
                          GUNNAIRE_GOOGLE_CLIENT_ID='synthetic-acceptance.apps.googleusercontent.com',
                          GUNNAIRE_LOCAL_AI_TIMEOUT_SECONDS='600', GUNNAIRE_PRIMARY_ADMIN_EMAIL='admin@example.invalid')
        from Backend import gunnaire_backend as backend
        from Backend import gunnaire_local_ai_backend as routes
        backend.initialize_database()
        tokens = {}
        for name, role in (('admin', 'Admin'), ('field', 'Field Technician')):
            email = name + '@example.invalid'
            now = dt.datetime.now(dt.timezone.utc).isoformat()
            with backend.db() as connection:
                connection.execute('INSERT OR REPLACE INTO users(email,role,is_active,created_at,updated_at) VALUES (?,?,1,?,?)',
                                   (email, role, now, now))
            tokens[name] = backend.create_app_session(email, 'synthetic-acceptance', name)[0]
        server = ThreadingHTTPServer(('127.0.0.1', 0), routes.GunnAireLocalAIBackendHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def request(path, actor=None, payload=None):
            headers = {'Content-Type': 'application/json'}
            if actor:
                headers['Authorization'] = 'Bearer ' + tokens[actor]
            req = urllib.request.Request(f'http://127.0.0.1:{server.server_port}' + path,
                                         headers=headers, data=None if payload is None else json.dumps(payload).encode())
            try:
                with opener.open(req, timeout=610) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, json.load(error)

        checks = []
        response = None
        try:
            code, _ = request(routes.STATUS_PATH)
            checks.append({'scope': 'unauthenticated-status', 'http': code, 'passed': code == 401})
            code, status = request(routes.STATUS_PATH, 'admin')
            checks.append({'scope': 'authenticated-status', 'http': code,
                           'passed': code == 200 and status.get('hostedFallbackEnabled') is False and status.get('local') is True})
            code, _ = request(routes.ASSIST_PATH, 'field', {'task': 'security_review', 'input': 'Synthetic blocked-role check'})
            checks.append({'scope': 'unauthorized-role', 'http': code, 'passed': code == 403})
            code, response = request(routes.ASSIST_PATH, 'field', {
                'task': 'customer_text_draft',
                'input': 'Synthetic acceptance fixture: the requested service appointment is not yet confirmed. Draft one sentence saying the office will contact the customer to arrange a time. Do not send it.'})
            checks.append({'scope': 'authenticated-real-model-draft', 'http': code, 'passed': code == 200
                           and response.get('advisoryOnly') is True and response.get('needsHumanApproval') is True
                           and response.get('hostedFallbackUsed') is False and response.get('stableDiffusionUsed') is False
                           and bool(response.get('result', {}).get('body'))})
            with backend.db() as connection:
                audit_count = connection.execute("SELECT COUNT(*) FROM audit_events WHERE action='generate-draft'").fetchone()[0]
            checks.append({'scope': 'audit-record', 'passed': audit_count == 1})
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=5)
        report = {'schema_version': 1, 'observed_at': dt.datetime.now(dt.timezone.utc).isoformat(),
                  'scope': 'Real loopback HTTP, app-session verification and Ollama inference; synthetic identity bootstrap only',
                  'provider_login_tested': False, 'native_app_configuration_tested': False,
                  'production_data_used': False, 'persistent_service_deployed': False,
                  'checks': checks, 'response': response, 'passed': all(c['passed'] for c in checks)}
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(report, indent=2) + '\n')
        print(args.evidence)
        return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
