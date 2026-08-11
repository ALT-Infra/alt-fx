#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    import yaml  # type: ignore[import-not-found]
except ImportError:
    yaml = None


REPO_ROOT = Path(__file__).resolve().parents[2]
EVALS_ROOT = REPO_ROOT / "evals"
DATASETS_ROOT = EVALS_ROOT / "datasets"
JOBS_ROOT = EVALS_ROOT / "jobs"
TASK_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*$")
GENERATED_PREFIXES = (
    "evals/.build/",
    "evals/jobs-out/",
    "evals/images/fx",
)


def parse_value(raw: str) -> Any:
    value = raw.strip()
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    if value in ("true", "false"):
        return value == "true"
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        if inner.startswith("{"):
            return [inner]
        return [parse_value(item.strip()) for item in inner.split(",")]
    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def load_toml(path: Path) -> dict[str, Any]:
    data: dict[str, Any] = {}
    current: dict[str, Any] = data
    current_step: dict[str, Any] | None = None

    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped == "[[steps]]":
            steps = data.setdefault("steps", [])
            if not isinstance(steps, list):
                raise ValueError(f"steps was not a list in {path}")
            current_step = {}
            steps.append(current_step)
            current = current_step
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped.strip("[]")
            if section.startswith("steps."):
                if current_step is None:
                    raise ValueError(f"{section} appeared before [[steps]] in {path}")
                target = current_step
                for part in section.split(".")[1:]:
                    child = target.setdefault(part, {})
                    if not isinstance(child, dict):
                        raise ValueError(f"{section} conflicted with an existing value in {path}")
                    target = child
                current = target
            else:
                target = data
                for part in section.split("."):
                    child = target.setdefault(part, {})
                    if not isinstance(child, dict):
                        raise ValueError(f"{section} conflicted with an existing value in {path}")
                    target = child
                current = target
            continue
        if "=" not in stripped:
            continue
        key, raw_value = stripped.split("=", 1)
        current[key.strip()] = parse_value(raw_value)

    return data


def rel(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def fail(errors: list[str], path: Path, message: str) -> None:
    errors.append(f"{rel(path)}: {message}")


def check_task(path: Path, errors: list[str]) -> None:
    data = load_toml(path)
    task = data.get("task")
    if not isinstance(task, dict):
        fail(errors, path, "missing [task] section")
        return

    name = task.get("name")
    if not isinstance(name, str) or not TASK_NAME_RE.match(name):
        fail(errors, path, "task.name must be org/name with lowercase slug segments")
    elif name.rsplit("/", 1)[1] != path.parent.name:
        fail(errors, path, "task.name suffix must match the task directory name")

    environment = data.get("environment")
    if not isinstance(environment, dict):
        fail(errors, path, "missing [environment] section")
    elif not (path.parent / "environment" / "Dockerfile").is_file():
        fail(errors, path, "missing environment/Dockerfile")

    steps = data.get("steps")
    if steps is None:
        for required in ("instruction.md", "solution/solve.sh", "tests/test.sh"):
            if not (path.parent / required).is_file():
                fail(errors, path, f"missing {required}")
        return

    if not isinstance(steps, list) or not steps:
        fail(errors, path, "steps must be a non-empty list for multi-step tasks")
        return

    for step in steps:
        if not isinstance(step, dict):
            fail(errors, path, "each step entry must be a table")
            continue
        step_name = step.get("name")
        if not isinstance(step_name, str) or not step_name:
            fail(errors, path, "each step must have a name")
            continue
        step_dir = path.parent / "steps" / step_name
        for required in ("instruction.md", "solution/solve.sh", "tests/test.sh"):
            if not (step_dir / required).is_file():
                fail(errors, path, f"missing steps/{step_name}/{required}")


def check_dataset(path: Path, errors: list[str]) -> None:
    data = load_toml(path)
    dataset = data.get("dataset")
    if not isinstance(dataset, dict):
        fail(errors, path, "missing [dataset] section")
        return

    name = dataset.get("name")
    if not isinstance(name, str) or not TASK_NAME_RE.match(name):
        fail(errors, path, "dataset.name must be org/name with lowercase slug segments")

    authors = dataset.get("authors")
    if not isinstance(authors, list) or not authors:
        fail(errors, path, "dataset.authors must list at least one author")

    task_paths = sorted(path.parent.glob("*/task.toml"))
    if not task_paths:
        fail(errors, path, "dataset directory must contain at least one task")
    for task_path in task_paths:
        check_task(task_path, errors)


def check_metric_scripts(errors: list[str]) -> None:
    metric_path = EVALS_ROOT / "metrics" / "fx_metrics.py"
    if not metric_path.is_file():
        fail(errors, metric_path, "shared metric script is missing")
        return
    text = metric_path.read_text(encoding="utf-8")
    for needle in ("# /// script", "dependencies = []", "--input-path", "--output-path"):
        if needle not in text:
            fail(errors, metric_path, f"missing metric marker {needle!r}")

    local_metric = DATASETS_ROOT / "fx-release" / "metric.py"
    if local_metric.is_file():
        local_text = local_metric.read_text(encoding="utf-8")
        if "metrics" not in local_text or "fx_metrics.py" not in local_text:
            fail(errors, local_metric, "local dataset metric should delegate to fx_metrics.py")


def parse_job(path: Path) -> dict[str, Any] | None:
    if yaml is None:
        return None
    value = yaml.safe_load(path.read_text(encoding="utf-8"))
    return value if isinstance(value, dict) else None


def check_job_config(path: Path, errors: list[str]) -> None:
    text = path.read_text(encoding="utf-8")
    for key in ("jobs_dir:", "agents:", "datasets:", "metrics:", "artifacts:"):
        if key not in text:
            fail(errors, path, f"missing {key}")
    if "script_path: evals/metrics/fx_metrics.py" not in text:
        fail(errors, path, "missing shared metric script_path")

    parsed = parse_job(path)
    if parsed is None:
        return

    datasets = parsed.get("datasets")
    if not isinstance(datasets, list) or not datasets:
        fail(errors, path, "datasets must be a non-empty list")
    else:
        for dataset in datasets:
            if not isinstance(dataset, dict):
                fail(errors, path, "dataset entries must be maps")
                continue
            if "path" in dataset:
                dataset_path = REPO_ROOT / str(dataset["path"])
                if not dataset_path.is_dir():
                    fail(errors, path, f"local dataset path does not exist: {dataset['path']}")
            elif "name" not in dataset:
                fail(errors, path, "dataset entry must have path or name")

    metrics = parsed.get("metrics")
    if not isinstance(metrics, list) or not metrics:
        fail(errors, path, "metrics must be a non-empty list")


def check_generated_outputs(errors: list[str]) -> None:
    tracked = subprocess.run(
        ["git", "ls-files", "--", "evals"],
        cwd=REPO_ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout.splitlines()

    for path in tracked:
        if path.endswith(".pyc") or "/__pycache__/" in path:
            errors.append(f"{path}: generated Python cache must not be tracked")
        if any(is_generated_path(path, prefix) for prefix in GENERATED_PREFIXES):
            errors.append(f"{path}: generated Harbor output must not be tracked")


def is_generated_path(path: str, prefix: str) -> bool:
    if prefix.endswith("/"):
        return path.startswith(prefix)
    return path == prefix


def main() -> int:
    errors: list[str] = []

    for dataset_path in sorted(DATASETS_ROOT.glob("*/dataset.toml")):
        check_dataset(dataset_path, errors)

    check_metric_scripts(errors)

    for job_path in sorted(JOBS_ROOT.glob("*.yaml")):
        check_job_config(job_path, errors)

    check_generated_outputs(errors)

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print("publish readiness checks passed")
    print("checked local datasets, task names, metric scripts, job configs, and tracked generated outputs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
