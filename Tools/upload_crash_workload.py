"""Synthetic bounded crash/byte accounting; no real files or credentials."""
import hashlib,json,os,subprocess,sys,uuid
from pathlib import Path
from unittest import mock
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT))
from Backend import gunnaire_backend as b
from Backend.test_document_upload_idempotency import DocumentUploadIdempotencyTests
def workload():
    payload=b'o'*(12*1024**2)
    case=DocumentUploadIdempotencyTests();case.setUp()
    try:
     original=case.upload;case.upload=lambda **changes:original(payload=payload,**changes)
     operation=str(uuid.uuid4());rows=[];identity=None
     for attempt in range(4):
      case.crashed_upload('before-commit',operation)
      files=list(b.STORAGE_ROOT.rglob('*.payload'));assert len(files)==1
      current=(files[0].stat().st_dev,files[0].stat().st_ino)
      if identity is not None:assert current==identity
      identity=current
      with b.db() as c:
       committed=c.execute('SELECT COUNT(*) FROM documents').fetchone()[0]
       pending=c.execute('SELECT COUNT(*) FROM document_upload_reservations_v1').fetchone()[0]
      assert committed==0 and pending==1 and files[0].read_bytes()==payload
      rows.append({'failedAttempts':attempt+1,'committedRows':committed,'pendingRows':pending,'payloadFiles':len(files),'logicalBytes':files[0].stat().st_size,'allocatedBytes':files[0].stat().st_blocks*512,'sameInode':True})
     status,created=case.upload(operationID=operation);assert status==201
     with b.db() as c:
      committed=c.execute('SELECT COUNT(*) FROM documents').fetchone()[0]
      pending=c.execute('SELECT COUNT(*) FROM document_upload_reservations_v1').fetchone()[0]
      path=c.execute('SELECT stored_path FROM documents WHERE id=?',(created['id'],)).fetchone()[0]
     assert committed==1 and pending==0 and (Path(path).stat().st_dev,Path(path).stat().st_ino)==identity
     report={'sourceSHA':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'payloadBytes':len(payload),'crashAttempts':rows,'afterRetry':{'committedRows':committed,'pendingRows':pending,'payloadFiles':len(list(b.STORAGE_ROOT.rglob('*.payload'))),'logicalBytes':Path(path).stat().st_size,'sha256':hashlib.sha256(Path(path).read_bytes()).hexdigest()}}
    finally:case.doCleanups()
    case=DocumentUploadIdempotencyTests();case.setUp()
    try:
     original=case.upload;case.upload=lambda **changes:original(payload=payload,**changes)
     operations=[str(uuid.uuid4()) for _ in range(3)]
     with mock.patch.dict(os.environ,{'GUNNAIRE_UPLOAD_PENDING_BYTES':str(24*1024**2)}):
      for operation in operations[:2]:case.crashed_upload('before-commit',operation)
      status,_=case.upload(operationID=operations[2]);assert status==503
      with b.db() as c:
       pending=c.execute('SELECT COUNT(*) FROM document_upload_reservations_v1').fetchone()[0]
      assert pending==2 and len(list(b.STORAGE_ROOT.rglob('*.payload')))==2
      assert case.upload(operationID=operations[0])[0]==201
      with b.db() as c:
       after_pending=c.execute('SELECT COUNT(*) FROM document_upload_reservations_v1').fetchone()[0]
       committed=c.execute('SELECT COUNT(*) FROM documents').fetchone()[0]
      assert (after_pending,committed)==(1,1)
      report['distinctCrashBudget']={'pendingByteCap':24*1024**2,'blockedThirdStatus':status,'pendingAtCap':pending,'payloadFilesAtCap':2,'existingRecoveryStatus':201,'pendingAfterRecovery':after_pending,'committedAfterRecovery':committed}
    finally:case.doCleanups()
    return report
