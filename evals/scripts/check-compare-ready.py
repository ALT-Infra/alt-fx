#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
JOBS_ROOT = REPO_ROOT / "evals" / "jobs"
COMPARISON_JOB_NAMES = {
    "compare-key-agents.yaml",
    "compare-terminal-bench-smoke.yaml",
    "compare-terminal-bench.yaml",
}
COMPARISON_AGENTS = {"fx", "codex", "claude-code", "opencode"}


@dataclass
class YamlLine:
    indent: int
    text: str
    lineno: int


def rel(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def fail(errors: list[str], path: Path | None, message: str) -> None:
    if path is None:
        errors.append(message)
    else:
        errors.append(f"{rel(path)}: {message}")


def strip_comment(line: str) -> str:
    in_single = False
    in_double = False
    escaped = False
    out: list[str] = []
    for char in line:
        if char == "\\" and in_double:
            escaped = not escaped
            out.append(char)
            continue
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single and not escaped:
            in_double = not in_double
        if char == "#" and not in_single and not in_double:
            break
        out.append(char)
        escaped = False
    return "".join(out).rstrip()


def yaml_lines(path: Path) -> list[YamlLine]:
    lines: list[YamlLine] = []
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if "\t" in raw:
            raise ValueError(f"line {lineno}: tabs are not supported in job YAML")
        stripped = strip_comment(raw)
        if not stripped.strip():
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        lines.append(YamlLine(indent=indent, text=stripped.strip(), lineno=lineno))
    return lines


def split_key_value(text: str, lineno: int) -> tuple[str, str | None]:
    if ":" not in text:
        raise ValueError(f"line {lineno}: expected key: value")
    key, value = text.split(":", 1)
    key = key.strip()
    if not key:
        raise ValueError(f"line {lineno}: empty key")
    value = value.strip()
    return key, value if value else None


def scalar(value: str) -> Any:
    if value in ("true", "false"):
        return value == "true"
    if value in ("null", "~"):
        return None
    if (
        (value.startswith('"') and value.endswith('"'))
        or (value.startswith("'") and value.endswith("'"))
    ):
        return value[1:-1]
    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def parse_mapping(lines: list[YamlLine], index: int, indent: int) -> tuple[dict[str, Any], int]:
    result: dict[str, Any] = {}
    while index < len(lines):
        line = lines[index]
        if line.indent < indent:
            break
        if line.indent > indent:
            raise ValueError(f"line {line.lineno}: unexpected indentation")
        if line.text.startswith("- "):
            break

        key, value = split_key_value(line.text, line.lineno)
        index += 1
        if value is not None:
            result[key] = scalar(value)
            continue

        if index >= len(lines) or lines[index].indent <= indent:
            result[key] = {}
            continue
        child, index = parse_block(lines, index, lines[index].indent)
        result[key] = child
    return result, index


def parse_sequence(lines: list[YamlLine], index: int, indent: int) -> tuple[list[Any], int]:
    result: list[Any] = []
    while index < len(lines):
        line = lines[index]
        if line.indent < indent:
            break
        if line.indent > indent:
            raise ValueError(f"line {line.lineno}: unexpected indentation")
        if not line.text.startswith("- "):
            break

        item_text = line.text[2:].strip()
        index += 1
        if not item_text:
            if index >= len(lines) or lines[index].indent <= indent:
                result.append(None)
                continue
            item, index = parse_block(lines, index, lines[index].indent)
            result.append(item)
            continue

        if ":" in item_text:
            key, value = split_key_value(item_text, line.lineno)
            item: dict[str, Any] = {}
            if value is None:
                if index >= len(lines) or lines[index].indent <= indent:
                    item[key] = {}
                else:
                    item[key], index = parse_block(lines, index, lines[index].indent)
            else:
                item[key] = scalar(value)

            if index < len(lines) and lines[index].indent > indent:
                extra, index = parse_mapping(lines, index, lines[index].indent)
                item.update(extra)
            result.append(item)
        else:
            result.append(scalar(item_text))
    return result, index


def parse_block(lines: list[YamlLine], index: int, indent: int) -> tuple[Any, int]:
    if lines[index].text.startswith("- "):
        return parse_sequence(lines, index, indent)
    return parse_mapping(lines, index, indent)


def fallback_yaml_load(path: Path) -> dict[str, Any]:
    lines = yaml_lines(path)
    if not lines:
        return {}
    value, index = parse_block(lines, 0, lines[0].indent)
    if index != len(lines):
        line = lines[index]
        raise ValueError(f"line {line.lineno}: could not parse remaining YAML")
    if not isinstance(value, dict):
        raise ValueError("top-level YAML value must be a mapping")
    return value


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        import yaml  # type: ignore[import-not-found]
    except ImportError:
        return fallback_yaml_load(path)

    value = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("top-level YAML value must be a mapping")
    return value


def check_env(errors: list[str]) -> None:
    if not os.environ.get("AI_GATEWAY_API_KEY"):
        fail(
            errors,
            None,
            "AI_GATEWAY_API_KEY is required for fx, Codex, Claude Code, and OpenCode comparison agents",
        )


def job_paths() -> list[Path]:
    return sorted(JOBS_ROOT.glob("*.yaml"))


def runtime_agent_name(
    path: Path, item: dict[str, Any], errors: list[str]
) -> str | None:
    import_path = item.get("import_path")
    if isinstance(import_path, str):
        agent_class = check_import_path(path, import_path, errors)
        if agent_class is not None:
            name_fn = getattr(agent_class, "name", None)
            if callable(name_fn):
                try:
                    name = name_fn()
                except Exception as exc:
                    fail(errors, path, f"{import_path}.name() failed: {exc}")
                else:
                    if isinstance(name, str) and name:
                        return name

    name = item.get("name")
    return name if isinstance(name, str) else None


def check_comparison_jobs(
    parsed_by_path: dict[Path, dict[str, Any]], errors: list[str]
) -> None:
    found_names = {
        path.name for path in parsed_by_path if path.name in COMPARISON_JOB_NAMES
    }
    missing = sorted(COMPARISON_JOB_NAMES - found_names)
    for name in missing:
        fail(errors, JOBS_ROOT / name, "comparison job config is missing")

    for path, parsed in parsed_by_path.items():
        if path.name not in COMPARISON_JOB_NAMES:
            continue
        agents = parsed.get("agents")
        if not isinstance(agents, list):
            fail(errors, path, "agents must be a list")
            continue
        names = {
            name
            for item in agents
            if isinstance(item, dict)
            if (name := runtime_agent_name(path, item, errors)) is not None
        }
        missing_agents = sorted(COMPARISON_AGENTS - names)
        if missing_agents:
            fail(
                errors,
                path,
                "missing comparison agents: " + ", ".join(missing_agents),
            )


def check_import_path(path: Path, import_path: str, errors: list[str]) -> Any | None:
    if ":" not in import_path:
        fail(errors, path, f"import_path must be module:Class: {import_path}")
        return None
    module_name, class_name = import_path.split(":", 1)
    try:
        module = importlib.import_module(module_name)
    except Exception as exc:
        fail(errors, path, f"cannot import {module_name}: {exc}")
        return None
    if not hasattr(module, class_name):
        fail(errors, path, f"{module_name} does not expose {class_name}")
        return None
    return getattr(module, class_name)


def check_harbor_job_config(path: Path, parsed: dict[str, Any], errors: list[str]) -> None:
    try:
        from harbor.models.job.config import JobConfig
    except Exception as exc:
        fail(errors, path, f"Harbor JobConfig is not importable: {exc}")
        return

    try:
        JobConfig.model_validate(parsed)
    except Exception as exc:
        fail(errors, path, f"Harbor JobConfig validation failed: {exc}")


def check_job_configs(errors: list[str]) -> tuple[int, int]:
    parsed_by_path: dict[Path, dict[str, Any]] = {}
    for path in job_paths():
        try:
            parsed = load_yaml(path)
        except Exception as exc:
            fail(errors, path, f"YAML parse failed: {exc}")
            continue
        parsed_by_path[path] = parsed
        check_harbor_job_config(path, parsed, errors)

    check_comparison_jobs(parsed_by_path, errors)
    return len(parsed_by_path), len(
        [path for path in parsed_by_path if path.name in COMPARISON_JOB_NAMES]
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config-only",
        action="store_true",
        help="Validate YAML and Harbor JobConfig shape without checking credentials.",
    )
    args = parser.parse_args()

    sys.path.insert(0, str(REPO_ROOT))
    os.chdir(REPO_ROOT)

    errors: list[str] = []
    if not args.config_only:
        check_env(errors)
    total_jobs, comparison_jobs = check_job_configs(errors)

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print("comparison readiness checks passed")
    if args.config_only:
        print("credential checks skipped")
    print(
        f"validated {total_jobs} job YAML files and {comparison_jobs} comparison job configs"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
