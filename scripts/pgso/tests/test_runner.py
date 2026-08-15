from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import shlex
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from scripts.pgso.model import PgsoError
from scripts.pgso.runner import run_checked


class PgsoRunnerTests(unittest.TestCase):
    def test_child_output_is_visible_before_the_command_finishes(self) -> None:
        class LiveOutput(io.StringIO):
            def __init__(self) -> None:
                super().__init__()
                self.marker_seen = threading.Event()

            def write(self, value: str) -> int:
                written = super().write(value)
                if "early output" in value:
                    self.marker_seen.set()
                return written

        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            stdout = LiveOutput()
            errors: list[Exception] = []

            def invoke() -> None:
                try:
                    run_checked(
                        [
                            sys.executable,
                            "-c",
                            (
                                "import time; "
                                "print('early output', flush=True); "
                                "time.sleep(1)"
                            ),
                        ],
                        cwd=root,
                        env=os.environ.copy(),
                        timeout_s=5,
                        log_path=root / "live-before-exit.json",
                    )
                except Exception as error:
                    errors.append(error)

            with contextlib.redirect_stdout(stdout):
                worker = threading.Thread(target=invoke, daemon=True)
                worker.start()
                observed_while_running = stdout.marker_seen.wait(timeout=0.5)
                command_still_running = worker.is_alive()
                worker.join(timeout=3)

            self.assertTrue(observed_while_running)
            self.assertTrue(command_still_running)
            self.assertFalse(worker.is_alive())
            self.assertEqual([], errors)

    def test_silent_command_emits_periodic_heartbeats(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            stdout = io.StringIO()

            with (
                contextlib.redirect_stdout(stdout),
                mock.patch(
                    "scripts.pgso.runner.COMMAND_HEARTBEAT_SECONDS",
                    0.05,
                    create=True,
                ),
            ):
                run_checked(
                    [sys.executable, "-c", "import time; time.sleep(0.2)"],
                    cwd=root,
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=root / "heartbeat.json",
                )

            output = stdout.getvalue()
            self.assertRegex(
                output,
                r"\[pgso\] command still running after \d+\.\d+s",
            )
            self.assertIn("heartbeat.json", output)

    def test_success_streams_command_lifecycle_and_child_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            stdout = io.StringIO()
            stderr = io.StringIO()

            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                run_checked(
                    [
                        sys.executable,
                        "-c",
                        (
                            "import sys; "
                            "print('live stdout', flush=True); "
                            "print('live stderr', file=sys.stderr, flush=True)"
                        ),
                    ],
                    cwd=root,
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=root / "live.json",
                )

            output = stdout.getvalue()
            self.assertIn("[pgso] command started", output)
            self.assertIn("live stdout\n", output)
            self.assertRegex(output, r"\[pgso\] command passed in \d+\.\d{3}s")
            self.assertLess(output.index("command started"), output.index("live stdout"))
            self.assertLess(output.index("live stdout"), output.index("command passed"))
            self.assertIn("live stderr\n", stderr.getvalue())

    def test_failure_streams_terminal_status_after_child_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-runner-") as tmp:
            root = pathlib.Path(tmp)
            stdout = io.StringIO()

            with (
                contextlib.redirect_stdout(stdout),
                self.assertRaisesRegex(PgsoError, "command failed with exit code 7"),
            ):
                run_checked(
                    [
                        sys.executable,
                        "-c",
                        "print('failure detail', flush=True); raise SystemExit(7)",
                    ],
                    cwd=root,
                    env=os.environ.copy(),
                    timeout_s=5,
                    log_path=root / "failure.json",
                )

            output = stdout.getvalue()
            self.assertIn("failure detail\n", output)
            self.assertRegex(output, r"\[pgso\] command failed in \d+\.\d{3}s")
            self.assertLess(output.index("failure detail"), output.index("command failed"))

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
            script = root / "timeout-fixture.sh"
            script.write_text(
                "#!/bin/sh\n"
                f"(sleep 1; printf survived > {shlex.quote(str(marker))}) &\n"
                "printf 'started\\n'\n"
                "sleep 30\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(PgsoError, "timed out after 0.5 seconds"):
                run_checked(
                    ["/bin/sh", str(script)],
                    cwd=root,
                    env=os.environ.copy(),
                    timeout_s=0.5,
                    log_path=log_path,
                )

            time.sleep(1.2)
            self.assertFalse(marker.exists())
            log = json.loads(log_path.read_text())
            self.assertEqual("timed_out", log["status"])
            self.assertIn("started\n", log["stdout"])


if __name__ == "__main__":
    unittest.main()
