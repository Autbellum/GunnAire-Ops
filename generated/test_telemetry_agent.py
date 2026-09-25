"""Focused checks for the launch log summarizer."""

from pathlib import Path
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import telemetry_agent


def app_line(time: str, message: str) -> str:
    return f"2026-09-19 11:40:{time} Df GunnAire Ops[37811:3c8effc] {message}\n"


class TelemetryAgentTests(unittest.TestCase):
    def test_nonregular_inputs_are_rejected_without_opening_them(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fifo = Path(directory) / "capture.fifo"
            os.mkfifo(fifo)
            regular = Path(directory) / "capture.log"
            regular.write_text(app_line("57.100", "fatal error"), encoding="utf-8")
            link = Path(directory) / "capture-link.log"
            link.symlink_to(regular)
            for path in (fifo, Path(directory), Path("/dev/null"), link):
                with self.subTest(path=path), patch.object(telemetry_agent.os, "open", side_effect=AssertionError("must not open")):
                    result = telemetry_agent.analyze(path)
                self.assertEqual(result.state, "insufficient")
                self.assertIn("regular file", result.reason)
                self.assertFalse(result.findings)

    def test_replaced_nonregular_file_is_rejected_after_open(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            path.write_text(app_line("57.100", "fatal error"), encoding="utf-8")
            original_open = os.open

            def replace_with_fifo(path_to_open: Path, flags: int) -> int:
                self.assertTrue(flags & os.O_NONBLOCK, "A replacement FIFO must not wait for a writer")
                path.unlink()
                os.mkfifo(path)
                return original_open(path_to_open, flags)

            with patch.object(telemetry_agent.os, "open", side_effect=replace_with_fifo):
                result = telemetry_agent.analyze(path)
            self.assertEqual(result.state, "insufficient")
            self.assertIn("regular file", result.reason)
            self.assertFalse(result.findings)

    def test_file_growing_after_metadata_check_discards_partial_failure_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            path.write_text(app_line("57.100", "fatal error"), encoding="utf-8")
            original_fstat = os.fstat

            def metadata_before_growth(descriptor: int) -> os.stat_result:
                metadata = original_fstat(descriptor)
                with path.open("ab") as stream:
                    stream.write(b"x" * 256)
                return metadata

            with patch.object(telemetry_agent, "MAX_LOG_BYTES", 128), patch.object(
                telemetry_agent.os, "fstat", side_effect=metadata_before_growth
            ):
                result = telemetry_agent.analyze(path)
            self.assertEqual(result.state, "insufficient")
            self.assertIn("analysis limit", result.reason)
            self.assertEqual(result.captured_lines, 0)
            self.assertEqual(result.app_lines, 0)
            self.assertFalse(result.findings)
            self.assertIsNone(result.first_stamp)

    def test_input_at_exact_read_limit_is_analyzed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            data = app_line("57.100", "fatal error").encode("utf-8")
            path.write_bytes(data)
            with patch.object(telemetry_agent, "MAX_LOG_BYTES", len(data)):
                result = telemetry_agent.analyze(path)
            self.assertEqual(result.state, "issue-observed")
            self.assertEqual(len(result.findings), 1)

    def test_app_recorder_stalls_are_detected_without_logging_private_screen_names(self) -> None:
        for screen in ("The app", "private-customer-screen"):
            with self.subTest(screen=screen), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "capture.log"
                path.write_text(
                    app_line("57.100", f"[AppPerformance] Performance event: stall {screen} froze for 0.7 seconds"),
                    encoding="utf-8",
                )
                result = telemetry_agent.analyze(path)
                report = telemetry_agent.render(result)
                self.assertEqual(result.state, "issue-observed")
                self.assertEqual([finding.category for finding in result.findings], ["App-reported main-thread stall"])
                self.assertNotIn(screen, report)
                self.assertNotIn("froze for", report)

    def test_app_recorder_slow_launch_is_an_issue_and_retains_its_measured_time(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            path.write_text(
                app_line("57.100", "[AppPerformance] Performance event: slowLaunch Launch took 2.7 seconds")
                + app_line("58.100", "[AppPerformance] Performance event: launch Launched in 0.5 seconds"),
                encoding="utf-8",
            )
            result = telemetry_agent.analyze(path)
            self.assertEqual(result.state, "issue-observed")
            self.assertEqual(result.launch_seconds, [2.7, 0.5])
            self.assertEqual([finding.category for finding in result.findings], ["App-reported slow launch"])
            self.assertIn("2.700 s, 0.500 s", telemetry_agent.render(result))

    def test_recorder_signals_from_other_processes_and_unstructured_timings_are_not_app_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            path.write_text(
                app_line("57.100", "Performance event: stall Another screen froze for 0.7 seconds")
                .replace("GunnAire Ops[", "Another App[")
                + app_line("57.200", "Performance event: slowLaunch Launch took 2.7 seconds")
                .replace("GunnAire Ops[", "Another App[")
                + app_line("58.100", "A previous example said Launch took 2.7 seconds"),
                encoding="utf-8",
            )
            result = telemetry_agent.analyze(path)
            self.assertEqual(result.state, "limited-observation")
            self.assertEqual(result.app_lines, 1)
            self.assertFalse(result.findings)
            self.assertFalse(result.launch_seconds)

    def test_malformed_recorder_messages_are_not_reported_as_measured_events(self) -> None:
        messages = [
            "Performance event: stall private-screen froze for unknown seconds",
            "Performance event: stall private-screen froze for 0.7 widgets",
            "Performance event: slowLaunch Launch took unknown seconds",
            "Performance event: slowLaunch Launch took 2.7 widgets",
            "Performance event: slowLaunch Launched in 2.7 seconds",
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            path.write_text("".join(app_line("57.100", message) for message in messages), encoding="utf-8")
            result = telemetry_agent.analyze(path)
            self.assertEqual(result.state, "limited-observation")
            self.assertFalse(result.findings)
            self.assertFalse(result.launch_seconds)
            self.assertNotIn("private-screen", telemetry_agent.render(result))

    def test_launch_timing_and_benign_framework_lines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            path.write_text(
                'Filtering the log data using "main thread hang watchdog"\n'
                + app_line("57.100", "Authorization change notification received")
                + app_line("57.200", "[AppPerformance] Performance event: launch Launched in 0.5 seconds")
                + app_line("58.100", "No main thread hang observed"),
                encoding="utf-8",
            )
            result = telemetry_agent.analyze(path)
            self.assertEqual(result.state, "limited-observation")
            self.assertEqual(result.launch_seconds, [0.5])
            self.assertFalse(result.findings)
            self.assertIn("0.500 s", telemetry_agent.render(result))

    def test_real_failures_report_categories_without_raw_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            secret = "secret-token-from-provider"
            path.write_text(
                app_line("57.100", f"main thread stalled while processing {secret}")
                + app_line("58.100", f"watchdog termination after timeout {secret}")
                + app_line("59.100", f"fatal error: {secret}"),
                encoding="utf-8",
            )
            result = telemetry_agent.analyze(path)
            report = telemetry_agent.render(result)
            self.assertEqual(result.state, "issue-observed")
            self.assertEqual(len(result.findings), 3)
            self.assertIn("Main-thread stall", report)
            self.assertIn("Watchdog", report)
            self.assertIn("Crash signal", report)
            self.assertNotIn(secret, report)

    def test_multiline_springboard_process_exit_detects_app_crash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "system.log"
            secret = "private-provider-token"
            path.write_text(
                app_line("47.000", "[AppPerformance] Performance event: launch Launched in 0.5 seconds")
                + "2026-09-19 11:40:48.952 E SpringBoard[72422:3cebf71] [com.apple.FrontBoard:Scene] "
                  "sceneID:com.gunnaire.businesssuite-E1256BD2 Update failed {\n"
                + "  NSUnderlyingError = <FBProcessExit; code: 4 (\"crash\"); The process crashed.>\n"
                + f"  NSUnderlyingError = <signal; code: 5; SIGTRAP(5)>; {secret}\n"
                + "}\n",
                encoding="utf-8",
            )
            result = telemetry_agent.analyze(path)
            report = telemetry_agent.render(result)
            self.assertEqual(result.state, "issue-observed")
            self.assertEqual(result.findings[-1].category, "System-reported app process crash")
            self.assertNotIn(secret, report)

    def test_springboard_sigterm_during_test_cleanup_is_not_a_crash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "system.log"
            path.write_text(
                app_line("35.000", "Sign-in screen displayed")
                + "2026-09-19 11:40:35.922 E SpringBoard[72422:3cebf71] "
                  "sceneID:com.gunnaire.businesssuite-E1256BD2 Update failed {\n"
                + "  RBSProcessExitContext| specific, status:<RBSProcessExitStatus| "
                  "domain:signal(2) code:SIGTERM(15)>\n"
                + "}\n",
                encoding="utf-8",
            )
            result = telemetry_agent.analyze(path)
            self.assertEqual(result.state, "limited-observation")
            self.assertFalse(result.findings)

    def test_missing_empty_and_non_app_capture_are_insufficient(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            self.assertEqual(telemetry_agent.analyze(path).state, "insufficient")
            path.write_text("", encoding="utf-8")
            self.assertIn("empty", telemetry_agent.analyze(path).reason)
            path.write_text('Filtering the log data using "hang"\n', encoding="utf-8")
            result = telemetry_agent.analyze(path)
            self.assertIn("no timestamped", result.reason)
            self.assertIn("No app evidence was available", telemetry_agent.render(result))

    def test_cli_writes_report_and_uses_meaningful_status(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            input_path = Path(directory) / "capture.log"
            output_path = Path(directory) / "health.md"
            self.assertEqual(telemetry_agent.main(["--input", str(input_path), "--output", str(output_path)]), 2)
            self.assertTrue(output_path.exists())
            input_path.write_text(app_line("57.100", "main thread blocked"), encoding="utf-8")
            self.assertEqual(telemetry_agent.main(["--input", str(input_path), "--output", str(output_path)]), 1)
            self.assertIn("Issue observed", output_path.read_text(encoding="utf-8"))

    def test_default_does_not_recycle_stale_capture_and_simulator_failure_is_honest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "health.md"
            self.assertEqual(telemetry_agent.main(["--output", str(report_path)]), 2)
            self.assertIn("No capture selected", report_path.read_text(encoding="utf-8"))
            with patch.object(telemetry_agent.subprocess, "run") as run:
                run.return_value.returncode = 1
                result = telemetry_agent.analyze_simulator("6F017CC5-3DF2-455C-9217-E0074DF9418F")
            self.assertEqual(result.state, "insufficient")
            self.assertIn("capture failed", result.reason)


if __name__ == "__main__":
    unittest.main()
