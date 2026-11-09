import copy
import hashlib
import unittest
from Tools.upload_recovery_checks import verdict, crash_verdict

class UploadRecoveryQuotaTests(unittest.TestCase):
    def setUp(self):
        self.identifier='00000000-0000-0000-0000-000000000001'
        self.size=25*1024**2;self.digest=hashlib.sha256(b'm'*self.size).hexdigest()
        self.final=dict(recovery=self.identifier,recoveryHash=self.digest,replay=self.identifier,downloadHash=self.digest,downloadBytes=self.size,committed=1,pending=0,actorStatus=409,healthStatuses=[200]*3)
        self.samples=[dict(peak=200000000,events={'oom':0,'oom_kill':0})]
        self.rows=[dict(wave=w,kind=k,status=503) for w in range(3) for k in ('recovery','replay','download') for _ in range(8)]
    def check(self,**kw):
        args=dict(rows=self.rows,samples=self.samples,errors=[],identifier=self.identifier,digest=self.digest,size=self.size,alive=True,final=self.final);args.update(kw)
        return verdict(**args)
    def test_complete_bounded_rejections_pass_with_separate_required_final_readbacks(self):
        self.assertTrue(all(self.check().values()))
    def test_missing_wave_kind_identity_or_fixture_fails(self):
        for kw in (dict(rows=[]),dict(rows=self.rows[:-1]),dict(identifier='../x'),dict(size=12),dict(digest='bad'),dict(alive=False),dict(errors=['sample'])):
            self.assertFalse(all(self.check(**kw).values()))
    def test_memory_peak_oom_and_empty_samples_fail(self):
        for samples in ([],[dict(peak=409600000,events={})],[dict(peak=512000000,events={})],[dict(peak=1,events={'oom_kill':1})]):
            self.assertFalse(all(self.check(samples=samples).values()))
    def test_each_success_requires_exact_identity_or_bytes(self):
        for k,r in [('replay',dict(status=201,json={'id':self.identifier})),('recovery',dict(status=200,json={'document':{'id':self.identifier,'fileSHA256':self.digest}})),('download',dict(status=200,bytes=self.size,sha256=self.digest))]:
            rows=copy.deepcopy(self.rows);i=next(i for i,x in enumerate(rows) if x['kind']==k);rows[i].update(r)
            self.assertTrue(all(self.check(rows=rows).values()))
            rows[i]['json']={};rows[i]['sha256']='bad'
            self.assertFalse(all(self.check(rows=rows).values()))
    def test_transport_unknown_is_only_allowed_for_post_and_unexpected_status_fails(self):
        for kind,status,error in [('download',None,'BrokenPipeError'),('recovery',None,'RemoteDisconnected'),('replay',500,None),('replay',200,None),('replay',None,'TimeoutError')]:
            rows=copy.deepcopy(self.rows);i=next(i for i,x in enumerate(rows) if x['kind']==kind);rows[i].update(status=status,error=error)
            self.assertFalse(all(self.check(rows=rows).values()))
    def test_duplicate_wave_cannot_pass_total_count(self):
        rows=copy.deepcopy(self.rows);rows[0]['wave']=2
        self.assertFalse(self.check(rows=rows)['completeWorkload'])
    def test_crash_evidence_is_required_and_mutations_fail(self):
        size=12*1024**2
        report=dict(payloadBytes=size,crashAttempts=[dict(failedAttempts=i+1,committedRows=0,pendingRows=1,payloadFiles=1,logicalBytes=size,sameInode=True) for i in range(4)],afterRetry=dict(committedRows=1,pendingRows=0,payloadFiles=1,logicalBytes=size,sha256=hashlib.sha256(b'o'*size).hexdigest()),distinctCrashBudget=dict(pendingByteCap=24*1024**2,blockedThirdStatus=503,pendingAtCap=2,payloadFilesAtCap=2,existingRecoveryStatus=201,pendingAfterRecovery=1,committedAfterRecovery=1))
        self.assertTrue(all(crash_verdict(self.samples,report,0).values()))
        for field in report:
            bad=copy.deepcopy(report);bad[field]=None if field!='crashAttempts' else []
            self.assertFalse(all(crash_verdict(self.samples,bad,0).values()))
        bad=copy.deepcopy(report);bad['crashAttempts'][1]['sameInode']=False
        self.assertFalse(all(crash_verdict(self.samples,bad,0).values()))
        self.assertFalse(all(crash_verdict(self.samples,report,23).values()))

    def test_all_final_readbacks_and_zero_pending_required(self):
        for key in self.final:
            final=copy.deepcopy(self.final);final.pop(key)
            self.assertFalse(all(self.check(final=final).values()))
        self.assertFalse(all(self.check(final=None).values()))
