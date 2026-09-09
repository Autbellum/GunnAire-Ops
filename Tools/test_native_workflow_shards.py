"""Exercise the actual workflow selector script without building or networking."""
import os
from pathlib import Path
import re
import subprocess
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/native-app-regression.yml"


class NativeWorkflowShardTests(unittest.TestCase):
    def selectors(self, platform, shard, *, check=True,
                  udid="12345678-1234-1234-1234-123456789ABC"):
        text = WORKFLOW.read_text()
        start = text.index('          selectors=(-only-testing:')
        end = text.index('          xcodebuild ', start)
        script = textwrap.dedent(text[start:end]) + '\nprintf "%s\\n" "${selectors[@]}"\n'
        # The extracted section only constructs selectors; it stops before
        # xcodebuild and cannot access a provider, project data, or credentials.
        result = subprocess.run(
            ["/bin/bash", "-eu", "-o", "pipefail", "-c", script],
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                 "CI_PLATFORM": platform, "CI_SHARD": str(shard),
                 "CI_IPAD_UDID": udid},
            capture_output=True, text=True, check=check,
        )
        return result.stdout.splitlines() if check else result

    def test_ipad_shards_execute_every_declared_existing_ui_method_once(self):
        declared = re.findall(r'^\s+(test\w+)\s*(?:\\|; do)\s*$', WORKFLOW.read_text(), re.M)
        self.assertGreaterEqual(len(declared), 64)
        self.assertIn("testExistingQuickBooksLinksOfferOfflineRecoveryWithoutDeviceOAuth", declared)
        self.assertIn("testUnverifiedBusinessRoleOffersRecoveryWithoutAdministratorWorkspaces", declared)
        for name in (
            "testSharedTimeReviewCancelsOnlyUnsentProposalAndReturnsToApprovedHours",
            "testSharedTimeWorkerReviewConfirmsReturnedWorkerAndReturnsToOriginalTime",
            "testSharedTimeLostConfirmationRecoversAfterRelaunchWithoutAnotherPublish",
            "testAdministratorCanMapTechnicianToAnExplicitQuickBooksTimeWorker",
        ):
            self.assertIn(name, declared)
        self.assertEqual(len(declared), len(set(declared)))
        source = (ROOT / "GunnAire OpsUITests/GunnAire_OpsUITests.swift").read_text()
        for name in declared:
            self.assertRegex(source, r"func " + name + r"\(")
        groups = [self.selectors("iPad", shard) for shard in (0, 1)]
        for selected in groups:
            self.assertEqual(selected[0], "-only-testing:GunnAire OpsTests")
            self.assertGreater(len(selected), 1)
        left, right = (set(group[1:]) for group in groups)
        self.assertFalse(left & right)
        expected = {"-only-testing:GunnAire OpsUITests/GunnAire_OpsUITests/" + name for name in declared}
        self.assertEqual(left | right, expected)
        self.assertLessEqual(abs(len(left) - len(right)), 1)
        self.assertIn("${{ matrix.platform }}-${{ matrix.shard }}-native-", WORKFLOW.read_text())

    def test_mac_keeps_the_complete_logic_target(self):
        self.assertEqual(self.selectors("Mac", 0), ["-only-testing:GunnAire OpsTests"])
        self.assertIn('ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO', WORKFLOW.read_text())
        self.assertIn("-verify_arch arm64 x86_64", WORKFLOW.read_text())

    def test_invalid_ipad_shard_cannot_report_an_empty_success(self):
        for shard in ("", "2", "-1", "text"):
            with self.subTest(shard=shard):
                result = self.selectors("iPad", shard, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_ipad_requires_the_prepared_exact_device(self):
        for udid in ("", "not-a-device", "12345678-1234-1234-1234-123456789ABC\nX=1"):
            with self.subTest(udid=udid):
                result = self.selectors("iPad", 0, check=False, udid=udid)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("-only-testing:", result.stdout)
        self.assertEqual(self.selectors("Mac", 0, udid=""), ["-only-testing:GunnAire OpsTests"])
        text = WORKFLOW.read_text()
        self.assertIn('destination="platform=iOS Simulator,id=$CI_IPAD_UDID"', text)
        self.assertIn('timeout-minutes: 5\n        run: bash Tools/prepare_ci_ipad.sh', text)
        self.assertLess(text.index('run: bash Tools/prepare_ci_ipad.sh'),
                        text.index('selectors=(-only-testing:'))


if __name__ == "__main__":
    unittest.main()
