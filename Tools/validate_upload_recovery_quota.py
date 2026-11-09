"""Bounded synthetic 25 MiB recovery contention; canonical child server, no live data."""
import base64, collections, concurrent.futures, hashlib, http.client, json, os
from pathlib import Path
import socket, subprocess, sys, threading, time, uuid
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT))
from cryptography.fernet import Fernet
from Backend import gunnaire_backend as b
from Backend.test_workspace_identity import WorkspaceIdentityTests
from Tools.quota_runtime import Runtime, MEMORY_MAX, HEADROOM_MAX
import argparse
from Tools.upload_recovery_checks import verdict
parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);parser.add_argument('--local-smoke',action='store_true');args=parser.parse_args()
out=args.output;out.mkdir(parents=True,exist_ok=False)
f=WorkspaceIdentityTests();f.setUp();process=None;log=None;stop=threading.Event();samples=[];sample_errors=[]
try:
 f.server.shutdown();f.server.server_close();f.thread.join(5)
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 env={'PATH':os.environ['PATH'],'PYTHONDONTWRITEBYTECODE':'1','LD_LIBRARY_PATH':str(Path(sys.base_prefix)/'lib'),'GUNNAIRE_BACKEND_HOST':'127.0.0.1','GUNNAIRE_BACKEND_PORT':str(port),'GUNNAIRE_BACKEND_AUTH_MODE':'google-id-token','GUNNAIRE_GOOGLE_CLIENT_ID':'fixture.apps.googleusercontent.com','GUNNAIRE_PRIMARY_ADMIN_EMAIL':'owner@gunnaire.com','GUNNAIRE_BACKEND_DATA_DIR':f.directory.name,'GUNNAIRE_BACKEND_DB':str(b.DB_PATH),'GUNNAIRE_BACKEND_STORAGE':str(b.STORAGE_ROOT),'GUNNAIRE_MAX_DOCUMENT_BYTES':str(25*1024**2),'GUNNAIRE_BACKUP_WORKER_STARTUP_DELAY_SECONDS':'3600'}
 for domain in ('QBO','GOOGLE','PUSH'):
  env['GUNNAIRE_'+domain+'_STORAGE_KEYRING']=json.dumps({'version':1,'active':'new','write_format':'versioned','keys':{'new':Fernet.generate_key().decode()}})
 log=open(out/'server.log','w');process=Runtime(ROOT/'Backend',env,log,local=args.local_smoke)
 def request(method,path,body=None,role='Admin'):
  c=http.client.HTTPConnection('127.0.0.1',port,timeout=20)
  try:
   c.request(method,path,body,{'Content-Type':'application/json','Authorization':'Bearer '+f.tokens[role]})
   r=c.getresponse();h=hashlib.sha256();count=0;parts=[]
   while block:=r.read(65536):
    h.update(block);count+=len(block)
    if count<=65536:parts.append(block)
   result={'status':r.status,'bytes':count,'sha256':h.hexdigest()}
   if count<=65536:
    try:result['json']=json.loads(b''.join(parts))
    except ValueError:pass
   return result
  except (OSError,http.client.HTTPException) as e:return {'error':type(e).__name__}
  finally:c.close()
 for _ in range(200):
  if request('GET','/health').get('status')==200:break
  if process.poll() is not None:raise RuntimeError('server exited')
  time.sleep(.05)
 else:raise RuntimeError('startup timed out')
 process.attach()
 def sample():
  while not stop.is_set() and process.poll() is None:
   try:
    v=process.sample();samples.append(v)
    if v['current']>MEMORY_MAX:process.close();return
   except Exception as e:sample_errors.append(type(e).__name__);return
   stop.wait(.05)
 sampler=threading.Thread(target=sample);sampler.start()
 operation=str(uuid.uuid4());data=b'm'*25*1024**2;digest=hashlib.sha256(data).hexdigest()
 body=json.dumps({'operationID':operation,'filename':'maximum.pdf','contentType':'application/pdf','kind':'service_report','dataBase64':base64.b64encode(data).decode()}).encode()
 created=request('POST','/api/documents',body);assert created.get('status')==201,created
 identifier=created['json']['id'];recovery='/api/document-uploads/'+operation;download='/api/documents/'+identifier+'/download'
 rows=[];health=[]
 for wave in range(3):
  barrier=threading.Barrier(25)
  def action(kind):
   barrier.wait(10)
   r=request('POST','/api/documents',body) if kind=='replay' else request('GET',recovery if kind=='recovery' else download)
   return {'wave':wave,'kind':kind,**r}
  with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
   futures=[pool.submit(action,kind) for kind in ('recovery','replay','download') for _ in range(8)]
   barrier.wait(10);rows.extend(x.result(30) for x in futures)
  health.append(request('GET','/health'))
 checks={'allOutcomesBounded':all(r.get('status') in (200,201,503) or r.get('error') in ('BrokenPipeError','ConnectionResetError','RemoteDisconnected') for r in rows),
         'sameReplayIdentity':all(r['json']['id']==identifier for r in rows if r['kind']=='replay' and r.get('status')==201),
         'correctRecoveredIdentity':all(r['json']['document']['id']==identifier and r['json']['document']['fileSHA256']==digest for r in rows if r['kind']=='recovery' and r.get('status')==200),
         'downloadIntegrity':all(r['bytes']==len(data) and r['sha256']==digest for r in rows if r['kind']=='download' and r.get('status')==200),
         'healthyAfterEachWave':all(r.get('status')==200 for r in health)}
 final={'healthStatuses':[r.get('status') for r in health]}
 for kind,path in (('recovery',recovery),('download',download)):
  r=request('GET',path);checks[kind+'AfterContention']=r.get('status')==200 and (r['json']['document']['id']==identifier if kind=='recovery' else r['sha256']==digest)
  if kind=='recovery':
   final['recovery']=r.get('json',{}).get('document',{}).get('id');final['recoveryHash']=r.get('json',{}).get('document',{}).get('fileSHA256')
  else:final['downloadHash']=r.get('sha256');final['downloadBytes']=r.get('bytes')
 final['replay']=request('POST','/api/documents',body).get('json',{}).get('id')
 checks['replayAfterContention']=final['replay']==identifier
 final['actorStatus']=request('GET',recovery,role='Field Technician').get('status')
 checks['otherActorDenied']=final['actorStatus']==409
 with b.db() as c:
  final['committed']=c.execute('SELECT COUNT(*) FROM documents').fetchone()[0]
  checks['oneCommittedDocument']=final['committed']==1
  final['pending']=c.execute('SELECT COUNT(*) FROM document_upload_reservations_v1').fetchone()[0]
  checks['noPendingAfterSuccess']=final['pending']==0
 stop.set();sampler.join(5);samples.append(process.sample())
 peak=max(v['peak'] for v in samples)
 checks.update(verdict(rows,samples,sample_errors,identifier,digest,len(data),process.poll() is None,final))
 report={'sourceSHA':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'mode':'local-smoke-NOT-Linux-quota' if args.local_smoke else 'linux-cgroup-v2','payloadBytes':len(data),'concurrentRequests':24,'waves':3,'newOnlySyntheticKeyrings':3,'peakBytes':peak,'budgetBytes':MEMORY_MAX,'headroomTargetBytes':HEADROOM_MAX,'outcomes':dict(collections.Counter(str(r.get('status',r.get('error'))) for r in rows)),'checks':checks,'passed':all(checks.values()),'samples':samples,'requests':rows,'finalReadbacks':final,'sampleErrors':sample_errors}
 (out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k not in ('samples','requests')},indent=2))
 if not report['passed']:raise SystemExit(1)
except BaseException as error:
 (out/'failure.json').write_text(json.dumps({'passed':False,'errorType':type(error).__name__,'samples':samples,'sampleErrors':sample_errors}))
 raise
finally:
 stop.set()
 if 'sampler' in locals():sampler.join(5)
 if process:process.close()
 if log:log.close()
 f.tearDown()
