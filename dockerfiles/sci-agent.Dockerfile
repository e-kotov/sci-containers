# sci-agent — Node >= 18 + Claude Code, for clusters whose host userland is too old.
#
# WHY THIS IMAGE EXISTS: LiDO3 gateways and compute nodes run RHEL 7.9 with
# glibc 2.17 (verified 2026-08-28: `ldd --version` -> 2.17 on gw01 and cstd01-001).
# Node 18+ requires glibc 2.28. No Node binary can run natively there, so the agent
# has to come in a container — and since max_user_namespaces = 0 on that cluster,
# that container is run by udocker, not Apptainer.
#
# PLATFORM: multi-arch (amd64 + arm64). node:*-bookworm-slim publishes both, and the
# arm64 leg is genuinely useful — the same image runs on the user's Apple Silicon Mac.
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        git tmux ripgrep curl less ca-certificates openssh-client \
        procps python3 jq unzip \
    && rm -rf /var/lib/apt/lists/*

# Pinning by tag, not digest, on purpose: this is the agent, not an analysis
# environment. Reproducibility of a *result* is the analysis image's job; the agent
# image should track upstream fixes. The workflow tags every build with its commit
# SHA, so a specific build is still addressable.
RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force

# udocker maps the invoking user to uid 0 inside the container by default (P1) or
# keeps the host uid (F modes). Either way $HOME must be pointed at a writable path
# by the *caller* — on LiDO3 that is /work/$USER, since $HOME is read-only on
# compute nodes. slurm/lido3/lido-agent.slurm does this; do not bake a HOME here.
WORKDIR /work
ENTRYPOINT []
CMD ["bash"]
