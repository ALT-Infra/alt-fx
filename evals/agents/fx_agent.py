from __future__ import annotations

import hashlib
import json
import os
import shlex
from pathlib import Path
from typing import Any

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext


class FxAgent(BaseInstalledAgent):
    """Harbor installed-agent wrapper for the local Linux fx binary."""

    _REMOTE_SETUP_BINARY = "/installed-agent/fx"
    _REMOTE_VERSION_FILE = "/installed-agent/fx.version"
    _REMOTE_BINARY = "/usr/local/bin/fx"
    _EFFORT_VALUES = {"auto", "none", "minimal", "low", "medium", "high", "xhigh", "max"}

    def __init__(
        self,
        logs_dir: Path,
        *args: Any,
        effort: str | None = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(logs_dir, *args, **kwargs)
        self.effort = self._parse_effort(effort)

    @staticmethod
    def name() -> str:
        return "fx"

    @staticmethod
    def _repo_root() -> Path:
        return Path(__file__).resolve().parents[2]

    @classmethod
    def _binary_path(cls) -> Path:
        configured = os.environ.get("FX_AGENT_BINARY_PATH")
        path = Path(configured) if configured else cls._repo_root() / "evals/images/fx"
        return path.expanduser().resolve()

    @classmethod
    def _validate_binary(cls, path: Path) -> None:
        if not path.exists():
            raise FileNotFoundError(f"fx agent binary not found: {path}")
        if not path.is_file():
            raise ValueError(f"fx agent binary is not a file: {path}")
        if not os.access(path, os.X_OK):
            raise PermissionError(f"fx agent binary is not executable: {path}")

    @classmethod
    def _source_version(cls) -> str:
        version_prefix = 'pub const version = "'
        main_path = cls._repo_root() / "src/main.zig"
        for line in main_path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith(version_prefix) and stripped.endswith('";'):
                return stripped[len(version_prefix) : -2]
        raise ValueError(f"could not find fx version in {main_path}")

    async def install(self, environment: BaseEnvironment) -> None:
        binary_path = self._binary_path()
        self._validate_binary(binary_path)

        version_path = self.logs_dir / "setup" / "fx-version.txt"
        version_path.parent.mkdir(parents=True, exist_ok=True)
        version_path.write_text(f"{self._source_version()}\n", encoding="utf-8")

        await environment.upload_file(binary_path, self._REMOTE_SETUP_BINARY)
        await environment.upload_file(version_path, self._REMOTE_VERSION_FILE)
        await self.exec_as_root(
            environment,
            command=(
                "mkdir -p /usr/local/bin && "
                f"cp {shlex.quote(self._REMOTE_SETUP_BINARY)} "
                f"{shlex.quote(self._REMOTE_BINARY)} && "
                f"chmod 0755 {shlex.quote(self._REMOTE_BINARY)} && "
                "(mkdir -p /home/agent/.fx && "
                "chown -R agent:agent /home/agent/.fx || true) && "
                "(mkdir -p /logs/artifacts && "
                "chown -R agent:agent /logs/artifacts || true)"
            ),
        )

    def get_version_command(self) -> str | None:
        return f"cat {shlex.quote(self._REMOTE_VERSION_FILE)}"

    @staticmethod
    def _parse_timeout_ms(raw: str | None) -> int:
        if not raw:
            return 300_000
        try:
            value = int(raw)
        except ValueError as exc:
            raise ValueError(f"FX_AGENT_TIMEOUT_MS must be an integer: {raw}") from exc
        if value <= 0:
            raise ValueError("FX_AGENT_TIMEOUT_MS must be positive")
        return value

    @staticmethod
    def _read_json(path: Path) -> dict[str, Any] | None:
        try:
            with path.open("r", encoding="utf-8") as handle:
                value = json.load(handle)
        except (OSError, json.JSONDecodeError):
            return None
        return value if isinstance(value, dict) else None

    @classmethod
    def _parse_effort(cls, raw: str | None) -> str | None:
        if raw is None:
            return None
        effort = raw.strip().lower()
        if effort not in cls._EFFORT_VALUES:
            expected = ", ".join(sorted(cls._EFFORT_VALUES))
            raise ValueError(f"invalid fx effort {raw!r}; expected one of: {expected}")
        return effort

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        model = self.model_name or self._get_env("FX_MODEL")
        if not model:
            raise ValueError("FxAgent requires a Harbor model name")

        timeout_ms = self._parse_timeout_ms(self._get_env("FX_AGENT_TIMEOUT_MS"))
        timeout_sec = (timeout_ms + 999) // 1000 + 30
        binary_version = self._source_version()
        instruction_bytes = instruction.encode("utf-8")
        wrapper = {
            "agent": self.name(),
            "model": model,
            "timeout_ms": timeout_ms,
            "binary_version": binary_version,
            "command": {
                "cwd": "/app",
                "argv": [
                    "/usr/local/bin/fx",
                    "ask",
                    "--auto",
                    "--json",
                    "--no-save",
                    "--timeout",
                    str(timeout_ms),
                    "<instruction>",
                ],
                "stdout_path": "/logs/agent/fx-result.json",
                "stderr_path": "/logs/agent/fx-stderr.txt",
                "exit_code_path": "/logs/agent/fx-exit-code.txt",
            },
            "instruction": {
                "sha256": hashlib.sha256(instruction_bytes).hexdigest(),
                "bytes": len(instruction_bytes),
            },
        }
        if self.effort is not None:
            wrapper["effort"] = self.effort
        wrapper_json = json.dumps(wrapper, sort_keys=True)

        settings: dict[str, Any] = {}
        if self.effort is not None:
            settings["effort"] = self.effort
        settings_json = json.dumps(settings, sort_keys=True)

        env = {
            "HOME": "/tmp/fx-home",
            "NO_COLOR": "1",
            "FX_MODEL": model,
        }
        for key in ("AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN"):
            value = self._get_env(key)
            if value:
                env[key] = value

        command = (
            "mkdir -p /logs/agent /tmp/fx-home/.fx && "
            f"printf '%s\\n' {shlex.quote(settings_json)} > /app/.fx.json && "
            "cd /app && "
            "/usr/local/bin/fx ask --auto --json --no-save "
            f"--timeout {timeout_ms} {shlex.quote(instruction)} "
            "> /logs/agent/fx-result.json 2> /logs/agent/fx-stderr.txt; "
            'code="$?"; '
            'echo "$code" > /logs/agent/fx-exit-code.txt; '
            "exit 0"
        )

        await self.exec_as_agent(
            environment,
            command=command,
            env=env,
            cwd="/app",
            timeout_sec=timeout_sec,
        )
        await self.exec_as_root(
            environment,
            command=(
                "mkdir -p /logs/artifacts && "
                "cp -f /logs/agent/fx-exit-code.txt /logs/artifacts/fx-exit-code.txt && "
                "cp -f /logs/agent/fx-result.json /logs/artifacts/fx-result.json && "
                "cp -f /logs/agent/fx-stderr.txt /logs/artifacts/fx-stderr.txt && "
                f"printf '%s\\n' {shlex.quote(wrapper_json)} > /logs/artifacts/fx-wrapper.json"
            ),
        )

    def populate_context_post_run(self, context: AgentContext) -> None:
        metadata: dict[str, Any] = {}

        exit_code_path = self.logs_dir / "fx-exit-code.txt"
        try:
            metadata["exit_code"] = int(exit_code_path.read_text().strip())
        except (OSError, ValueError):
            pass

        result = self._read_json(self.logs_dir / "fx-result.json")
        if result:
            if "exit_code" in result:
                metadata["exit_code"] = result["exit_code"]
            if "steps" in result:
                metadata["steps"] = result["steps"]
            if "model" in result:
                metadata["model"] = result["model"]
            if "session_id" in result:
                metadata["session_id"] = result["session_id"]

            tool_calls = result.get("tool_calls")
            if isinstance(tool_calls, list):
                metadata["tool_call_count"] = len(tool_calls)

        if metadata:
            existing = context.metadata or {}
            existing.update(metadata)
            context.metadata = existing
