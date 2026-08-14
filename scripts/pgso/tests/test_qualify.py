from __future__ import annotations

import json
import pathlib
import tempfile
import unittest

from scripts.pgso.model import PgsoError, sha256_file
from scripts.pgso.qualify import (
    BENCHMARK_PLANS,
    STARTUP_COMMANDS,
    EvidenceRecorder,
    compare_samples,
    install_binary,
    measure_alternating,
    percentile,
)


class PgsoQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="fx-pgso-qualify-"
        )
        self.root = pathlib.Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_percentile_uses_nearest_rank(self) -> None:
        samples = tuple(float(value) for value in range(1, 101))

        self.assertEqual(50.0, percentile(samples, 0.50))
        self.assertEqual(95.0, percentile(samples, 0.95))

    def test_production_plans_cover_six_startup_and_six_heavy_workloads(self) -> None:
        self.assertEqual(6, len(STARTUP_COMMANDS))
        workload_names = tuple(
            workload.name
            for plan in BENCHMARK_PLANS
            for workload in plan.workloads
        )
        self.assertEqual(
            (
                "file-index-100k",
                "ui-activity",
                "approval-transcript",
                "approval-diff",
                "approval-combined",
                "approval-payload",
            ),
            workload_names,
        )
        self.assertEqual(
            ("file_index", "ui_activity", "approval_review"),
            tuple(plan.selector for plan in BENCHMARK_PLANS),
        )

    def test_comparison_requires_fifty_samples_per_artifact(self) -> None:
        with self.assertRaisesRegex(PgsoError, "at least 50"):
            compare_samples((1.0,) * 49, (1.0,) * 50)

    def test_comparison_accepts_the_boundary_and_rejects_either_regression(self) -> None:
        boundary = compare_samples((10.0,) * 50, (11.0,) * 50)
        self.assertTrue(boundary.passed)

        p50_regression = compare_samples((10.0,) * 50, (11.01,) * 50)
        self.assertFalse(p50_regression.passed)

        p95_candidate = (10.0,) * 47 + (20.0,) * 3
        p95_regression = compare_samples((10.0,) * 50, p95_candidate)
        self.assertFalse(p95_regression.passed)

    def test_measurement_alternates_ab_and_ba_order(self) -> None:
        order: list[tuple[str, int]] = []

        def sample_runner(label, binary, argv, sample_index):
            order.append((label, sample_index))
            return 1.0 if label == "control" else 0.9

        result = measure_alternating(
            name="startup-help",
            control_binary=self.root / "control",
            candidate_binary=self.root / "candidate",
            argv=("help",),
            samples=50,
            sample_runner=sample_runner,
        )

        self.assertEqual(
            [
                ("control", 0),
                ("candidate", 0),
                ("candidate", 1),
                ("control", 1),
            ],
            order[:4],
        )
        self.assertEqual(0, result.control_failures)
        self.assertEqual(0, result.candidate_failures)
        self.assertTrue(result.passed)
        self.assertIsNotNone(result.comparison)

    def test_measurement_counts_failures_without_replacement(self) -> None:
        def sample_runner(label, binary, argv, sample_index):
            if label == "candidate" and sample_index == 3:
                raise PgsoError("candidate failed")
            return 1.0

        result = measure_alternating(
            name="startup-help",
            control_binary=self.root / "control",
            candidate_binary=self.root / "candidate",
            argv=("help",),
            samples=50,
            sample_runner=sample_runner,
        )

        self.assertEqual(0, result.control_failures)
        self.assertEqual(1, result.candidate_failures)
        self.assertFalse(result.passed)
        self.assertIsNone(result.comparison)
        self.assertEqual(49, len(result.candidate_samples))

    def test_binary_installation_copies_and_verifies_the_exact_hash(self) -> None:
        source = self.root / "candidate"
        destination = self.root / "zig-out" / "bin" / "fx"
        source.write_bytes(b"candidate-binary")

        installed = install_binary(source, destination, sha256_file(source))

        self.assertEqual(destination, installed)
        self.assertEqual(sha256_file(source), sha256_file(destination))

    def test_binary_installation_rejects_a_canonical_symlink(self) -> None:
        source = self.root / "candidate"
        source.write_bytes(b"candidate-binary")
        destination = self.root / "zig-out" / "bin" / "fx"
        destination.parent.mkdir(parents=True)
        destination.symlink_to(source)

        with self.assertRaisesRegex(PgsoError, "cannot be a symlink"):
            install_binary(source, destination, sha256_file(source))

    def test_evidence_recorder_is_fail_closed_and_writes_atomically(self) -> None:
        manifest = self.root / "manifest.json"
        recorder = EvidenceRecorder(
            manifest,
            command="all",
            configuration={"target": "aarch64-macos", "samples": 50},
        )
        recorder.stage("validate", "passed", {"source_sha": "a" * 40})
        recorder.fail("profile-use", PgsoError("optimizer warning"))

        payload = json.loads(manifest.read_text())
        self.assertEqual(1, payload["schema_version"])
        self.assertEqual("failed", payload["status"])
        self.assertEqual("profile-use", payload["stage"])
        self.assertFalse(payload["eligible"])
        self.assertEqual("optimizer warning", payload["error"])
        self.assertFalse(any(self.root.glob(".manifest.json.*.tmp")))

    def test_evidence_recorder_cannot_mark_incomplete_work_eligible(self) -> None:
        recorder = EvidenceRecorder(
            self.root / "manifest.json",
            command="all",
            configuration={"target": "aarch64-macos", "samples": 50},
        )
        with self.assertRaisesRegex(PgsoError, "required evidence"):
            recorder.complete()


if __name__ == "__main__":
    unittest.main()
