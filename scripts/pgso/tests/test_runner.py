from __future__ import annotations

import json
import os
import pathlib
import sys
import tempfile
import time
import unittest

from scripts.pgso.model import PgsoError
from scripts.pgso.runner import run_checked


class PgsoRunnerTests(unittest.TestCase):
    def test_success_captures_output_and_writes_a_bounded_log(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            log_path = pathlib.Path(tmp) / "stage.json"
            env = os.environ.copy()
            env["PGSO_TEST_SECRET"] = "must-not-be-logged"

            result = run_checked(
                [
                    sys.executable,
                    "-c",
                    "import sys; print('stdout'); print('stderr', file=sys.stderr)",
                ],
                cwd=pathlib.Path(tmp),
                env=env,
                timeout_s=5,
                log_path=log_path,
            )

            self.assertEqual(0, result.returncode)
            self.assertEqual("stdout\n", result.stdout)
            self.assertEqual("stderr\n", result.stderr)
            self.assertGreaterEqual(result.elapsed_seconds, 0)
            log = json.loads(log_path.read_text())
            self.assertEqual(pathlib.Path(sys.executable).name, log["command_class"])
            self.assertEqual("passed", log["status"])
            self.assertNotIn("environment", log)
            self.assertNotIn("must-not-be-logged", log_path.read_text())

    def test_nonzero_exit_raises_after_logging_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            log_path = pathlib.Path(tmp) / "stage.json"

            with self.assertRaisesRegex(
                PgsoError,
                "command failed with exit code 7",
            ):
                run_checked(
                    [
                        sys.executable,
                        "-c",
                        "import sys; print('before failure'); sys.exit(7)",
                    ],
                    cwd=pathlib.Path(tmp),
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=log_path,
                )

            log = json.loads(log_path.read_text())
            self.assertEqual(7, log["returncode"])
            self.assertEqual("before failure\n", log["stdout"])
            self.assertEqual("failed", log["status"])

    def test_empty_stderr_policy_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            log_path = pathlib.Path(tmp) / "stage.json"

            with self.assertRaisesRegex(PgsoError, "wrote unexpected stderr"):
                run_checked(
                    [
                        sys.executable,
                        "-c",
                        "import sys; print('optimizer warning', file=sys.stderr)",
                    ],
                    cwd=pathlib.Path(tmp),
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=log_path,
                    require_empty_stderr=True,
                )

            log = json.loads(log_path.read_text())
            self.assertEqual("unexpected_stderr", log["status"])
            self.assertEqual("optimizer warning\n", log["stderr"])

    def test_missing_executable_fails_closed_and_writes_a_log(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            log_path = pathlib.Path(tmp) / "stage.json"

            with self.assertRaisesRegex(PgsoError, "executable not found"):
                run_checked(
                    [str(pathlib.Path(tmp) / "missing-command")],
                    cwd=pathlib.Path(tmp),
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=log_path,
                )

            log = json.loads(log_path.read_text())
            self.assertEqual("spawn_failed", log["status"])
            self.assertIsNone(log["returncode"])

    def test_timeout_terminates_the_whole_process_group(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            marker = root / "child-survived"
            log_path = root / "stage.json"
            child_code = (
                "import pathlib,time; time.sleep(0.5); "
                f"pathlib.Path({str(marker)!r}).write_text('survived')"
            )
            parent_code = (
                "import subprocess,sys,time; "
                f"subprocess.Popen([sys.executable, '-c', {child_code!r}]); "
                "print('started', flush=True); time.sleep(30)"
            )

            with self.assertRaisesRegex(PgsoError, "timed out after 0.1 seconds"):
                run_checked(
                    [sys.executable, "-c", parent_code],
                    cwd=root,
                    env=os.environ.copy(),
                    timeout_s=0.1,
                    log_path=log_path,
                )

            time.sleep(0.8)
            self.assertFalse(marker.exists())
            log = json.loads(log_path.read_text())
            self.assertEqual("timed_out", log["status"])
            self.assertIn("started\n", log["stdout"])


if __name__ == "__main__":
    unittest.main()
