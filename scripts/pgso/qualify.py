from __future__ import annotations

import dataclasses
import json
import math
import os
import pathlib
import uuid
from collections.abc import Callable, Mapping, Sequence

from scripts.pgso.model import PgsoError
from scripts.pgso.pipeline import (
    ArtifactSpec,
    PipelinePaths,
    apply_profile,
    build_control,
    build_instrumented,
    collect_instrumented_profile,
    emit_bitcode,
    link_candidate,
    merge_profile_batch,
    read_macos_minos,
)
from scripts.pgso.runner import run_checked
from scripts.pgso.toolchain import Toolchain


MINIMUM_SAMPLES = 50
MAXIMUM_REGRESSION = 0.10
REQUIRED_EVIDENCE = (
    "identity",
    "runtime",
    "artifacts",
    "corpus",
    "startup",
    "heavy_workloads",
)

STARTUP_COMMANDS = (
    ("help", ("help",)),
    ("version", ("--version",)),
    ("status", ("status", "--json")),
    ("background", ("background", "--json")),
    ("doctor", ("doctor", "--json")),
    ("sessions", ("sessions", "--json")),
)


@dataclasses.dataclass(frozen=True)
class Workload:
    name: str
    argv: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class BenchmarkPlan:
    selector: str
    training_argvs: tuple[tuple[str, ...], ...]
    workloads: tuple[Workload, ...]


@dataclasses.dataclass(frozen=True)
class BenchmarkPair:
    selector: str
    control_binary: pathlib.Path
    candidate_binary: pathlib.Path
    bitcode_sha256: str
    merged_raw_profiles: int


BENCHMARK_PLANS = (
    BenchmarkPlan(
        selector="file_index",
        training_argvs=(("100000", "500"),),
        workloads=(Workload("file-index-100k", ("100000", "500")),),
    ),
    BenchmarkPlan(
        selector="ui_activity",
        training_argvs=((),),
        workloads=(Workload("ui-activity", ()),),
    ),
    BenchmarkPlan(
        selector="approval_review",
        training_argvs=(
            ("transcript", "3", "1"),
            ("diff", "3", "1"),
            ("combined", "3", "1"),
            ("payload", "3", "1"),
        ),
        workloads=(
            Workload("approval-transcript", ("transcript", "1", "1")),
            Workload("approval-diff", ("diff", "1", "1")),
            Workload("approval-combined", ("combined", "1", "1")),
            Workload("approval-payload", ("payload", "1", "1")),
        ),
    ),
)


@dataclasses.dataclass(frozen=True)
class Comparison:
    control_samples: tuple[float, ...]
    candidate_samples: tuple[float, ...]
    control_p50: float
    control_p95: float
    candidate_p50: float
    candidate_p95: float
    p50_change: float
    p95_change: float
    passed: bool


@dataclasses.dataclass(frozen=True)
class MeasurementResult:
    name: str
    argv: tuple[str, ...]
    requested_samples: int
    control_samples: tuple[float, ...]
    candidate_samples: tuple[float, ...]
    control_failures: int
    candidate_failures: int
    errors: tuple[str, ...]
    comparison: Comparison | None
    passed: bool


class EvidenceRecorder:
    def __init__(
        self,
        path: pathlib.Path,
        *,
        command: str,
        configuration: Mapping[str, object],
    ) -> None:
        self.path = path
        self.payload: dict[str, object] = {
            "schema_version": 1,
            "command": command,
            "configuration": dict(configuration),
            "status": "running",
            "stage": "initialize",
            "eligible": False,
            "error": None,
            "evidence": {},
            "stages": [],
        }
        self._write()

    def _write(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(
            f".{self.path.name}.{uuid.uuid4().hex}.tmp"
        )
        temporary.write_text(
            json.dumps(self.payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, self.path)

    def stage(
        self,
        name: str,
        status: str,
        evidence: Mapping[str, object] | None = None,
    ) -> None:
        if status not in ("running", "passed"):
            raise PgsoError(f"invalid evidence stage status: {status}")
        if self.payload["status"] == "failed":
            raise PgsoError("cannot update a failed evidence manifest")
        self.payload["stage"] = name
        self.payload["status"] = "running"
        stages = self.payload["stages"]
        if not isinstance(stages, list):
            raise PgsoError("invalid in-memory evidence stage list")
        stages.append({"name": name, "status": status})
        if evidence:
            recorded = self.payload["evidence"]
            if not isinstance(recorded, dict):
                raise PgsoError("invalid in-memory evidence mapping")
            recorded.update(evidence)
        self._write()

    def fail(self, stage: str, error: Exception) -> None:
        self.payload["stage"] = stage
        self.payload["status"] = "failed"
        self.payload["eligible"] = False
        self.payload["error"] = str(error)
        stages = self.payload["stages"]
        if isinstance(stages, list):
            stages.append({"name": stage, "status": "failed"})
        self._write()

    def complete(self) -> None:
        evidence = self.payload["evidence"]
        if not isinstance(evidence, dict):
            raise PgsoError("invalid in-memory evidence mapping")
        missing = tuple(key for key in REQUIRED_EVIDENCE if key not in evidence)
        if missing:
            raise PgsoError(
                "required evidence is incomplete: " + ", ".join(missing)
            )
        self.payload["stage"] = "complete"
        self.payload["status"] = "passed"
        self.payload["eligible"] = True
        self.payload["error"] = None
        stages = self.payload["stages"]
        if isinstance(stages, list):
            stages.append({"name": "complete", "status": "passed"})
        self._write()

    def finish_partial(self, stage: str) -> None:
        if self.payload["status"] == "failed":
            raise PgsoError("cannot finish a failed evidence manifest")
        self.payload["stage"] = stage
        self.payload["status"] = "passed"
        self.payload["eligible"] = False
        self.payload["error"] = None
        stages = self.payload["stages"]
        if isinstance(stages, list):
            stages.append({"name": stage, "status": "passed"})
        self._write()


def percentile(samples: Sequence[float], fraction: float) -> float:
    if not samples:
        raise PgsoError("percentile requires at least one sample")
    if not 0 < fraction <= 1:
        raise PgsoError("percentile fraction must be in (0, 1]")
    if not all(math.isfinite(sample) and sample >= 0 for sample in samples):
        raise PgsoError("samples must be finite nonnegative values")
    ordered = sorted(samples)
    rank = max(1, math.ceil(fraction * len(ordered)))
    return ordered[rank - 1]


def _change(control: float, candidate: float) -> float:
    if control <= 0:
        raise PgsoError("control percentile must be positive")
    return candidate / control - 1.0


def compare_samples(
    control_samples: Sequence[float],
    candidate_samples: Sequence[float],
    *,
    minimum_samples: int = MINIMUM_SAMPLES,
    maximum_regression: float = MAXIMUM_REGRESSION,
) -> Comparison:
    if len(control_samples) < minimum_samples or len(candidate_samples) < minimum_samples:
        raise PgsoError(
            f"comparison requires at least {minimum_samples} samples per artifact"
        )
    if maximum_regression < 0:
        raise PgsoError("maximum regression must be nonnegative")
    control = tuple(control_samples)
    candidate = tuple(candidate_samples)
    control_p50 = percentile(control, 0.50)
    control_p95 = percentile(control, 0.95)
    candidate_p50 = percentile(candidate, 0.50)
    candidate_p95 = percentile(candidate, 0.95)
    p50_change = _change(control_p50, candidate_p50)
    p95_change = _change(control_p95, candidate_p95)
    passed = (
        candidate_p50 <= control_p50 * (1.0 + maximum_regression)
        and candidate_p95 <= control_p95 * (1.0 + maximum_regression)
    )
    return Comparison(
        control_samples=control,
        candidate_samples=candidate,
        control_p50=control_p50,
        control_p95=control_p95,
        candidate_p50=candidate_p50,
        candidate_p95=candidate_p95,
        p50_change=p50_change,
        p95_change=p95_change,
        passed=passed,
    )


def measure_alternating(
    *,
    name: str,
    control_binary: pathlib.Path,
    candidate_binary: pathlib.Path,
    argv: Sequence[str],
    samples: int,
    sample_runner: Callable[[str, pathlib.Path, tuple[str, ...], int], float],
) -> MeasurementResult:
    if samples < MINIMUM_SAMPLES:
        raise PgsoError(
            f"qualification requires at least {MINIMUM_SAMPLES} samples"
        )
    control_samples: list[float] = []
    candidate_samples: list[float] = []
    control_failures = 0
    candidate_failures = 0
    errors: list[str] = []
    arguments = tuple(argv)

    for sample_index in range(samples):
        order = (
            (("control", control_binary), ("candidate", candidate_binary))
            if sample_index % 2 == 0
            else (("candidate", candidate_binary), ("control", control_binary))
        )
        for label, binary in order:
            try:
                elapsed = sample_runner(label, binary, arguments, sample_index)
                if not math.isfinite(elapsed) or elapsed <= 0:
                    raise PgsoError("sample duration must be finite and positive")
                if label == "control":
                    control_samples.append(elapsed)
                else:
                    candidate_samples.append(elapsed)
            except Exception as error:
                errors.append(f"{label}[{sample_index}]: {error}")
                if label == "control":
                    control_failures += 1
                else:
                    candidate_failures += 1

    comparison: Comparison | None = None
    if (
        control_failures == 0
        and candidate_failures == 0
        and len(control_samples) >= MINIMUM_SAMPLES
        and len(candidate_samples) >= MINIMUM_SAMPLES
    ):
        comparison = compare_samples(control_samples, candidate_samples)
    passed = comparison is not None and comparison.passed
    return MeasurementResult(
        name=name,
        argv=arguments,
        requested_samples=samples,
        control_samples=tuple(control_samples),
        candidate_samples=tuple(candidate_samples),
        control_failures=control_failures,
        candidate_failures=candidate_failures,
        errors=tuple(errors),
        comparison=comparison,
        passed=passed,
    )


def _external_control_link_argv(
    toolchain: Toolchain,
    object_path: pathlib.Path,
    binary_path: pathlib.Path,
) -> tuple[str, ...]:
    return (
        str(toolchain.zig),
        "cc",
        "-target",
        toolchain.target,
        "-O2",
        "-Wl,-dead_strip",
        "-s",
        str(object_path),
        "-o",
        str(binary_path),
        "-lc",
    )


def build_external_o2_control(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> pathlib.Path:
    output = paths.root / "external-control"
    output.mkdir(parents=True, exist_ok=False)
    bitcode = output / paths.bitcode.name
    object_path = output / f"{paths.binary_name}.o"
    binary = output / paths.binary_name
    run_checked(
        (
            str(toolchain.opt),
            "-passes=default<O2>",
            str(paths.bitcode),
            "-o",
            str(bitcode),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "external-control-opt.json",
        require_empty_stderr=True,
    )
    run_checked(
        (
            str(toolchain.llc),
            "-filetype=obj",
            "-O=2",
            str(bitcode),
            "-o",
            str(object_path),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "external-control-object.json",
        require_empty_stderr=True,
    )
    run_checked(
        _external_control_link_argv(toolchain, object_path, binary),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "external-control-link.json",
        require_empty_stderr=True,
    )
    run_checked(
        (str(toolchain.strip), "-S", "-x", str(binary)),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=120,
        log_path=paths.logs / "external-control-strip.json",
        require_empty_stderr=True,
    )
    if not binary.is_file() or binary.stat().st_size == 0:
        raise PgsoError(f"external O2 control is missing or empty: {binary}")
    return binary


def build_benchmark_pair(
    toolchain: Toolchain,
    repo_root: pathlib.Path,
    output_root: pathlib.Path,
    plan: BenchmarkPlan,
) -> BenchmarkPair:
    paths = PipelinePaths.create(output_root, selector=plan.selector)
    spec = ArtifactSpec(repo_root=repo_root, selector=plan.selector)
    ordinary_control = build_control(toolchain, spec, paths)
    minimum_macos = read_macos_minos(
        toolchain,
        ordinary_control,
        paths.logs / "control-load-commands.json",
    )
    bitcode_sha256 = emit_bitcode(toolchain, spec, paths)
    external_control = build_external_o2_control(toolchain, paths)

    first_training = plan.training_argvs[0]
    raw_profiles = list(
        build_instrumented(
            toolchain,
            paths,
            minimum_macos,
            training_argv=first_training,
            training_name="training-1",
        )
    )
    for index, training_argv in enumerate(plan.training_argvs[1:], start=2):
        raw_profiles.extend(
            collect_instrumented_profile(
                toolchain,
                paths,
                training_argv=training_argv,
                training_name=f"training-{index}",
                timeout_s=300,
            )
        )
    merged_count = merge_profile_batch(
        toolchain,
        raw_profiles,
        paths.merged_profile,
        paths.logs / "merge-training.json",
    )
    emit_bitcode(
        toolchain,
        spec,
        paths,
        expected_sha256=bitcode_sha256,
    )
    apply_profile(toolchain, paths, bitcode_sha256)
    candidate = link_candidate(
        toolchain,
        paths,
        require_release_safe_evidence=False,
    )
    return BenchmarkPair(
        selector=plan.selector,
        control_binary=external_control,
        candidate_binary=candidate,
        bitcode_sha256=bitcode_sha256,
        merged_raw_profiles=merged_count,
    )


def _measurement_environment(home: pathlib.Path) -> dict[str, str]:
    environment = os.environ.copy()
    for key in ("AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN", "LLVM_PROFILE_FILE"):
        environment.pop(key, None)
    environment.update(
        {
            "FX_AUTO_UPGRADE": "0",
            "FX_SKIP_ONBOARDING": "1",
            "FX_SOUND": "0",
            "HOME": str(home),
            "NO_COLOR": "1",
        }
    )
    return environment


def measure_startup(
    *,
    repo_root: pathlib.Path,
    control_binary: pathlib.Path,
    candidate_binary: pathlib.Path,
    output_dir: pathlib.Path,
    samples: int,
    timeout_s: float,
) -> tuple[MeasurementResult, ...]:
    home = output_dir / "home"
    logs = output_dir / "logs"
    home.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    results: list[MeasurementResult] = []

    for command_name, command_argv in STARTUP_COMMANDS:
        def sample_runner(
            label: str,
            binary: pathlib.Path,
            argv: tuple[str, ...],
            sample_index: int,
        ) -> float:
            result = run_checked(
                (str(binary), *argv),
                cwd=repo_root,
                env=_measurement_environment(home),
                timeout_s=timeout_s,
                log_path=logs / f"{command_name}-{sample_index:03d}-{label}.json",
                require_empty_stderr=True,
            )
            if not result.stdout.strip():
                raise PgsoError(f"startup command produced empty stdout: {command_name}")
            return result.elapsed_seconds

        results.append(
            measure_alternating(
                name=f"startup-{command_name}",
                control_binary=control_binary,
                candidate_binary=candidate_binary,
                argv=command_argv,
                samples=samples,
                sample_runner=sample_runner,
            )
        )
    return tuple(results)


def measure_heavy_workloads(
    *,
    toolchain: Toolchain,
    repo_root: pathlib.Path,
    output_dir: pathlib.Path,
    samples: int,
    timeout_s: float,
) -> tuple[MeasurementResult, ...]:
    output_dir.mkdir(parents=True, exist_ok=False)
    home = output_dir / "home"
    logs = output_dir / "logs"
    home.mkdir()
    logs.mkdir()
    results: list[MeasurementResult] = []

    for plan in BENCHMARK_PLANS:
        pair = build_benchmark_pair(
            toolchain,
            repo_root,
            output_dir / plan.selector,
            plan,
        )
        for workload in plan.workloads:
            workload_logs = logs / workload.name

            def sample_runner(
                label: str,
                binary: pathlib.Path,
                argv: tuple[str, ...],
                sample_index: int,
            ) -> float:
                result = run_checked(
                    (str(binary), *argv),
                    cwd=repo_root,
                    env=_measurement_environment(home),
                    timeout_s=timeout_s,
                    log_path=(
                        workload_logs
                        / f"{sample_index:03d}-{label}.json"
                    ),
                    require_empty_stderr=True,
                )
                if not result.stdout.strip():
                    raise PgsoError(
                        f"heavy workload produced empty stdout: {workload.name}"
                    )
                return result.elapsed_seconds

            results.append(
                measure_alternating(
                    name=workload.name,
                    control_binary=pair.control_binary,
                    candidate_binary=pair.candidate_binary,
                    argv=workload.argv,
                    samples=samples,
                    sample_runner=sample_runner,
                )
            )
    return tuple(results)


def measurement_payload(
    results: Sequence[MeasurementResult],
) -> list[dict[str, object]]:
    return [dataclasses.asdict(result) for result in results]


def require_measurements_passed(
    label: str,
    results: Sequence[MeasurementResult],
) -> None:
    failed = tuple(result.name for result in results if not result.passed)
    if failed:
        raise PgsoError(f"{label} qualification failed: {', '.join(failed)}")
