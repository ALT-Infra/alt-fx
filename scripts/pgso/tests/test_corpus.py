from __future__ import annotations

import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from scripts.pgso.corpus import (
    Corpus,
    CorpusRunError,
    Scenario,
    load_corpus,
    run_behavior_corpus,
    run_corpus,
)
from scripts.pgso.model import PgsoError
from scripts.pgso.runner import CommandResult


ACCEPTED_E2E_TESTS = (
    "cli.test.ts",
    "ask-presentation.test.ts",
    "config-persistence.test.ts",
    "prompt-history.test.ts",
    "auth-refresh.test.ts",
    "file-tool-paths.test.ts",
    "file-tool-permissions.test.ts",
    "gateway-stream-lifecycle.test.ts",
    "web-fetch-fake-network.test.ts",
    "web-search-fake-gateway.test.ts",
    "vision-route-fake-gateway.test.ts",
    "acp.test.ts",
    "mcp-http.test.ts",
    "mcp-legacy-remote.test.ts",
    "mcp-stdio.test.ts",
    "mcp-auth.test.ts",
    "session-recovery.test.ts",
    "terminal-host.test.ts",
    "tui-startup.test.ts",
    "tui-agent.test.ts",
    "tui-resize.test.ts",
    "tui-render-stress.test.ts",
    "tui-full-transcript-brutal.test.ts",
    "tui-resume-brutal.test.ts",
    "tui-permissions.test.ts",
    "tui-interrupt-recovery.test.ts",
    "tui-subagent-manager.test.ts",
    "tui-terminal-tool.test.ts",
    "tui-native-clear-recovery.test.ts",
    "tui-gateway-stream-lifecycle.test.ts",
)


class PgsoCorpusTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="fx-pgso-corpus-"
        )
        self.root = pathlib.Path(self.temporary_directory.name)
        (self.root / "tests" / "e2e").mkdir(parents=True)
        self.manifest_path = self.root / "corpus.json"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def direct_scenarios(self) -> list[dict[str, object]]:
        commands = (
            ("direct-help", ("help",)),
            ("direct-version", ("--version",)),
            ("direct-status", ("status", "--json")),
            ("direct-background", ("background", "--json")),
            ("direct-doctor", ("doctor", "--json")),
            ("direct-sessions", ("sessions", "--json")),
        )
        return [
            {
                "name": name,
                "argv": ["{binary}", *arguments],
                "cwd": ".",
                "env_set": {"FX_SOUND": "0"},
                "env_unset": [],
                "timeout_seconds": 30,
                "requires_tmux": False,
            }
            for name, arguments in commands
        ]

    def manifest(self) -> dict[str, object]:
        return {
            "version": 1,
            "intentional_exclusions": {
                "notifications.test.ts": "sound-related",
                "tui-command-permissions.test.ts": "contains a sound scenario",
            },
            "scenarios": self.direct_scenarios(),
        }

    def write_manifest(self, payload: dict[str, object]) -> pathlib.Path:
        self.manifest_path.write_text(json.dumps(payload))
        return self.manifest_path

    def e2e_scenario(self, test_file: str) -> dict[str, object]:
        return {
            "name": f"e2e-{test_file.removesuffix('.test.ts')}",
            "argv": ["bun", "test", "--max-concurrency", "1", f"./{test_file}"],
            "cwd": "tests/e2e",
            "env_set": {"FX_SOUND": "0"},
            "env_unset": ["AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN"],
            "timeout_seconds": 60,
            "requires_tmux": True,
            "test_file": test_file,
        }

    def test_load_rejects_duplicate_names(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios.append(dict(scenarios[0]))

        with self.assertRaisesRegex(PgsoError, "duplicate scenario name"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_path_traversal(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios[0]["cwd"] = "../outside"

        with self.assertRaisesRegex(PgsoError, "cwd escapes repository"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_a_missing_test_file(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios.append(self.e2e_scenario("missing.test.ts"))

        with self.assertRaisesRegex(PgsoError, "test file does not exist"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_binds_each_test_file_to_its_exact_bun_command(self) -> None:
        test_file = "cli.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenario = self.e2e_scenario(test_file)
        scenario["argv"] = ["bun", "test", "./different.test.ts"]
        scenarios.append(scenario)

        with self.assertRaisesRegex(PgsoError, "test command mismatch"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_an_empty_command_or_nonpositive_timeout(self) -> None:
        cases = (("argv", []), ("timeout_seconds", 0))
        for field, value in cases:
            with self.subTest(field=field):
                payload = self.manifest()
                scenarios = payload["scenarios"]
                assert isinstance(scenarios, list)
                scenarios[0][field] = value
                with self.assertRaises(PgsoError):
                    load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_sound_and_live_test_files(self) -> None:
        for test_file in (
            "notifications.test.ts",
            "tui-command-permissions.test.ts",
            "web-search-live.test.ts",
        ):
            with self.subTest(test_file=test_file):
                (self.root / "tests" / "e2e" / test_file).write_text("test")
                payload = self.manifest()
                scenarios = payload["scenarios"]
                assert isinstance(scenarios, list)
                scenarios.append(self.e2e_scenario(test_file))
                with self.assertRaisesRegex(PgsoError, "forbidden corpus test"):
                    load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_requires_every_direct_command(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios.pop()

        with self.assertRaisesRegex(PgsoError, "missing required direct command"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_environment_keys_owned_by_the_runner(self) -> None:
        for key in ("HOME", "LLVM_PROFILE_FILE", "TMUX", "AI_GATEWAY_API_KEY"):
            with self.subTest(key=key):
                payload = self.manifest()
                scenarios = payload["scenarios"]
                assert isinstance(scenarios, list)
                scenarios[0]["env_set"] = {key: "unsafe"}
                with self.assertRaisesRegex(PgsoError, "reserved environment key"):
                    load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_production_manifest_has_the_accepted_files_and_sound_exclusions(self) -> None:
        repo_root = pathlib.Path(__file__).resolve().parents[3]
        corpus = load_corpus(
            repo_root / "scripts" / "pgso" / "corpus.json",
            repo_root=repo_root,
        )

        self.assertEqual(ACCEPTED_E2E_TESTS, corpus.test_files)
        self.assertNotIn("notifications.test.ts", corpus.test_files)
        self.assertNotIn("tui-command-permissions.test.ts", corpus.test_files)
        self.assertEqual(36, len(corpus.scenarios))

    def make_scenario(
        self,
        name: str,
        *,
        requires_tmux: bool = False,
        skip_reason: str | None = None,
    ) -> Scenario:
        return Scenario(
            name=name,
            argv=("{binary}", name),
            cwd=".",
            env_set=(("FX_SOUND", "0"),),
            env_unset=("PGSO_UNSET_ME",),
            timeout_seconds=5,
            requires_tmux=requires_tmux,
            test_file=None,
            skip_reason=skip_reason,
        )

    def make_corpus(self, *scenarios: Scenario) -> Corpus:
        return Corpus(
            repo_root=self.root,
            manifest_path=self.manifest_path,
            manifest_sha256="a" * 64,
            scenarios=tuple(scenarios),
            intentional_exclusions=(
                ("notifications.test.ts", "sound-related"),
                ("tui-command-permissions.test.ts", "contains sound"),
            ),
        )

    def run_fixture(
        self,
        corpus: Corpus,
        *,
        fail_scenario: str | None = None,
        omit_profile_for: str | None = None,
    ):
        output = self.root / "output"
        profile_dir = output / "profiles" / "raw"
        profile_dir.mkdir(parents=True, exist_ok=True)
        merged_profile = output / "profiles" / "merged.profdata"
        binary = self.root / "instrumented-fx"
        binary.write_bytes(b"instrumented")
        calls: list[dict[str, object]] = []
        merges: list[tuple[str, ...]] = []

        def command_runner(argv, **kwargs):
            environment = kwargs["env"]
            scenario_name = argv[1]
            calls.append(
                {
                    "argv": tuple(argv),
                    "env": dict(environment),
                    "cwd": kwargs["cwd"],
                }
            )
            if scenario_name == fail_scenario:
                raise PgsoError(f"failed scenario: {scenario_name}")
            if scenario_name != omit_profile_for:
                pattern = environment["LLVM_PROFILE_FILE"]
                raw = pathlib.Path(
                    pattern.replace("%m", "module")
                    .replace("%p", "123")
                    .replace("%c", "")
                )
                raw.write_bytes(scenario_name.encode())
            return CommandResult(
                argv=tuple(argv),
                returncode=0,
                stdout="ok\n",
                stderr="",
                elapsed_seconds=0.25,
            )

        def profile_merger(toolchain, raw_profiles, merged, log_path):
            merges.append(tuple(path.name for path in raw_profiles))
            merged.write_bytes(b"merged")
            for raw in raw_profiles:
                raw.unlink()
            return len(raw_profiles)

        result = run_corpus(
            corpus,
            binary,
            profile_dir,
            merged_profile,
            toolchain=object(),
            command_runner=command_runner,
            profile_merger=profile_merger,
        )
        return result, calls, merges, binary, merged_profile

    def test_run_inherits_environment_and_owns_per_scenario_profiles(self) -> None:
        corpus = self.make_corpus(
            self.make_scenario("first"),
            self.make_scenario("second"),
        )
        with mock.patch.dict(
            os.environ,
            {
                "PGSO_INHERITED": "yes",
                "PGSO_UNSET_ME": "remove",
                "TMUX": "/tmp/user-tmux,1,0",
                "TMUX_PANE": "%1",
            },
            clear=False,
        ):
            result, calls, merges, binary, merged = self.run_fixture(corpus)

        self.assertEqual(2, result.passed)
        self.assertEqual(0, result.skipped)
        self.assertEqual(0, result.failed)
        self.assertEqual(2, result.merged_raw_profiles)
        self.assertEqual(
            sha256_bytes(binary.read_bytes()),
            sha256_bytes(
                (self.root / "zig-out" / "bin" / "fx").read_bytes()
            ),
        )
        self.assertTrue(merged.is_file())
        self.assertEqual(2, len(calls))
        self.assertEqual("yes", calls[0]["env"]["PGSO_INHERITED"])
        self.assertNotIn("PGSO_UNSET_ME", calls[0]["env"])
        self.assertNotIn("TMUX", calls[0]["env"])
        self.assertNotIn("TMUX_PANE", calls[0]["env"])
        self.assertEqual(
            str(self.root / "output" / "profiles" / "home"),
            calls[0]["env"]["HOME"],
        )
        patterns = [call["env"]["LLVM_PROFILE_FILE"] for call in calls]
        self.assertNotEqual(patterns[0], patterns[1])
        self.assertTrue(all("%m-%p-%c.profraw" in pattern for pattern in patterns))
        self.assertEqual(("first-module-123-.profraw",), merges[0])
        self.assertEqual(("second-module-123-.profraw",), merges[1])

    def test_run_cleans_the_isolated_tmux_server(self) -> None:
        marker = self.root / "tmux-cleaned"
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        tmux = fake_bin / "tmux"
        tmux.write_text(
            "#!/bin/sh\nprintf cleaned > \"$PGSO_TMUX_MARKER\"\n"
        )
        tmux.chmod(0o755)
        scenario = dataclasses_replace_env(
            self.make_scenario("tui", requires_tmux=True),
            ("PGSO_TMUX_MARKER", str(marker)),
        )
        corpus = self.make_corpus(scenario)

        with mock.patch.dict(
            os.environ,
            {"PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}"},
            clear=False,
        ):
            self.run_fixture(corpus)

        self.assertEqual("cleaned", marker.read_text())

    def test_run_stops_and_records_a_failed_scenario(self) -> None:
        corpus = self.make_corpus(
            self.make_scenario("first"),
            self.make_scenario("broken"),
            self.make_scenario("never-runs"),
        )

        with self.assertRaises(CorpusRunError) as raised:
            self.run_fixture(corpus, fail_scenario="broken")

        self.assertEqual(1, raised.exception.result.passed)
        self.assertEqual(1, raised.exception.result.failed)
        self.assertEqual(2, len(raised.exception.result.results))

    def test_run_stops_when_a_successful_scenario_writes_no_profile(self) -> None:
        corpus = self.make_corpus(self.make_scenario("missing-profile"))

        with self.assertRaisesRegex(CorpusRunError, "produced no raw profile"):
            self.run_fixture(corpus, omit_profile_for="missing-profile")

    def test_run_records_only_explicit_manifest_skips(self) -> None:
        corpus = self.make_corpus(
            self.make_scenario("skip", skip_reason="not applicable in smoke"),
            self.make_scenario("run"),
        )

        result, calls, merges, _, _ = self.run_fixture(corpus)

        self.assertEqual(1, result.passed)
        self.assertEqual(1, result.skipped)
        self.assertEqual(0, result.failed)
        self.assertEqual(1, len(calls))
        self.assertEqual(1, len(merges))

    def test_behavior_corpus_runs_the_exact_binary_without_profile_output(self) -> None:
        corpus = self.make_corpus(
            self.make_scenario("first"),
            self.make_scenario("second"),
        )
        binary = self.root / "candidate-fx"
        binary.write_bytes(b"candidate")
        calls: list[tuple[tuple[str, ...], dict[str, str]]] = []

        def command_runner(argv, **kwargs):
            calls.append((tuple(argv), dict(kwargs["env"])))
            return CommandResult(
                argv=tuple(argv),
                returncode=0,
                stdout="ok\n",
                stderr="",
                elapsed_seconds=0.2,
            )

        result = run_behavior_corpus(
            corpus,
            binary,
            self.root / "behavior-output",
            command_runner=command_runner,
        )

        canonical = self.root / "zig-out" / "bin" / "fx"
        self.assertEqual(2, result.passed)
        self.assertEqual(0, result.failed)
        self.assertEqual(0, result.merged_raw_profiles)
        self.assertTrue(all(call[0][0] == str(canonical) for call in calls))
        self.assertTrue(all("LLVM_PROFILE_FILE" not in call[1] for call in calls))
        self.assertTrue(
            all(
                call[1]["HOME"]
                == str(self.root / "behavior-output" / "home")
                for call in calls
            )
        )


def sha256_bytes(contents: bytes) -> str:
    import hashlib

    return hashlib.sha256(contents).hexdigest()


def dataclasses_replace_env(
    scenario: Scenario,
    item: tuple[str, str],
) -> Scenario:
    import dataclasses

    return dataclasses.replace(scenario, env_set=(*scenario.env_set, item))


if __name__ == "__main__":
    unittest.main()
