from __future__ import annotations

import os
import shlex
from pathlib import Path
from typing import Any

from harbor.agents.installed.claude_code import ClaudeCode


class ClaudeCodeGatewayAgent(ClaudeCode):
    """Claude Code wrapper with container-scoped Vercel AI Gateway env."""

    _GATEWAY_BASE_URL = "https://ai-gateway.vercel.sh"
    _CONFIG_DIR = "/tmp/claude-code-config"

    @staticmethod
    def name() -> str:
        return "claude-code"

    def __init__(
        self,
        logs_dir: Path,
        *args: Any,
        extra_env: dict[str, str] | None = None,
        **kwargs: Any,
    ) -> None:
        gateway_key = os.environ.get("AI_GATEWAY_API_KEY", "")
        if not gateway_key:
            raise ValueError("AI_GATEWAY_API_KEY is required for Claude Code compare")

        scoped_env = dict(extra_env) if extra_env else {}
        scoped_env["ANTHROPIC_BASE_URL"] = self._GATEWAY_BASE_URL
        scoped_env["ANTHROPIC_AUTH_TOKEN"] = gateway_key
        scoped_env["ANTHROPIC_API_KEY"] = ""
        scoped_env["CLAUDE_CONFIG_DIR"] = self._CONFIG_DIR

        super().__init__(logs_dir, *args, extra_env=scoped_env, **kwargs)

    async def _prepare_agent_log_dir(self, environment: Any) -> None:
        user = str(getattr(environment, "default_user", None) or "agent")
        await self.exec_as_root(
            environment,
            command=(
                "mkdir -p /logs/agent /logs/artifacts && "
                f"(chown -R {shlex.quote(user)} /logs/agent /logs/artifacts "
                "2>/dev/null || true) && "
                "chmod -R a+rwX /logs/agent /logs/artifacts"
            ),
        )

    async def _copy_sessions_to_logs(self, environment: Any) -> None:
        user = str(getattr(environment, "default_user", None) or "agent")
        await self.exec_as_root(
            environment,
            command=(
                f"if [ -d {shlex.quote(self._CONFIG_DIR)} ]; then "
                "rm -rf /logs/agent/sessions && "
                "mkdir -p /logs/agent && "
                f"cp -R {shlex.quote(self._CONFIG_DIR)} /logs/agent/sessions && "
                f"(chown -R {shlex.quote(user)} /logs/agent/sessions "
                "2>/dev/null || true) && "
                "chmod -R a+rwX /logs/agent/sessions; "
                "fi"
            ),
        )

    async def run(self, *args: Any, **kwargs: Any) -> None:
        environment = kwargs.get("environment")
        if environment is None and len(args) >= 2:
            environment = args[1]
        if environment is None:
            raise ValueError("ClaudeCodeGatewayAgent.run requires an environment")

        await self._prepare_agent_log_dir(environment)
        try:
            await super().run(*args, **kwargs)
        finally:
            await self._copy_sessions_to_logs(environment)
