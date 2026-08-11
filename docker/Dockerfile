FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y curl xz-utils && rm -rf /var/lib/apt/lists/*
ARG ZIG_VERSION=0.16.0
RUN curl -sSfL https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz \
    | tar -xJ -C /opt && ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig
WORKDIR /fx
