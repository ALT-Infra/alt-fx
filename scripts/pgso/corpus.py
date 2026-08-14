from __future__ import annotations

import argparse
import dataclasses
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
from collections.abc import Callable, Mapping, Sequence

from scripts.pgso.model import PgsoError, sha256_file
from scripts.pgso.pipeline import merge_profile_batch
from scripts.pgso.runner import CommandResult, run_checked


REQUIRED_DIRECT_COMMANDS = (
    ("help",),
    ("--version",),
    ("status", "--json"),
    ("background", "--json"),
    ("doctor", "--json"),
    ("sessions", "--json"),
)

REQUIRED_EXCLUSIONS = (
    "notifications.test.ts",
    "tui-command-permissions.test.ts",
)

ISOLATED_ENVIRONMENT_KEYS = (
    "AI_GATEWAY_API_KEY",
    "VERCEL_OIDC_TOKEN",
    "LLVM_PROFILE_FILE",
    "TMUX",
    "TMUX_PANE",
    "TMUX_TMPDIR",
)


@dataclasses.dataclass(frozen=True)
class Scenario:
    name: str
    argv: tuple[str, ...]
    cwd: str
    env_set: tuple[tuple[str, str], ...]
    env_unset: tuple[str, ...]
    timeout_seconds: float
    requires_tmux: bool
    allow_keychain: bool
    test_file: str | None
    skip_reason: str | None = None


@dataclasses.dataclass(frozen=True)
class Corpus:
    repo_root: pathlib.Path
    manifest_path: pathlib.Path
    manifest_sha256: str
    scenarios: tuple[Scenario, ...]
    intentional_exclusions: tuple[tuple[str, str], ...]

    @property
    def test_files(self) -> tuple[str, ...]:
        return tuple(
            scenario.test_file
            for scenario in self.scenarios
            if scenario.test_file is not None
        )


@dataclasses.dataclass(frozen=True)
class ScenarioResult:
    name: str
    status: str
    elapsed_seconds: float
    raw_profiles: int
    skip_reason: str | None = None
    error: str | None = None


@dataclasses.dataclass(frozen=True)
class CorpusResult:
    passed: int
    skipped: int
    failed: int
    merged_raw_profiles: int
    results: tuple[ScenarioResult, ...]


class CorpusRunError(PgsoError):
    def __init__(self, message: str, result: CorpusResult) -> None:
        super().__init__(message)
        self.result = result


def _mapping(value: object, label: str) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise PgsoError(f"{label} must be an object")
    if not all(isinstance(key, str) for key in value):
        raise PgsoError(f"{label} keys must be strings")
    return value


def _string_mapping(value: object, label: str) -> dict[str, str]:
    mapping = _mapping(value, label)
    if not all(isinstance(item, str) for item in mapping.values()):
        raise PgsoError(f"{label} values must be strings")
    return {key: item for key, item in mapping.items() if isinstance(item, str)}


def _string_sequence(
    value: object,
    label: str,
    *,
    allow_empty: bool = False,
) -> tuple[str, ...]:
    if (
        not isinstance(value, list)
        or (not value and not allow_empty)
        or not all(
        isinstance(item, str) and item for item in value
        )
    ):
        raise PgsoError(f"{label} must be a list of nonempty strings")
    return tuple(value)


def _resolve_cwd(repo_root: pathlib.Path, cwd: str) -> pathlib.Path:
    repo_root = repo_root.resolve()
    resolved = (repo_root / cwd).resolve()
    try:
        resolved.relative_to(repo_root)
    except ValueError as error:
        raise PgsoError(f"scenario cwd escapes repository: {cwd}") from error
    if not resolved.is_dir():
        raise PgsoError(f"scenario cwd does not exist: {cwd}")
    return resolved


def _is_live_test(test_file: str) -> bool:
    return re.search(r"(?:^|-)live(?:-|\.)", test_file) is not None


def _parse_scenario(
    raw: object,
    *,
    defaults: Mapping[str, object],
    repo_root: pathlib.Path,
) -> Scenario:
    values = dict(defaults)
    values.update(_mapping(raw, "scenario"))

    name = values.get("name")
    if not isinstance(name, str) or re.fullmatch(r"[a-z0-9][a-z0-9-]*", name) is None:
        raise PgsoError(f"invalid scenario name: {name!r}")
    argv = _string_sequence(values.get("argv"), f"scenario {name} argv")

    cwd = values.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        raise PgsoError(f"scenario {name} cwd must be a nonempty string")
    _resolve_cwd(repo_root, cwd)

    default_env_set = _string_mapping(
        defaults.get("env_set", {}),
        "default env_set",
    )
    scenario_raw = _mapping(raw, "scenario")
    scenario_env_set = _string_mapping(
        scenario_raw.get("env_set", {}),
        f"scenario {name} env_set",
    )
    env_set = {**default_env_set, **scenario_env_set}
    reserved = set(env_set) & ({"HOME"} | set(ISOLATED_ENVIRONMENT_KEYS))
    if reserved:
        raise PgsoError(
            f"scenario {name} sets reserved environment key: "
            f"{', '.join(sorted(reserved))}"
        )
    env_unset = _string_sequence(
        values.get("env_unset", []),
        f"scenario {name} env_unset",
        allow_empty=True,
    )
    overlap = set(env_set) & set(env_unset)
    if overlap:
        raise PgsoError(
            f"scenario {name} sets and unsets the same environment key: "
            f"{', '.join(sorted(overlap))}"
        )

    timeout_seconds = values.get("timeout_seconds")
    if (
        isinstance(timeout_seconds, bool)
        or not isinstance(timeout_seconds, (int, float))
        or timeout_seconds <= 0
    ):
        raise PgsoError(f"scenario {name} timeout must be positive")
    requires_tmux = values.get("requires_tmux")
    if not isinstance(requires_tmux, bool):
        raise PgsoError(f"scenario {name} requires_tmux must be a boolean")
    allow_keychain = values.get("allow_keychain", False)
    if not isinstance(allow_keychain, bool):
        raise PgsoError(f"scenario {name} allow_keychain must be a boolean")

    test_file = values.get("test_file")
    if test_file is not None:
        if not isinstance(test_file, str) or pathlib.Path(test_file).name != test_file:
            raise PgsoError(f"invalid corpus test file: {test_file!r}")
        if test_file in REQUIRED_EXCLUSIONS or _is_live_test(test_file):
            raise PgsoError(f"forbidden corpus test: {test_file}")
        expected_argv = (
            "bun",
            "test",
            "--max-concurrency",
            "1",
            f"./{test_file}",
        )
        if argv != expected_argv:
            raise PgsoError(f"scenario {name} test command mismatch")
        expected_test = repo_root / "tests" / "e2e" / test_file
        if not expected_test.is_file():
            raise PgsoError(f"test file does not exist: {test_file}")

    skip_reason = values.get("skip_reason")
    if skip_reason is not None and (
        not isinstance(skip_reason, str) or not skip_reason.strip()
    ):
        raise PgsoError(f"scenario {name} skip_reason must be nonempty")

    return Scenario(
        name=name,
        argv=argv,
        cwd=cwd,
        env_set=tuple(sorted(env_set.items())),
        env_unset=env_unset,
        timeout_seconds=float(timeout_seconds),
        requires_tmux=requires_tmux,
        allow_keychain=allow_keychain,
        test_file=test_file,
        skip_reason=skip_reason,
    )


def load_corpus(
    path: pathlib.Path,
    *,
    repo_root: pathlib.Path | None = None,
) -> Corpus:
    path = path.resolve()
    if not path.is_file():
        raise PgsoError(f"corpus manifest does not exist: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PgsoError(f"could not read corpus manifest: {error}") from error
    root = path.parents[2] if repo_root is None else repo_root.resolve()
    document = _mapping(payload, "corpus manifest")
    if document.get("version") != 1:
        raise PgsoError("unsupported corpus manifest version")

    exclusions = _string_mapping(
        document.get("intentional_exclusions"),
        "intentional_exclusions",
    )
    for required in REQUIRED_EXCLUSIONS:
        if required not in exclusions:
            raise PgsoError(f"missing required corpus exclusion: {required}")

    defaults = _mapping(document.get("defaults", {}), "corpus defaults")
    raw_scenarios = document.get("scenarios")
    if not isinstance(raw_scenarios, list) or not raw_scenarios:
        raise PgsoError("corpus scenarios must be a nonempty list")
    scenarios = tuple(
        _parse_scenario(raw, defaults=defaults, repo_root=root)
        for raw in raw_scenarios
    )
    names = [scenario.name for scenario in scenarios]
    if len(set(names)) != len(names):
        raise PgsoError("duplicate scenario name in corpus manifest")

    direct_commands = {
        scenario.argv[1:]
        for scenario in scenarios
        if scenario.argv[0] == "{binary}" and scenario.test_file is None
    }
    for required in REQUIRED_DIRECT_COMMANDS:
        if required not in direct_commands:
            raise PgsoError(
                "missing required direct command: " + " ".join(required)
            )

    return Corpus(
        repo_root=root,
        manifest_path=path,
        manifest_sha256=sha256_file(path),
        scenarios=scenarios,
        intentional_exclusions=tuple(sorted(exclusions.items())),
    )


def _install_training_binary(corpus: Corpus, binary: pathlib.Path) -> pathlib.Path:
    if not binary.is_file() or binary.stat().st_size == 0:
        raise PgsoError(f"training binary is missing or empty: {binary}")
    canonical = corpus.repo_root / "zig-out" / "bin" / "fx"
    canonical.parent.mkdir(parents=True, exist_ok=True)
    if canonical.is_symlink():
        raise PgsoError(f"canonical training binary cannot be a symlink: {canonical}")
    if binary.resolve() != canonical.resolve():
        shutil.copy2(binary, canonical)
    if sha256_file(canonical) != sha256_file(binary):
        raise PgsoError("canonical training binary hash mismatch after installation")
    return canonical


def _cleanup_tmux(
    environment: Mapping[str, str],
    tmux_dir: pathlib.Path,
) -> None:
    if (
        tmux_dir.parent != pathlib.Path("/tmp")
        or not tmux_dir.name.startswith("fxp-tmux-")
        or tmux_dir.is_symlink()
    ):
        raise PgsoError(f"refusing to remove unowned tmux directory: {tmux_dir}")

    cleanup_failure: tuple[str, BaseException] | None = None
    try:
        subprocess.run(
            ("tmux", "kill-server"),
            env=dict(environment),
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except FileNotFoundError as error:
        cleanup_failure = ("tmux is required by the corpus scenario", error)
    except subprocess.TimeoutExpired as error:
        cleanup_failure = ("tmux cleanup timed out", error)

    removal_failure: OSError | None = None
    try:
        shutil.rmtree(tmux_dir)
    except FileNotFoundError:
        pass
    except OSError as error:
        removal_failure = error

    if cleanup_failure is not None:
        message, error = cleanup_failure
        raise PgsoError(message) from error
    if removal_failure is not None:
        raise PgsoError(
            f"could not remove tmux directory: {tmux_dir}"
        ) from removal_failure


def _new_tmux_dir() -> pathlib.Path:
    tmux_dir = pathlib.Path(tempfile.mkdtemp(prefix="fxp-tmux-", dir="/tmp"))
    tmux_dir.chmod(0o700)
    return tmux_dir


def _scenario_environment(runtime_home: pathlib.Path) -> dict[str, str]:
    environment = os.environ.copy()
    for key in ISOLATED_ENVIRONMENT_KEYS:
        environment.pop(key, None)
    environment["HOME"] = str(runtime_home)
    return environment


def _prepare_runtime_home(
    runtime_home: pathlib.Path,
    *,
    allow_keychain: bool,
) -> None:
    runtime_home.mkdir(parents=True, exist_ok=True)
    tmux_config = runtime_home / ".tmux.conf"
    if tmux_config.is_symlink():
        raise PgsoError(f"isolated tmux config cannot be a symlink: {tmux_config}")
    tmux_config.write_text(
        "set-option -g history-limit 100000\n",
        encoding="utf-8",
    )
    if allow_keychain:
        source = pathlib.Path.home() / "Library" / "Keychains"
        if not source.is_dir():
            raise PgsoError(f"host Keychains directory does not exist: {source}")
        library = runtime_home / "Library"
        library.mkdir()
        destination = library / "Keychains"
        destination.symlink_to(source, target_is_directory=True)


def _result(
    results: Sequence[ScenarioResult],
    merged_raw_profiles: int,
) -> CorpusResult:
    return CorpusResult(
        passed=sum(item.status == "passed" for item in results),
        skipped=sum(item.status == "skipped" for item in results),
        failed=sum(item.status == "failed" for item in results),
        merged_raw_profiles=merged_raw_profiles,
        results=tuple(results),
    )


def _scenario_argv(
    scenario: Scenario,
    canonical: pathlib.Path,
    bun: pathlib.Path | str,
) -> tuple[str, ...]:
    resolved: list[str] = []
    for argument in scenario.argv:
        if argument == "{binary}":
            resolved.append(str(canonical))
        elif argument == "bun":
            resolved.append(str(bun))
        else:
            resolved.append(argument)
    return tuple(resolved)


def run_corpus(
    corpus: Corpus,
    binary: pathlib.Path,
    profile_dir: pathlib.Path,
    merged_profile: pathlib.Path,
    *,
    toolchain: object,
    bun: pathlib.Path | str = "bun",
    command_runner: Callable[..., CommandResult] = run_checked,
    profile_merger: Callable[..., int] = merge_profile_batch,
) -> CorpusResult:
    canonical = _install_training_binary(corpus, binary)
    profile_dir.mkdir(parents=True, exist_ok=True)
    log_dir = profile_dir.parent.parent / "logs" / "corpus"
    log_dir.mkdir(parents=True, exist_ok=True)
    runtime_home = profile_dir.parent / "home"
    runtime_home.mkdir(parents=True, exist_ok=True)
    results: list[ScenarioResult] = []
    merged_raw_profiles = 0
    for scenario in corpus.scenarios:
        if scenario.skip_reason is not None:
            results.append(
                ScenarioResult(
                    name=scenario.name,
                    status="skipped",
                    elapsed_seconds=0,
                    raw_profiles=0,
                    skip_reason=scenario.skip_reason,
                )
            )
            continue

        scenario_home = runtime_home / scenario.name
        _prepare_runtime_home(
            scenario_home,
            allow_keychain=scenario.allow_keychain,
        )
        environment = _scenario_environment(scenario_home)
        for key in scenario.env_unset:
            environment.pop(key, None)
        environment.update(dict(scenario.env_set))
        environment["HOME"] = str(scenario_home)
        environment["LLVM_PROFILE_FILE"] = str(
            profile_dir / f"{scenario.name}-%m-%p-%c.profraw"
        )
        if scenario.requires_tmux:
            tmux_dir = _new_tmux_dir()
            environment["TMUX_TMPDIR"] = str(tmux_dir)

        argv = _scenario_argv(scenario, canonical, bun)
        before = set(profile_dir.glob("*.profraw"))
        command_result: CommandResult | None = None
        scenario_error: Exception | None = None
        try:
            command_result = command_runner(
                argv,
                cwd=_resolve_cwd(corpus.repo_root, scenario.cwd),
                env=environment,
                timeout_s=scenario.timeout_seconds,
                log_path=log_dir / f"{scenario.name}.json",
            )
        except Exception as error:
            scenario_error = error

        if scenario.requires_tmux:
            try:
                _cleanup_tmux(environment, tmux_dir)
            except Exception as error:
                if scenario_error is None:
                    scenario_error = error

        if scenario_error is not None:
            results.append(
                ScenarioResult(
                    name=scenario.name,
                    status="failed",
                    elapsed_seconds=0,
                    raw_profiles=0,
                    error=str(scenario_error),
                )
            )
            result = _result(results, merged_raw_profiles)
            raise CorpusRunError(
                f"corpus scenario failed: {scenario.name}: {scenario_error}",
                result,
            ) from scenario_error

        generated = tuple(sorted(set(profile_dir.glob("*.profraw")) - before))
        if not generated or any(
            not profile.is_file() or profile.stat().st_size == 0
            for profile in generated
        ):
            results.append(
                ScenarioResult(
                    name=scenario.name,
                    status="failed",
                    elapsed_seconds=command_result.elapsed_seconds,
                    raw_profiles=len(generated),
                    error="produced no raw profile",
                )
            )
            result = _result(results, merged_raw_profiles)
            raise CorpusRunError(
                f"corpus scenario produced no raw profile: {scenario.name}",
                result,
            )

        try:
            merged_raw_profiles += profile_merger(
                toolchain,
                generated,
                merged_profile,
                log_dir / f"{scenario.name}-merge.json",
            )
        except Exception as error:
            results.append(
                ScenarioResult(
                    name=scenario.name,
                    status="failed",
                    elapsed_seconds=command_result.elapsed_seconds,
                    raw_profiles=len(generated),
                    error=str(error),
                )
            )
            result = _result(results, merged_raw_profiles)
            raise CorpusRunError(
                f"corpus profile merge failed: {scenario.name}: {error}",
                result,
            ) from error

        results.append(
            ScenarioResult(
                name=scenario.name,
                status="passed",
                elapsed_seconds=command_result.elapsed_seconds,
                raw_profiles=len(generated),
            )
        )

    return _result(results, merged_raw_profiles)


def run_behavior_corpus(
    corpus: Corpus,
    binary: pathlib.Path,
    output_dir: pathlib.Path,
    *,
    bun: pathlib.Path | str = "bun",
    command_runner: Callable[..., CommandResult] = run_checked,
) -> CorpusResult:
    canonical = _install_training_binary(corpus, binary)
    log_dir = output_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    runtime_home = output_dir / "home"
    runtime_home.mkdir(parents=True, exist_ok=True)
    results: list[ScenarioResult] = []
    for scenario in corpus.scenarios:
        if scenario.skip_reason is not None:
            results.append(
                ScenarioResult(
                    name=scenario.name,
                    status="skipped",
                    elapsed_seconds=0,
                    raw_profiles=0,
                    skip_reason=scenario.skip_reason,
                )
            )
            continue

        scenario_home = runtime_home / scenario.name
        _prepare_runtime_home(
            scenario_home,
            allow_keychain=scenario.allow_keychain,
        )
        environment = _scenario_environment(scenario_home)
        for key in scenario.env_unset:
            environment.pop(key, None)
        environment.update(dict(scenario.env_set))
        environment["HOME"] = str(scenario_home)
        if scenario.requires_tmux:
            tmux_dir = _new_tmux_dir()
            environment["TMUX_TMPDIR"] = str(tmux_dir)

        argv = _scenario_argv(scenario, canonical, bun)
        command_result: CommandResult | None = None
        scenario_error: Exception | None = None
        try:
            command_result = command_runner(
                argv,
                cwd=_resolve_cwd(corpus.repo_root, scenario.cwd),
                env=environment,
                timeout_s=scenario.timeout_seconds,
                log_path=log_dir / f"{scenario.name}.json",
            )
        except Exception as error:
            scenario_error = error

        if scenario.requires_tmux:
            try:
                _cleanup_tmux(environment, tmux_dir)
            except Exception as error:
                if scenario_error is None:
                    scenario_error = error

        if scenario_error is not None:
            results.append(
                ScenarioResult(
                    name=scenario.name,
                    status="failed",
                    elapsed_seconds=0,
                    raw_profiles=0,
                    error=str(scenario_error),
                )
            )
            result = _result(results, 0)
            raise CorpusRunError(
                f"behavior corpus scenario failed: {scenario.name}: "
                f"{scenario_error}",
                result,
            ) from scenario_error

        if command_result is None:
            raise PgsoError(f"scenario completed without a result: {scenario.name}")
        results.append(
            ScenarioResult(
                name=scenario.name,
                status="passed",
                elapsed_seconds=command_result.elapsed_seconds,
                raw_profiles=0,
            )
        )

    return _result(results, 0)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Inspect the fx PGSO corpus")
    parser.add_argument(
        "--manifest",
        required=True,
        type=pathlib.Path,
    )
    parser.add_argument("--list", action="store_true")
    arguments = parser.parse_args(argv)
    corpus = load_corpus(arguments.manifest)
    if not arguments.list:
        parser.error("only --list is supported by this module")
    for scenario in corpus.scenarios:
        source = scenario.test_file or "direct"
        print(f"{scenario.name}\t{source}")
    print("intentional exclusions:")
    for test_file, reason in corpus.intentional_exclusions:
        print(f"{test_file}\t{reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
