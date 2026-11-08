import tempfile
from pathlib import Path
import unittest
from Tools.validate_storage_rotation_quota import workload,resource_verdict,HEADROOM_MAX

class StorageRotationQuotaTests(unittest.TestCase):
    def test_synthetic_workload_checks_activated_writes_and_old_key_removed_reads(self):
        with tempfile.TemporaryDirectory() as path:
            result=workload(Path(path),waves=2,workers=4,payload_bytes=4096)
        self.assertEqual(result['verifiedOperations'],8)
        self.assertEqual(result['migratedRows'],16)
        self.assertTrue(result['oldKeyRemovedReadback'])
        self.assertTrue(result['statesPreserved'])

    def test_missing_work_or_telemetry_and_equal_headroom_fail(self):
        complete={'verifiedOperations':2880,'migratedRows':16,'oldKeyRemovedReadback':True,'statesPreserved':True}
        sample={'peak':HEADROOM_MAX-1,'events':{'oom':0,'oom_kill':0}}
        self.assertTrue(all(resource_verdict([sample],complete,0).values()))
        self.assertFalse(all(resource_verdict([],complete,0).values()))
        self.assertFalse(all(resource_verdict([sample],{},0).values()))
        self.assertFalse(all(resource_verdict([sample],complete,1).values()))
        self.assertFalse(all(resource_verdict([{**sample,'peak':HEADROOM_MAX}],complete,0).values()))
        self.assertFalse(all(resource_verdict([{**sample,'events':{'oom_kill':1}}],complete,0).values()))

if __name__=='__main__':unittest.main()
