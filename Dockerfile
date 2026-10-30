FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Native install, then copy the real binary to the path the profile allows
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && cp -L /root/.local/bin/claude /usr/local/bin/claude

RUN useradd --uid 1500 --create-home claude \
    && install -d -o claude -g claude /sandbox

WORKDIR /sandbox
USER claude

ENV DISABLE_AUTOUPDATER=1
# No telemetry or error reporting (statsig.anthropic.com, sentry.io)
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
