"""Synthetic activated-envelope pressure, separate from exact-entrypoint quota.

No live configuration/data. Same kernel quota/headroom; no local quota fallback.
The worker exercises 64 concurrent 1 MiB writes/readbacks for 45 waves, then
serial bounded migration. This is additional crypto evidence, not server E2E.
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import platform
import sqlite3
import subprocess
import sys
import threading
import time
import uuid

TREE=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(TREE))
from Tools.quota_runtime import MEMORY_MAX,HEADROOM_MAX,read_cgroup,validate_ci_environment,launch_command

def resource_verdict(samples,completion,code):
    peak=max((s['peak'] for s in samples),default=0)
    return {'completed':code==0 and completion.get('verifiedOperations')==2880 and completion.get('migratedRows')==16
            and completion.get('oldKeyRemovedReadback') is True and completion.get('statesPreserved') is True,
            'measurementValid':bool(samples),'underBudget':bool(samples) and peak<MEMORY_MAX,
            'met20PercentHeadroom':bool(samples) and peak<HEADROOM_MAX,
            'noOOM':bool(samples) and all(not any(s['events'].get(k,0) for k in ('oom','oom_kill','oom_group_kill')) for s in samples)}


def workload(directory, *, waves=45, workers=64, payload_bytes=1024*1024):
    from Backend import gunnaire_backend as backend
    original=(backend.QBO_TOKEN_ENCRYPTION_KEY,backend.QBO_STORAGE_KEYRING)
    try:
        return _workload(directory,waves=waves,workers=workers,payload_bytes=payload_bytes)
    finally:
        backend.QBO_TOKEN_ENCRYPTION_KEY,backend.QBO_STORAGE_KEYRING=original


def _workload(directory, *, waves, workers, payload_bytes):
    from cryptography.fernet import Fernet
    from Backend import gunnaire_backend as backend
    from Backend.storage_keyring import StorageKeyring
    from Backend.storage_rotation import migrate_batch
    old,new=Fernet.generate_key().decode(),Fernet.generate_key().decode()
    config=json.dumps({'version':1,'active':'new','write_format':'versioned','keys':{'old':old,'new':new}})
    backend.QBO_TOKEN_ENCRYPTION_KEY=old
    backend.QBO_STORAGE_KEYRING=config
    barrier=threading.Barrier(workers,timeout=120)
    def exercise(number):
        clear=str(number)+':'+'x'*payload_bytes
        barrier.wait()
        encrypted=backend.encrypt_catalog_payload(clear)
        decoded=backend.decrypt_catalog_payload(encrypted)
        if decoded!=clear:raise RuntimeError('Activated envelope readback failed')
        # Retain each caller's result until all concurrent operations finish.
        barrier.wait()
        return True
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for wave in range(waves):
            if not all(pool.map(exercise,range(wave*workers,(wave+1)*workers))):
                raise RuntimeError('Incomplete crypto workload')
    db=sqlite3.connect(directory/'migration.sqlite3');db.row_factory=sqlite3.Row
    db.execute('PRAGMA cache_size=-512')
    db.execute('CREATE TABLE time_publications(payload_ciphertext TEXT,receipt_ciphertext TEXT,state TEXT)')
    for i in range(16):
        db.execute('INSERT INTO time_publications VALUES (?,NULL,?)',(Fernet(old).encrypt((str(i)+':'+'y'*payload_bytes).encode()).decode(),'uncertain'))
    db.commit()
    ring=StorageKeyring('qbo',old,config)
    cursor=0;changed=0
    while True:
        result=migrate_batch(db,ring,'time_publications','payload_ciphertext',after=cursor,max_rows=50,max_bytes=4*1024*1024)
        changed+=result['changed']
        if not result['scanned']:break
        cursor=result['cursor']
    if changed!=16:raise RuntimeError('Incomplete migration workload')
    retired=StorageKeyring('qbo',new,json.dumps({'version':1,'active':'new','write_format':'versioned','keys':{'new':new}}))
    for i,row in enumerate(db.execute('SELECT * FROM time_publications ORDER BY rowid')):
        if (retired.decrypt(row['payload_ciphertext'].encode()).decode()!=str(i)+':'+'y'*payload_bytes
                or row['receipt_ciphertext'] is not None or row['state']!='uncertain'):
            raise RuntimeError('Migration verification failed')
    if db.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise RuntimeError('Integrity check failed')
    db.close()
    return {'waves':waves,'concurrency':workers,'plaintextBytesPerOperation':payload_bytes,
            'verifiedOperations':waves*workers,'migratedRows':changed,'oldKeyRemovedReadback':True,
            'statesPreserved':True,'providerCalls':0}


def run(output):
    validate_ci_environment(os.environ,platform.system())
    if os.getuid()==0 or sys.version_info[:3]!=(3,14,3):raise RuntimeError('Requires unprivileged production-compatible Python')
    output=output.resolve();output.mkdir(parents=True,exist_ok=False)
    unit='gunnaire-rotation-quota-'+uuid.uuid4().hex+'.service'
    env={'PATH':os.environ['PATH'],'PYTHONDONTWRITEBYTECODE':'1','LD_LIBRARY_PATH':str(Path(sys.base_prefix)/'lib')}
    expected=[sys.executable,str(Path(__file__).resolve()),'--worker',str(output)]
    command=launch_command(unit,TREE,env,os.getuid())[:-2]+expected
    samples=[];errors=[];process=None;report=None
    with (output/'worker.log').open('w') as log:
        try:
            process=subprocess.Popen(command,stdout=log,stderr=log)
            group=Path('/sys/fs/cgroup/system.slice')/unit
            for _ in range(200):
                if (group/'memory.current').is_file():break
                if process.poll() is not None:raise RuntimeError('Worker failed before cgroup attachment')
                time.sleep(.05)
            read_cgroup(group)
            pid=int(subprocess.check_output(['systemctl','show',unit,'--property=MainPID','--value'],text=True))
            if (pid<=0 or (Path('/proc')/str(pid)/'cmdline').read_bytes().split(b'\0')[:-1] != [v.encode() for v in expected]
                    or f'0::/system.slice/{unit}' not in (Path('/proc')/str(pid)/'cgroup').read_text().splitlines()):
                raise RuntimeError('Unexpected worker process identity')
            started=time.monotonic()
            while process.poll() is None and not (output/'done.json').exists():
                samples.append(read_cgroup(group))
                if time.monotonic()-started>600:raise RuntimeError('Crypto workload timed out')
                time.sleep(.05)
            if not (output/'done.json').exists():raise RuntimeError('Crypto workload did not complete')
            samples.append(read_cgroup(group))
            completion=json.loads((output/'done.json').read_text())
            (output/'release').touch()
            code=process.wait(timeout=20)
            peak=max(s['peak'] for s in samples)
            checks=resource_verdict(samples,completion,code)
            report={'sourceSHA':subprocess.check_output(['git','rev-parse','HEAD'],cwd=TREE,text=True).strip(),
                    'kind':'activated-storage-envelopes-NOT-server-E2E','budgetBytes':MEMORY_MAX,'headroomTargetBytes':HEADROOM_MAX,
                    'peakBytes':peak,'checks':checks,'passed':all(checks.values()),'workload':completion,'samples':samples}
            (output/'report.json').write_text(json.dumps(report,indent=2))
            print(json.dumps({k:v for k,v in report.items() if k!='samples'}))
            return report['passed']
        except Exception as error:
            (output/'failure.json').write_text(json.dumps({'passed':False,'errorType':type(error).__name__,'samples':samples}))
            raise
        finally:
            subprocess.run(['sudo','-n','systemctl','stop',unit],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
            if process is not None:process.wait(timeout=20)
            subprocess.run(['sudo','-n','systemctl','reset-failed',unit],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--worker',type=Path);parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    if args.worker:
        result=workload(args.worker)
        (args.worker/'done.tmp').write_text(json.dumps(result))
        (args.worker/'done.tmp').replace(args.worker/'done.json')
        for _ in range(600):
            if (args.worker/'release').exists():break
            time.sleep(.05)
        else:raise SystemExit('Controller did not release worker')
    elif args.output:raise SystemExit(0 if run(args.output) else 1)
    else:parser.error('Specify output')
