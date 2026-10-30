# syntax=docker/dockerfile:1.8
# Build from the REPOSITORY ROOT with --platform=linux/amd64.
ARG OPENENV_BASE=ghcr.io/huggingface/openenv-base:latest
# TODO(release): pin every FROM below (and OPENENV_BASE) to a resolved @sha256 digest.
FROM node:24-bookworm-slim AS node
RUN mkdir -p /opt/strim-toolchains/node/bin /opt/strim-toolchains/node/lib \
    && cp -a /usr/local/bin/node /opt/strim-toolchains/node/bin/node \
    && cp -a /usr/local/lib/node_modules /opt/strim-toolchains/node/lib/node_modules \
    && ln -s ../lib/node_modules/npm/bin/npm-cli.js /opt/strim-toolchains/node/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /opt/strim-toolchains/node/bin/npx
FROM golang:1.25-bookworm AS go
FROM rust:1.91-bookworm AS rust
RUN mkdir -p /opt/strim-toolchains/rust \
    && cp -a /usr/local/rustup/toolchains/*/. /opt/strim-toolchains/rust/
FROM oven/bun:1.3.0 AS bun

FROM ${OPENENV_BASE} AS toolchains
USER root
ARG TARGETARCH
# Published images are linux/amd64. STRIM_VALIDATE_ARM64=1 allows a local arm64 build only to run the
# validation suite natively (Bubblewrap cannot create namespaces under amd64 emulation on Apple silicon).
ARG STRIM_VALIDATE_ARM64=0
RUN { test "$TARGETARCH" = amd64 || test "$STRIM_VALIDATE_ARM64" = 1; } \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       bash bubblewrap build-essential ca-certificates git \
       default-jdk-headless python3 python3-venv ruby ruby-minitest \
    && rm -rf /var/lib/apt/lists/*
# Node lives in its own prefix: copying the node image's /usr/local over the
# base image's /usr/local could clobber the base's own files.
COPY --from=node /opt/strim-toolchains/node /opt/strim-toolchains/node
COPY --from=go /usr/local/go /usr/local/go
COPY --from=rust /opt/strim-toolchains/rust /opt/strim-toolchains/rust
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
ENV PATH="/opt/strim-toolchains/node/bin:/opt/strim-toolchains/rust/bin:/usr/local/go/bin:${PATH}"
RUN npm install --global --prefix /opt/strim-toolchains/node typescript@5.9.3 \
    && npm cache clean --force \
    && node --version && tsc --version && bun --version && go version \
    && ruby -rminitest -e 'puts RUBY_VERSION' \
    && python3 --version && cargo --version && javac -version

# Agent image: toolchains only. No checkout, task archive, tests or solution.
FROM toolchains AS agent
RUN mkdir -p /workspace && chown 1000:1000 /workspace
WORKDIR /workspace
USER 1000:1000
CMD ["/bin/bash"]

# Trusted server/grader image. Never give the agent a shell in this image.
FROM toolchains AS grader
WORKDIR /app
COPY envs/pyproject.toml /app/envs/pyproject.toml
COPY envs/strim_envs /app/envs/strim_envs
RUN python3 -m venv /app/venv \
    && /app/venv/bin/pip install --no-cache-dir '/app/envs[openenv,test]'
# Bind mount keeps the full corpus and solution patches out of image layers.
# Only selected manifests/snapshots are exported into the trusted grader image.
RUN --mount=type=bind,source=bench/agenttasks,target=/corpus,ro \
    STRIM_ENVS_CORPUS=/corpus /app/venv/bin/python -m strim_envs.assets /grader
# Run unprivileged. Bubblewrap needs unprivileged user namespaces on the host.
RUN useradd --uid 1001 --no-create-home --shell /usr/sbin/nologin app \
    && chown -R root:root /grader /app \
    && chmod -R u+rwX,go+rX,go-w /grader /app
USER 1001:1001
# OpenEnv Arena runs each episode in a fresh sandbox that cannot create nested namespaces:
# the per-episode container is then the isolation boundary (see README). Grader image only.
ENV STRIM_ENVS_CONTAINER_BOUNDARY=1 \
    STRIM_ENVS_CORPUS=/grader \
    ENABLE_WEB_INTERFACE=false \
    PATH="/app/venv/bin:${PATH}"
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["/app/venv/bin/python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]
CMD ["/app/venv/bin/python", "-m", "uvicorn", "strim_envs.openenv_server:app", "--host", "0.0.0.0", "--port", "8000"]
