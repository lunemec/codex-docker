# Dockerfile
FROM node:22-trixie

ARG RUST_TOOLCHAIN=stable

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash ca-certificates curl git docker-cli docker-compose docker-buildx iptables python3 make g++ ffmpeg \
  less vim nano tree tmux fzf ripgrep fd-find jq yq zip xz-utils \
  cloc sloccount hyperfine entr httpie xh ncdu \
  wrk apache2-utils hey wget aria2 \
  kubectx \
  sudo procps iproute2 iputils-ping dnsutils netcat-openbsd lsof strace rsync openssh-client \
  build-essential pkg-config cmake ninja-build libssl-dev libffi-dev \
  python3-pip python3-venv pipx shellcheck shfmt \
  && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

RUN set -eux; \
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list; \
  apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) glab_arch='x86_64' ;; \
    arm64) glab_arch='arm64' ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac; \
  GLAB_VERSION="$(curl -fsSL https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases | jq -r '.[0].tag_name' | sed 's/^v//')"; \
  echo "Installing glab ${GLAB_VERSION}"; \
  curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${glab_arch}.tar.gz" \
    -o /tmp/glab.tar.gz; \
  tar -xzf /tmp/glab.tar.gz -C /tmp; \
  install -m 0755 /tmp/bin/glab /usr/local/bin/glab; \
  rm -rf /tmp/glab.tar.gz /tmp/bin

RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) goarch='amd64' ;; \
    arm64) goarch='arm64' ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac; \
  GO_VERSION="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1 | sed 's/^go//')"; \
  echo "Installing Go ${GO_VERSION}"; \
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz" -o /tmp/go.tgz; \
  rm -rf /usr/local/go; \
  tar -C /usr/local -xzf /tmp/go.tgz; \
  rm -f /tmp/go.tgz

ENV PATH="/usr/local/go/bin:/root/.cargo/bin:/root/.local/bin:${PATH}"
ENV RUSTUP_HOME="/root/.rustup"
ENV CARGO_HOME="/root/.cargo"
ENV PIPX_HOME="/opt/pipx"
ENV PIPX_BIN_DIR="/usr/local/bin"

RUN cat >/etc/profile.d/codex-paths.sh <<'EOF' \
  && chmod 0644 /etc/profile.d/codex-paths.sh
#!/usr/bin/env sh
for p in /usr/local/go/bin /root/.cargo/bin /root/.local/bin; do
  case ":$PATH:" in
    *":$p:"*) ;;
    *) PATH="$p:$PATH" ;;
  esac
done
export PATH
EOF

RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain "${RUST_TOOLCHAIN}"

RUN pipx install uv \
  && pipx install poetry \
  && pipx install pre-commit

RUN python3 -m venv /opt/voice-stt \
  && /opt/voice-stt/bin/pip install --upgrade pip \
  && /opt/voice-stt/bin/pip install --no-cache-dir faster-whisper requests

RUN corepack enable && corepack prepare pnpm@latest --activate

RUN npm install -g @openai/codex @anthropic-ai/claude-code @google/gemini-cli opencode-ai @ralph-orchestrator/ralph-cli @googleworkspace/cli @aisuite/chub openclaw kimaki context-mode @playwright/test \
  && mv /usr/local/bin/codex /usr/local/bin/codex-real \
  && mv /usr/local/bin/claude /usr/local/bin/claude-real

RUN npx playwright install --with-deps chromium

# Pinned: Cursor removed their version discovery API (api.cursor.com/version/lab/latest
# returns 404 as of 2026-04). Update manually when new versions are confirmed.
ARG CURSOR_AGENT_VERSION=2026.02.27-e7d2ef6
RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) cursor_arch='x64' ;; \
    arm64) cursor_arch='arm64' ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac; \
  echo "Installing cursor-agent ${CURSOR_AGENT_VERSION}"; \
  cursor_root="/root/.local/share/cursor-agent/versions/${CURSOR_AGENT_VERSION}"; \
  mkdir -p "$cursor_root" /root/.local/bin; \
  curl -fsSL "https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/${cursor_arch}/agent-cli-package.tar.gz" \
    | tar --strip-components=1 -xzf - -C "$cursor_root"; \
  ln -sf "${cursor_root}/cursor-agent" /root/.local/bin/cursor; \
  ln -sf "${cursor_root}/cursor-agent" /root/.local/bin/agent; \
  ln -sf "${cursor_root}/cursor-agent" /root/.local/bin/cursor-agent

RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) forge_arch='x86_64-unknown-linux-gnu' ;; \
    arm64) forge_arch='aarch64-unknown-linux-gnu' ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac; \
  FORGE_VERSION="$(curl -fsSL https://api.github.com/repos/antinomyhq/forgecode/releases/latest | jq -r '.tag_name' | sed 's/^v//')"; \
  echo "Installing forge ${FORGE_VERSION}"; \
  curl -fsSL "https://github.com/antinomyhq/forgecode/releases/download/v${FORGE_VERSION}/forge-${forge_arch}" \
    -o /tmp/forge; \
  install -m 0755 /tmp/forge /usr/local/bin/forge; \
  rm -f /tmp/forge

RUN GOBIN=/usr/local/bin go install github.com/bojand/ghz/cmd/ghz@latest \
  && GOBIN=/usr/local/bin go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest \
  && GOBIN=/usr/local/bin go install github.com/rs/curlie@latest

RUN mkdir -p /home/coder/.config/opencode \
  && cat >/home/coder/.config/opencode/opencode.json <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "context-mode": {
      "type": "local",
      "command": ["context-mode"]
    }
  },
  "plugin": ["context-mode"]
}
EOF

RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) gcloud_arch='x86_64'; kubectl_arch='amd64' ;; \
    arm64) gcloud_arch='arm'; kubectl_arch='arm64' ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac; \
  CLOUD_SDK_VERSION="$(curl -fsSL https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json | jq -r '.version')"; \
  echo "Installing gcloud ${CLOUD_SDK_VERSION}"; \
  curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${CLOUD_SDK_VERSION}-linux-${gcloud_arch}.tar.gz" -o /tmp/google-cloud-cli.tgz; \
  tar -C /usr/local -xzf /tmp/google-cloud-cli.tgz; \
  rm -f /tmp/google-cloud-cli.tgz; \
  ln -sf /usr/local/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud; \
  ln -sf /usr/local/google-cloud-sdk/bin/bq /usr/local/bin/bq; \
  ln -sf /usr/local/google-cloud-sdk/bin/gsutil /usr/local/bin/gsutil; \
  /usr/local/google-cloud-sdk/bin/gcloud components install gke-gcloud-auth-plugin --quiet; \
  ln -sf /usr/local/google-cloud-sdk/bin/gke-gcloud-auth-plugin /usr/local/bin/gke-gcloud-auth-plugin; \
  KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"; \
  echo "Installing kubectl ${KUBECTL_VERSION}"; \
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${kubectl_arch}/kubectl" -o /usr/local/bin/kubectl; \
  chmod 0755 /usr/local/bin/kubectl

COPY scripts/*.sh /opt/toolbelt/scripts/
COPY scripts/voice_autotranscribe.py /usr/local/bin/voice_autotranscribe.py
COPY container/toolbelt-entrypoint.sh /usr/local/bin/toolbelt-entrypoint

RUN chmod +x /opt/toolbelt/scripts/*.sh \
  /usr/local/bin/voice_autotranscribe.py \
  /usr/local/bin/toolbelt-entrypoint \
  && ln -sf /opt/toolbelt/scripts/voice-stt-start.sh /usr/local/bin/voice-stt-start \
  && ln -sf /opt/toolbelt/scripts/voice-stt-stop.sh /usr/local/bin/voice-stt-stop \
  && ln -sf /opt/toolbelt/scripts/voice-stt-once.sh /usr/local/bin/voice-stt-once

RUN set -eux; \
  node --version; npm --version; pnpm --version; \
  python3 --version; pip3 --version; uv --version; poetry --version; \
  go version; rustc --version; cargo --version; \
  rg --version; fd --version; jq --version; yq --version; \
  fzf --version; cloc --version; sloccount --version; hyperfine --version; \
  http --version; xh --version; curlie --version; ncdu --version; command -v entr ffmpeg; \
  claude-real --version; gemini --version; opencode --version; cursor --version; agent --version; cursor-agent --version; forge --version; \
  wrk --version || true; ab -V; hey --help | head -n 2; \
  ghz --version; grpcurl --version; wget --version; aria2c --version; \
  gcloud --version | head -n 1; command -v gke-gcloud-auth-plugin kubectl kubectx kubens; gke-gcloud-auth-plugin --version >/dev/null; kubectl version --client=true >/dev/null; \
  docker --version; docker compose version; docker-compose --version; docker buildx version; command -v iptables; \
  openclaw --version; command -v kimaki; \
  /opt/voice-stt/bin/python -c 'from faster_whisper import WhisperModel; print("faster-whisper ok")'; \
  command -v voice-stt-start voice-stt-stop voice-stt-once; \
  ralph --version; \
  context-mode --version; \
  gh --version; glab --version; \
  npx playwright --version

# Default: fully automatic, no sandbox/approvals (for isolated container use only)
RUN cat >/usr/local/bin/codex <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -f /.dockerenv ]] || { echo "Refusing outside Docker"; exit 1; }
exec /usr/local/bin/codex-real \
  --dangerously-bypass-approvals-and-sandbox \
  "$@"
EOF
RUN chmod +x /usr/local/bin/codex

# Default: fully automatic, no permission prompts (for isolated container use only)
RUN cat >/usr/local/bin/claude <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -f /.dockerenv ]] || { echo "Refusing outside Docker"; exit 1; }
exec /usr/local/bin/claude-real \
  --dangerously-skip-permissions \
  "$@"
EOF
RUN chmod +x /usr/local/bin/claude


RUN useradd -m -s /bin/bash -d /home/coder coder \
  && echo 'coder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/coder \
  && chmod 0440 /etc/sudoers.d/coder

ENTRYPOINT ["/usr/local/bin/toolbelt-entrypoint"]
CMD ["bash"]
