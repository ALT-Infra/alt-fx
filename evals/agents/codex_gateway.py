from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from harbor.agents.installed.codex import Codex


class CodexGatewayAgent(Codex):
    """Codex wrapper with container-scoped Vercel AI Gateway auth/config."""

    _OPENAI_COMPAT_BASE_URL = "https://ai-gateway.vercel.sh/v1"

    @staticmethod
    def name() -> str:
        return "codex"

    def __init__(
        self,
        logs_dir: Path,
        *args: Any,
        extra_env: dict[str, str] | None = None,
        **kwargs: Any,
    ) -> None:
        gateway_key = os.environ.get("AI_GATEWAY_API_KEY", "")
        if not gateway_key:
            raise ValueError("AI_GATEWAY_API_KEY is required for Codex compare")

        scoped_env = dict(extra_env) if extra_env else {}
        scoped_env["OPENAI_API_KEY"] = gateway_key
        scoped_env["OPENAI_BASE_URL"] = self._OPENAI_COMPAT_BASE_URL
        scoped_env["CODEX_AUTH_JSON_PATH"] = ""
        scoped_env["CODEX_FORCE_AUTH_JSON"] = "0"

        super().__init__(logs_dir, *args, extra_env=scoped_env, **kwargs)
