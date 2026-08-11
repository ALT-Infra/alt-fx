from __future__ import annotations

import copy
import json
import os
import shlex
from typing import Any

from harbor.agents.installed.base import with_prompt_template
from harbor.agents.installed.opencode import OpenCode
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext


class OpenCodeGatewayAgent(OpenCode):
    """OpenCode wrapper with container-local Vercel AI Gateway auth/config."""

    _OPENAI_COMPAT_BASE_URL = "https://ai-gateway.vercel.sh/v1"

    @staticmethod
    def name() -> str:
        return "opencode"

    def _gateway_setup_command(self, model_id: str) -> str:
        config: dict[str, Any] = {
            "$schema": "https://opencode.ai/config.json",
            "provider": {
                "openai": {
                    "models": {
                        model_id: {},
                    },
                    "options": {
                        "baseURL": self._OPENAI_COMPAT_BASE_URL,
                    },
                },
            },
        }
        config = self._deep_merge(config, copy.deepcopy(self._opencode_config))
        config_json = shlex.quote(json.dumps(config, indent=2))
        return (
            "mkdir -p ~/.config/opencode ~/.local/share/opencode && "
            "cat > ~/.local/share/opencode/auth.json <<EOF\n"
            "{\"openai\":{\"type\":\"api\",\"key\":\"${OPENAI_API_KEY}\"}}\n"
            "EOF\n"
            f"printf %s {config_json} > ~/.config/opencode/opencode.json"
        )

    def _gateway_model_id(self) -> str:
        if not self.model_name or "/" not in self.model_name:
            raise ValueError(
                "OpenCode gateway model must use provider/<gateway-model> format"
            )

        provider, model_id = self.model_name.split("/", 1)
        if provider not in {"openai", "vercel"}:
            raise ValueError(
                "OpenCode gateway model must use openai/<gateway-model> format"
            )
        return model_id

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        escaped_instruction = shlex.quote(instruction)

        gateway_key = self._get_env("AI_GATEWAY_API_KEY") or os.environ.get(
            "AI_GATEWAY_API_KEY"
        )
        if not gateway_key:
            raise ValueError("AI_GATEWAY_API_KEY is required for OpenCode compare")

        model_id = self._gateway_model_id()
        env = {
            "AI_GATEWAY_API_KEY": gateway_key,
            "OPENAI_API_KEY": gateway_key,
            "OPENAI_BASE_URL": self._OPENAI_COMPAT_BASE_URL,
            "OPENCODE_FAKE_VCS": "git",
        }

        skills_command = self._build_register_skills_command()
        if skills_command:
            await self.exec_as_agent(environment, command=skills_command, env=env)

        await self.exec_as_agent(
            environment,
            command=self._gateway_setup_command(model_id),
            env=env,
        )

        cli_flags = self.build_cli_flags()
        cli_flags_arg = (cli_flags + " ") if cli_flags else ""
        model = shlex.quote(f"openai/{model_id}")

        await self.exec_as_agent(
            environment,
            command=(
                ". ~/.nvm/nvm.sh; "
                f"opencode --model={model} run --format=json "
                f"{cli_flags_arg}--thinking --dangerously-skip-permissions -- "
                f"{escaped_instruction} 2>&1 </dev/null | stdbuf -oL tee "
                "/logs/agent/opencode.txt"
            ),
            env=env,
        )
