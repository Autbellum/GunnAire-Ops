"""Execute the actual CI preparation script against a fixture-only simctl."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare_ci_ipad.sh")
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
UDID = "12345678-1234-1234-1234-123456789ABC"


class PrepareCIIPadTests(unittest.TestCase):
    def run_fixture(self, *, missing_runtime=False, unavailable=False,
                    missing_type=False, invalid_id=False, fail_at="", ready=True,
                    wrong_runtime=False, wrong_type=False, shard="0"):
        self.assertIsNotNone(shutil.which("jq"), "jq is required, as on the CI runners")
        with tempfile.TemporaryDirectory(prefix="gunnaire-simulator-test-") as directory:
            root = Path(directory)
            before = {
                "runtimes": [] if missing_runtime else [
                    {"identifier": RUNTIME, "isAvailable": not unavailable}],
                "devicetypes": [] if missing_type else [{"identifier": DEVICE}],
                "devices": {},
            }
            after = dict(before, devices={RUNTIME if not wrong_runtime else "other-runtime": [
                {"udid": UDID, "deviceTypeIdentifier": DEVICE if not wrong_type else "other-type",
                 "state": "Booted" if ready else "Shutdown", "isAvailable": True}]})
            (root / "before.json").write_text(json.dumps(before))
            (root / "after.json").write_text(json.dumps(after))
            # This fixture owns only temporary files; no Apple tooling is called.
            fake = root / "xcrun"
            fake.write_text('''#!/bin/bash
set -eu
printf '%s\\n' "$*" >> "$FIXTURE_ROOT/calls"
[[ "$1" == simctl ]] || exit 90
[[ "$2" != "$FAIL_AT" ]] || exit 71
case "$2" in
  list)
    if [[ -f "$FIXTURE_ROOT/listed" ]]; then
      /bin/cat "$FIXTURE_ROOT/after.json"
    else
      /bin/cat "$FIXTURE_ROOT/before.json"
      /usr/bin/touch "$FIXTURE_ROOT/listed"
    fi ;;
  create) printf '%s\\n' "$CREATED_ID" ;;
  boot|bootstatus) : ;;
  *) exit 91 ;;
esac
''')
            fake.chmod(0o700)
            env = {"PATH": str(root) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
                   "FIXTURE_ROOT": str(root), "FAIL_AT": fail_at,
                   "CREATED_ID": UDID if not invalid_id else UDID + "\nINJECTED=1",
                   "CI_SHARD": shard, "RUNNER_TEMP": str(root),
                   "GITHUB_ENV": str(root / "github-env")}
            result = subprocess.run(["/bin/bash", str(SCRIPT)], env=env,
                                    capture_output=True, text=True, timeout=15)
            calls = (root / "calls").read_text().splitlines() if (root / "calls").exists() else []
            exported = (root / "github-env").read_text() if (root / "github-env").exists() else ""
            evidence = sorted(p.name for p in (root / "native-results").glob("*"))
            return result, calls, exported, evidence

    def test_missing_precreated_devices_are_created_booted_and_exported_by_id(self):
        result, calls, exported, evidence = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, ["simctl list -j",
            "simctl create GunnAire CI iPad 0 " + DEVICE + " " + RUNTIME,
            "simctl boot " + UDID, "simctl bootstatus " + UDID + " -b", "simctl list -j"])
        self.assertEqual(exported, "CI_IPAD_UDID=" + UDID + "\n")
        self.assertEqual(evidence, ["simulator-boot.log", "simulators-before.json", "simulators-ready.json"])

    def test_each_shard_gets_its_own_job_owned_device(self):
        result, calls, exported, _ = self.run_fixture(shard="1")
        self.assertEqual(result.returncode, 0)
        self.assertIn("simctl create GunnAire CI iPad 1 " + DEVICE + " " + RUNTIME, calls)
        self.assertTrue(exported)

    def test_missing_or_unavailable_pinned_environment_never_changes_os(self):
        for option in ("missing_runtime", "unavailable", "missing_type"):
            with self.subTest(option=option):
                result, calls, exported, evidence = self.run_fixture(**{option: True})
                self.assertEqual(result.returncode, 70)
                self.assertEqual(calls, ["simctl list -j"])
                self.assertEqual(exported, "")
                self.assertIn("simulators-before.json", evidence)

    def test_creation_and_boot_failures_do_not_export_a_destination(self):
        for command in ("list", "create", "boot", "bootstatus"):
            with self.subTest(command=command):
                result, calls, exported, _ = self.run_fixture(fail_at=command)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(exported, "")
                self.assertEqual(calls[-1].split()[1], command)

    def test_malformed_creation_result_cannot_inject_environment_or_boot(self):
        result, calls, exported, _ = self.run_fixture(invalid_id=True)
        self.assertEqual(result.returncode, 70)
        self.assertEqual(exported, "")
        self.assertFalse(any(" boot" in call for call in calls))

    def test_readback_requires_booted_exact_model_and_runtime(self):
        for options in ({"ready": False}, {"wrong_runtime": True}, {"wrong_type": True}):
            with self.subTest(options=options):
                result, _, exported, evidence = self.run_fixture(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(exported, "")
                self.assertIn("simulators-ready.json", evidence)

    def test_invalid_shard_has_no_simulator_side_effects(self):
        for shard in ("", "2", "-1", "unknown"):
            with self.subTest(shard=shard):
                result, calls, exported, _ = self.run_fixture(shard=shard)
                self.assertEqual(result.returncode, 64)
                self.assertEqual(calls, [])
                self.assertEqual(exported, "")


if __name__ == "__main__":
    unittest.main()
