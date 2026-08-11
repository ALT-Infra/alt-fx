FROM --platform=linux/amd64 debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        nodejs \
        npm \
        python3 \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

COPY fx /usr/local/bin/fx

RUN chmod 0755 /usr/local/bin/fx \
    && useradd --create-home --shell /bin/bash agent \
    && mkdir -p /app /logs/agent /logs/verifier /logs/artifacts /home/agent/.fx \
    && chown -R agent:agent /app /logs /home/agent

WORKDIR /app
