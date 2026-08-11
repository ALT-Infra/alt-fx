#!/usr/bin/env python3
from __future__ import annotations

import ast
import importlib
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
EVALS_ROOT = REPO_ROOT / "evals"
DATASETS_ROOT = EVALS_ROOT / "datasets"
REWARDKIT_ROOT = EVALS_ROOT / "rewardkit"
JUDGE_ENV = "FX_REWARDKIT_RUN_JUDGES"
JUDGE_DIR_ENV = "FX_REWARDKIT_JUDGE_DIR"


def rel(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def fail(errors: list[str], path: Path, message: str) -> None:
    errors.append(f"{rel(path)}: {message}")


def strip_comment(line: str) -> str:
    in_string = False
    escaped = False
    out: list[str] = []
    for char in line:
        if char == "\\" and in_string:
            escaped = not escaped
            out.append(char)
            continue
        if char == '"' and not escaped:
            in_string = not in_string
        if char == "#" and not in_string:
            break
        out.append(char)
        escaped = False
    return "".join(out).strip()


def split_top_level(raw: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    in_string = False
    escaped = False
    bracket_depth = 0
    brace_depth = 0
    for char in raw:
        if char == "\\" and in_string:
            escaped = not escaped
            current.append(char)
            continue
        if char == '"' and not escaped:
            in_string = not in_string
        elif not in_string:
            if char == "[":
                bracket_depth += 1
            elif char == "]":
                bracket_depth -= 1
            elif char == "{":
                brace_depth += 1
            elif char == "}":
                brace_depth -= 1
            elif char == "," and bracket_depth == 0 and brace_depth == 0:
                parts.append("".join(current).strip())
                current = []
                escaped = False
                continue
        current.append(char)
        escaped = False
    if current:
        parts.append("".join(current).strip())
    return parts


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
        return [parse_value(item) for item in split_top_level(inner)]
    if value.startswith("{") and value.endswith("}"):
        return value
    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def table_target(data: dict[str, Any], section: str) -> dict[str, Any]:
    parts = section.split(".")
    if parts[0] in data and isinstance(data[parts[0]], list):
        table_list = data[parts[0]]
        if not table_list:
            raise ValueError(f"{section} appeared before [[{parts[0]}]]")
        target = table_list[-1]
        if not isinstance(target, dict):
            raise ValueError(f"{parts[0]} was not a table list")
        parts = parts[1:]
    else:
        target = data
    for part in parts:
        child = target.setdefault(part, {})
        if not isinstance(child, dict):
            raise ValueError(f"{section} conflicted with an existing value")
        target = child
    return target


def parse_toml(path: Path) -> dict[str, Any]:
    data: dict[str, Any] = {}
    current: dict[str, Any] = data
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = strip_comment(line)
        if not stripped:
            continue
        if stripped.startswith("[[") and stripped.endswith("]]"):
            section = stripped[2:-2].strip()
            table_list = data.setdefault(section, [])
            if not isinstance(table_list, list):
                raise ValueError(f"{path}:{lineno}: [[{section}]] conflicted with an existing value")
            current = {}
            table_list.append(current)
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            current = table_target(data, stripped[1:-1].strip())
            continue
        if "=" not in stripped:
            raise ValueError(f"{path}:{lineno}: expected key = value")
        key, raw_value = stripped.split("=", 1)
        current[key.strip()] = parse_value(raw_value)
    return data


def check_toml_parse(errors: list[str]) -> None:
    paths = sorted(DATASETS_ROOT.rglob("*.toml")) + sorted(REWARDKIT_ROOT.rglob("*.toml"))
    for path in paths:
        try:
            parse_toml(path)
        except Exception as exc:
            fail(errors, path, f"TOML parse failed: {exc}")
    if paths:
        print(f"parsed {len(paths)} task, dataset, and RewardKit TOML files")


def check_judge_toml(path: Path, errors: list[str]) -> None:
    try:
        data = parse_toml(path)
    except Exception as exc:
        fail(errors, path, f"TOML parse failed: {exc}")
        return

    judge = data.get("judge")
    if not isinstance(judge, dict):
        fail(errors, path, "missing [judge] section")
        return
    if not isinstance(judge.get("judge"), str) or not judge["judge"]:
        fail(errors, path, "judge.judge must be a non-empty string")

    files = judge.get("files")
    if files is not None and not (
        isinstance(files, list) and all(isinstance(item, str) for item in files)
    ):
        fail(errors, path, "judge.files must be a list of strings when present")

    trajectory = judge.get("atif-trajectory")
    if trajectory is not None and not isinstance(trajectory, str):
        fail(errors, path, "judge.atif-trajectory must be a string when present")

    criteria = data.get("criterion")
    if not isinstance(criteria, list) or not criteria:
        fail(errors, path, "must contain at least one [[criterion]] entry")
        return

    for index, criterion in enumerate(criteria, 1):
        if not isinstance(criterion, dict):
            fail(errors, path, f"criterion {index} must be a table")
            continue
        if not isinstance(criterion.get("description"), str) or not criterion["description"]:
            fail(errors, path, f"criterion {index} must have a description")
        criterion_type = criterion.get("type")
        if criterion_type not in ("binary", "likert", "numeric"):
            fail(errors, path, f"criterion {index} has unsupported type {criterion_type!r}")
        if criterion_type == "likert":
            points = criterion.get("points")
            if not isinstance(points, int) or points < 2:
                fail(errors, path, f"criterion {index} likert points must be an integer >= 2")
        if criterion_type == "numeric":
            min_value = criterion.get("min")
            max_value = criterion.get("max")
            if not isinstance(min_value, (int, float)) or not isinstance(max_value, (int, float)):
                fail(errors, path, f"criterion {index} numeric criteria need min and max")
            elif min_value >= max_value:
                fail(errors, path, f"criterion {index} numeric min must be less than max")

    scoring = data.get("scoring")
    if scoring is not None:
        if not isinstance(scoring, dict):
            fail(errors, path, "[scoring] must be a table")
            return
        aggregation = scoring.get("aggregation")
        if aggregation not in ("weighted_mean", "all_pass", "any_pass", "threshold"):
            fail(errors, path, f"unsupported scoring aggregation {aggregation!r}")
        if aggregation == "threshold":
            threshold = scoring.get("threshold")
            if not isinstance(threshold, (int, float)) or not 0 <= threshold <= 1:
                fail(errors, path, "threshold scoring requires threshold between 0 and 1")


def check_builtin_example(errors: list[str]) -> None:
    path = REWARDKIT_ROOT / "built_in_file_command_json.py"
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except Exception as exc:
        fail(errors, path, f"Python parse failed: {exc}")
        return

    calls: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if isinstance(func, ast.Attribute):
            calls.add(func.attr)
        elif isinstance(func, ast.Name):
            calls.add(func.id)

    required = {
        "file_exists",
        "file_contains",
        "command_succeeds",
        "command_output_contains",
        "json_key_equals",
        "json_path_equals",
    }
    missing = sorted(required - calls)
    if missing:
        fail(errors, path, "missing built-in criteria calls: " + ", ".join(missing))


def rewardkit_namespace() -> Any | None:
    if importlib.util.find_spec("rewardkit") is None:
        return None
    rewardkit = importlib.import_module("rewardkit")
    if hasattr(rewardkit, "file_exists"):
        return rewardkit
    if hasattr(rewardkit, "criteria"):
        return rewardkit.criteria
    try:
        return importlib.import_module("rewardkit.criteria")
    except ModuleNotFoundError:
        return rewardkit


def run_builtin_smoke(errors: list[str]) -> None:
    try:
        namespace = rewardkit_namespace()
    except Exception as exc:
        errors.append(f"rewardkit deterministic built-in smoke failed during import: {exc}")
        return
    if namespace is None:
        print("rewardkit deterministic built-in smoke skipped: rewardkit is not importable")
        return

    required = ("file_exists", "command_succeeds", "json_key_equals")
    missing = [name for name in required if not hasattr(namespace, name)]
    if missing:
        errors.append("rewardkit import smoke: missing built-in criteria " + ", ".join(missing))
        return

    passed = True
    with tempfile.TemporaryDirectory(prefix="fx-rewardkit-") as tmp:
        workspace = Path(tmp)
        (workspace / "summary.json").write_text(
            '{"status": "ok", "checks": {"build": "pass"}}\n',
            encoding="utf-8",
        )
        old_cwd = Path.cwd()
        try:
            os.chdir(str(workspace))
            namespace.file_exists("summary.json")
            namespace.command_succeeds("python3 -m json.tool summary.json", timeout=10)
            namespace.json_key_equals("summary.json", "status", "ok")
        except Exception as exc:
            passed = False
            errors.append(f"rewardkit deterministic built-in smoke failed: {exc}")
        finally:
            os.chdir(str(old_cwd))

    if passed:
        print("rewardkit deterministic built-in smoke passed")


def maybe_run_judges(errors: list[str]) -> None:
    if os.environ.get(JUDGE_ENV) != "1":
        print(f"judge execution skipped: set {JUDGE_ENV}=1 only for explicit paid eval workflows")
        return

    judge_dir = os.environ.get(JUDGE_DIR_ENV)
    if not judge_dir:
        print(f"{JUDGE_ENV}=1 set, but {JUDGE_DIR_ENV} is unset; no judge example executed")
        return

    if importlib.util.find_spec("rewardkit") is None:
        errors.append(f"{JUDGE_ENV}=1 requested judge execution, but rewardkit is not importable")
        return

    subprocess.run([sys.executable, "-m", "rewardkit", judge_dir], cwd=REPO_ROOT, check=True)
    print(f"executed RewardKit judge directory: {judge_dir}")


def main() -> int:
    errors: list[str] = []

    check_toml_parse(errors)
    for path in sorted(REWARDKIT_ROOT.glob("*.toml")):
        check_judge_toml(path, errors)
    check_builtin_example(errors)
    run_builtin_smoke(errors)
    maybe_run_judges(errors)

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print("RewardKit readiness checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
