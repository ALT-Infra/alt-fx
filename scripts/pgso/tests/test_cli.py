from __future__ import annotations

import json
import pathlib
import tempfile
import unittest
from unittest import mock

from scripts.pgso.__main__ import (
    ensure_fresh_output,
    load_read_only_manifest,
    parse_args,
    run_command,
)
from scripts.pgso.model import PgsoError


class PgsoCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="fx-pgso-cli-"
        )
        self.root = pathlib.Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def required_arguments(self, command: str = "all") -> list[str]:
        return [
            command,
            "--llvm-bin",
            "/opt/llvm/bin",
            "--output-dir",
            str(self.root / "output"),
        ]

    def test_all_command_exposes_the_production_defaults(self) -> None:
        arguments = parse_args(self.required_arguments())

        self.assertEqual("all", arguments.command)
        self.assertEqual("aarch64-macos", arguments.target)
        self.assertEqual("stable", arguments.update_channel)
        self.assertEqual(50, arguments.samples)
        self.assertGreater(arguments.timeout_seconds, 0)
        self.assertTrue(str(arguments.corpus).endswith("scripts/pgso/corpus.json"))

    def test_every_mutating_command_requires_toolchain_and_output(self) -> None:
        for command in ("build", "train", "qualify", "all"):
            with self.subTest(command=command):
                with self.assertRaises(SystemExit):
                    parse_args([command])

    def test_qualification_rejects_fewer_than_fifty_samples(self) -> None:
        for command in ("qualify", "all"):
            with self.subTest(command=command):
                with self.assertRaises(SystemExit):
                    parse_args([*self.required_arguments(command), "--samples", "49"])

    def test_fresh_output_rejects_nonempty_state(self) -> None:
        output = self.root / "output"
        output.mkdir()
        (output / "stale.profdata").write_bytes(b"stale")

        with self.assertRaisesRegex(PgsoError, "not empty"):
            ensure_fresh_output(output)

    def test_read_only_reporting_requires_an_existing_complete_manifest(self) -> None:
        output = self.root / "output"
        output.mkdir()
        manifest = output / "manifest.json"
        manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "status": "passed",
                    "stage": "complete",
                    "eligible": True,
                    "evidence": {
                        "identity": {},
                        "artifacts": {},
                        "corpus": {},
                        "startup": [],
                        "heavy_workloads": [],
                    },
                }
            )
        )

        payload = load_read_only_manifest(output)

        self.assertTrue(payload["eligible"])
        self.assertEqual("passed", payload["status"])

    def test_read_only_reporting_rejects_failed_or_incomplete_evidence(self) -> None:
        output = self.root / "output"
        output.mkdir()
        (output / "manifest.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "status": "failed",
                    "stage": "profile-use",
                    "eligible": False,
                }
            )
        )

        with self.assertRaisesRegex(PgsoError, "not eligible"):
            load_read_only_manifest(output)

    def test_driver_records_validation_failure_before_returning(self) -> None:
        arguments = parse_args(self.required_arguments())
        with mock.patch(
            "scripts.pgso.__main__.Toolchain.discover",
            side_effect=PgsoError("wrong LLVM version"),
        ):
            with self.assertRaisesRegex(PgsoError, "wrong LLVM version"):
                run_command(arguments)

        payload = json.loads(
            (arguments.output_dir / "manifest.json").read_text()
        )
        self.assertEqual("failed", payload["status"])
        self.assertEqual("validate", payload["stage"])
        self.assertFalse(payload["eligible"])
        self.assertEqual("wrong LLVM version", payload["error"])


if __name__ == "__main__":
    unittest.main()
