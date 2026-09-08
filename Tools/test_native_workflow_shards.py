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
    def selectors(self, platform, shard, *, check=True):
        text = WORKFLOW.read_text()
        start = text.index('          selectors=(-only-testing:')
        end = text.index('          xcodebuild ', start)
        script = textwrap.dedent(text[start:end]) + '\nprintf "%s\\n" "${selectors[@]}"\n'
        # The extracted section only constructs selectors; it stops before
        # xcodebuild and cannot access a provider, project data, or credentials.
        result = subprocess.run(
            ["/bin/bash", "-eu", "-o", "pipefail", "-c", script],
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                 "CI_PLATFORM": platform, "CI_SHARD": str(shard)},
            capture_output=True, text=True, check=check,
        )
        return result.stdout.splitlines() if check else result

    def test_ipad_shards_execute_every_declared_existing_ui_method_once(self):
        declared = re.findall(r'^\s+(test\w+)\s*(?:\\|; do)\s*$', WORKFLOW.read_text(), re.M)
        self.assertGreaterEqual(len(declared), 58)
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


if __name__ == "__main__":
    unittest.main()
