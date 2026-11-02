import base64
import copy
import hashlib
from pathlib import Path
import tempfile
import unittest
import uuid

from Tools.quota_checks import verdict, upload_readback_targets
from Tools.quota_runtime import read_cgroup, validate_ci_environment, launch_command


class QuotaRuntimeTests(unittest.TestCase):
    def test_kernel_limits_must_match_and_missing_telemetry_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            valid = {'memory.max':'512000000', 'memory.swap.max':'0', 'cpu.max':'50000 100000',
                     'memory.current':'1000', 'memory.peak':'2000', 'memory.events':'low 0\nmax 0\noom 0\noom_kill 0\n'}
            for name, value in valid.items(): (root/name).write_text(value)
            self.assertEqual(read_cgroup(root)['peak'], 2000)
            for name, wrong in [('memory.max','536870912'), ('memory.swap.max','1'),
                                ('cpu.max','100000 100000'), ('cpu.max','max 100000')]:
                with self.subTest(name=name,wrong=wrong):
                    (root/name).write_text(wrong)
                    with self.assertRaises((RuntimeError,ValueError)): read_cgroup(root)
                    (root/name).write_text(valid[name])
            (root/'memory.peak').unlink()
            with self.assertRaises(FileNotFoundError): read_cgroup(root)

    def test_missing_oom_counters_and_impossible_peak_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in {'memory.max':'512000000','memory.swap.max':'0',
                                'cpu.max':'50000 100000','memory.current':'1000',
                                'memory.peak':'2000','memory.events':'low 0\n'}.items():
                (root/name).write_text(value)
            with self.assertRaises(RuntimeError): read_cgroup(root)
            (root/'memory.events').write_text('oom 0\noom_kill 0\n')
            (root/'memory.peak').write_text('999')
            with self.assertRaises(RuntimeError): read_cgroup(root)

    def test_execution_is_restricted_to_manual_hosted_validation_branch(self):
        env = {'GITHUB_ACTIONS':'true', 'RUNNER_ENVIRONMENT':'github-hosted',
               'GITHUB_REPOSITORY':'Autbellum/GunnAire-Ops', 'GITHUB_EVENT_NAME':'workflow_dispatch',
               'GITHUB_REF':'refs/heads/validation/linux-quota-reviewed'}
        validate_ci_environment(env, 'Linux')
        for key, value in [('RUNNER_ENVIRONMENT','self-hosted'), ('GITHUB_REPOSITORY','other/repo'),
                           ('GITHUB_EVENT_NAME','push'), ('GITHUB_REF','refs/heads/main')]:
            with self.subTest(key=key):
                with self.assertRaises(RuntimeError): validate_ci_environment(dict(env, **{key:value}), 'Linux')
        with self.assertRaises(RuntimeError): validate_ci_environment(env, 'Darwin')

    def test_launcher_limits_environment_and_runs_backend_as_unprivileged_user(self):
        command = launch_command('gunnaire-quota-fixture.service', Path('/fixture/Backend'), {'SAFE':'fixture'}, 1001)
        self.assertIn('--uid=1001', command)
        self.assertIn('--property=MemoryMax=512000000', command)
        self.assertIn('--property=MemorySwapMax=0', command)
        self.assertIn('--property=CPUQuota=50%', command)
        self.assertEqual(command[-1], 'gunnaire_backend.py')
        self.assertEqual(command[command.index('/usr/bin/env')+1], '-i')
        self.assertNotIn('--collect', command)  # Do not discard failure telemetry early.


class QuotaVerdictTests(unittest.TestCase):
    def setUp(self):
        self.download = 'a' * 64
        self.upload = 'b' * 64
        raw = b'synthetic-replica'
        self.replica = hashlib.sha256(raw).hexdigest()
        good_download = dict(kind='download',status=200,bytes=64*1024**2,sha256=self.download)
        self.rows = [good_download.copy() for _ in range(120)]
        self.upload_ids = [str(uuid.UUID(int=i+1)) for i in range(120)]
        self.rows += [dict(kind='upload',status=201,json={'id':identifier}) for identifier in self.upload_ids]
        self.rows += [dict(kind='metadata',status=400) for _ in range(60)]
        self.rows += [dict(kind='replica',status=200,json={'payloadBase64':base64.b64encode(raw).decode(),
                                                        'chunkSHA256':self.replica}) for _ in range(60)]
        self.readbacks = [dict(documentID=identifier,status=200,bytes=12*1024**2,sha256=self.upload) for identifier in self.upload_ids]
        self.health = [dict(status=200,seconds=.01)]
        self.samples = [dict(peak=200000000,events={'oom':0,'oom_kill':0})]

    def check(self, **overrides):
        args = dict(rows=self.rows,retries=[],readbacks=self.readbacks,health=self.health,
                    samples=self.samples,backups=[{'verified':True}],waves=15,
                    download_digest=self.download,upload_digest=self.upload,
                    replica_digest=self.replica,survived=True,sample_errors=[])
        args.update(overrides)
        return verdict(**args)

    def test_valid_complete_evidence_passes(self):
        self.assertTrue(all(self.check().values()))

    def test_empty_or_incomplete_evidence_never_passes_vacuously(self):
        for overrides in [dict(samples=[]),dict(health=[]),dict(rows=[]),dict(readbacks=[]),dict(backups=[]),
                          dict(rows=self.rows[:-1]),dict(survived=False),dict(sample_errors=['OSError'])]:
            with self.subTest(overrides=list(overrides)):
                self.assertFalse(all(self.check(**overrides).values()))

    def test_kernel_peak_headroom_and_oom_are_independent_failure_gates(self):
        for peak in [409600000,512000000]:
            self.assertFalse(self.check(samples=[dict(peak=peak,events={})])['met20PercentHeadroom'])
        for key in ['oom','oom_kill','oom_group_kill']:
            self.assertFalse(self.check(samples=[dict(peak=100,events={key:1})])['measurementValid'])
        self.assertFalse(self.check(health=[dict(status=200,seconds=5)])['allHealthUnder5Seconds'])

    def test_corruption_or_wrong_prepared_replica_is_not_accepted(self):
        rows = copy.deepcopy(self.rows)
        rows[0]['sha256'] = 'bad'
        self.assertFalse(self.check(rows=rows)['downloadsVerified'])
        self.assertFalse(self.check(replica_digest='c'*64)['replicasVerified'])
        rows = copy.deepcopy(self.rows)
        rows[-1]['json']['payloadBase64'] = 'invalid!'
        self.assertFalse(self.check(rows=rows)['replicasVerified'])

    def test_definite_get_rejection_requires_verified_retry(self):
        rows = copy.deepcopy(self.rows)
        rows[0] = dict(kind='download',status=503)
        self.assertFalse(self.check(rows=rows)['downloadsVerified'])
        retry = dict(status=200,bytes=64*1024**2,sha256=self.download)
        self.assertTrue(self.check(rows=rows,retries=[retry])['downloadsVerified'])

    def test_unknown_upload_transport_is_recorded_without_replay(self):
        rows = copy.deepcopy(self.rows)
        rows[120] = dict(kind='upload',error='BrokenPipeError')
        self.assertTrue(self.check(rows=rows,readbacks=self.readbacks[1:])['uploadsVerified'])
        rows[120] = dict(kind='upload',error='UnexpectedError')
        self.assertFalse(self.check(rows=rows,readbacks=self.readbacks[1:])['uploadsVerified'])

    def test_duplicate_successful_upload_ids_cannot_pass_identical_byte_checks(self):
        rows = copy.deepcopy(self.rows)
        rows[121]['json']['id'] = rows[120]['json']['id']
        readbacks = copy.deepcopy(self.readbacks)
        readbacks[1]['documentID'] = readbacks[0]['documentID']
        self.assertFalse(self.check(rows=rows,readbacks=readbacks)['uploadsVerified'])

    def test_wrong_document_readback_cannot_pass_identical_byte_checks(self):
        readbacks = copy.deepcopy(self.readbacks)
        readbacks[0]['documentID'] = str(uuid.UUID(int=9999))
        self.assertFalse(self.check(readbacks=readbacks)['uploadsVerified'])

    def test_missing_or_malformed_upload_identity_fails_closed(self):
        for identifier in [None,123,'','../other','not-a-uuid']:
            rows = copy.deepcopy(self.rows)
            rows[120]['json']['id'] = identifier
            self.assertFalse(self.check(rows=rows)['uploadsVerified'])

    def test_readback_plan_rejects_all_bad_ids_before_network_requests(self):
        self.assertEqual(upload_readback_targets(self.rows), self.upload_ids)
        for identifier in [None,123,'','../other','not-a-uuid',self.upload_ids[0]]:
            rows = copy.deepcopy(self.rows)
            rows[121]['json']['id'] = identifier
            with self.subTest(identifier=identifier):
                with self.assertRaises(ValueError): upload_readback_targets(rows)
