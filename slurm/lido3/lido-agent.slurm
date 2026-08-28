#!/bin/bash -l
#SBATCH --job-name=lido-agent
#SBATCH --partition=long
#SBATCH --time=36:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=24G
#SBATCH --constraint=cstd01
#SBATCH --signal=B:TERM@60
#SBATCH --output=/work/%u/logs/lido-agent-%j.out
#SBATCH --error=/work/%u/logs/lido-agent-%j.err
#
# Mode B — the agent workstation as a LiDO3 compute allocation.
#
# The job holds a tmux server ON THE NODE (outside the container) whose single
# window runs the sci-agent image under udocker. Attaching is plain SSH from a
# gateway into your own allocated node, then `tmux attach` — LiDO3 permits that,
# so unlike the GWDG script there is NO sshd inside the container to configure.
#
# HARD LIMIT OF THIS MODE: $HOME is READ-ONLY here. No `git commit`, no writes to
# docs/memory/. Compute only. Git and memory writes happen on the gateway (Mode A)
# or on the Mac. An agent that forgets this will fail its first commit with EROFS.
#
# --output must exist before submission: slurmd opens it before this script runs.
# lido-agent-remote creates /work/$USER/logs; do not remove it.

set -euo pipefail

WORK="${WORK:-/work/${USER}}"
REPO="${SCI_AGENT_REPO:-ghcr.io/e-kotov/sci-agent}"
DIGEST="${SCI_AGENT_DIGEST:-}"
SESSION="${LIDO_AGENT_SESSION:-lido-agent}"
SOCK="${LIDO_AGENT_SOCK:-${WORK}/.state/lido-agent.tmux.sock}"

[ -n "$DIGEST" ] || { echo "set SCI_AGENT_DIGEST=sha256:..." >&2; exit 2; }

export UDOCKER_DIR="${UDOCKER_DIR:-${WORK}/.udocker}"
export PATH="${UDOCKER_PREFIX:-${WORK}/.local}/bin:$PATH"

SCRATCH_DIR="/scratch/${USER}/${SLURM_JOB_ID}"
mkdir -p "$SCRATCH_DIR" "${WORK}/agent-home" "$(dirname "$SOCK")"
rm -f "$SOCK"
trap 'rm -rf "$SCRATCH_DIR"; rm -f "$SOCK"' EXIT TERM

# Resolve the helper by REPO PATH, never by $(dirname "$0"): Slurm copies the batch
# script into the node's spool directory before running it, so $0 is
# /var/spool/slurm/d/jobNNN/slurm_script and dirname $0 contains nothing else.
# (Observed as "No such file or directory" on job 40190615, 2026-08-28.)
SCI_CONTAINERS_DIR="${SCI_CONTAINERS_DIR:-${WORK}/sci-containers}"
PULL="${SCI_CONTAINERS_DIR}/slurm/lido3/udocker_pull.sh"
[ -x "$PULL" ] || { echo "missing $PULL — clone e-kotov/sci-containers into $SCI_CONTAINERS_DIR" >&2; exit 1; }
"$PULL" "$REPO" "$DIGEST" sci-agent
udocker setup --execmode="${UDOCKER_EXECMODE:-F3}" sci-agent

# --- Why this job holds the allocation but hosts NO terminal multiplexer -------------
# The obvious design runs tmux here so the session survives a dropped laptop connection.
# On this cluster it cannot, and both halves were measured on cstd01-001 (2026-08-28):
#
#   * Compute nodes have NO tmux at all — `bash: tmux: command not found`. Only the
#     gateways carry it.
#   * The tmux inside the sci-agent image cannot open a socket under udocker:
#       F3 (Fakechroot): "error creating <path> (No such file or directory)" for a socket
#                        on /work, on /scratch, and via TMUX_TMPDIR alike — fakechroot
#                        redirects AF_UNIX paths (FAKECHROOT_AF_UNIX_PATH) and the
#                        redirected path does not resolve.
#       P1 (PRoot):      "access not allowed" — PRoot maps the caller to uid 0, and tmux
#                        refuses a socket directory it does not own.
#
# So the multiplexer lives on the GATEWAY, where tmux exists and is native, and its
# window SSHes into this node and runs the container. The gateway then carries only an
# ssh client and a tmux server — a few MB, nothing ITMC's CPU-hog policy is aimed at —
# while every byte of real work happens inside this allocation.
#
# This job's only duties: pre-pull the image so attaching is instant, and hold the
# allocation open.
cat <<INFO
Node:    $(hostname -s)
Job:     ${SLURM_JOB_ID}
Image:   sci-agent (execmode ${UDOCKER_EXECMODE:-F3})
Attach:  lido-agent-remote attach ${SLURM_JOB_ID}
NOTE:    $HOME is READ-ONLY here. No git commit, no docs/memory/ writes.
INFO

udocker setup --execmode="${UDOCKER_EXECMODE:-F3}" sci-agent

# Prove the image actually runs before anyone tries to attach to it, so a broken pull
# surfaces here, in the job log, instead of as a confusing failure at attach time.
udocker run --nobanner --volume="${WORK}:${WORK}" --env=HOME="${WORK}/agent-home" \
    sci-agent bash -lc 'echo "ready: node $(node -v), $(claude --version 2>&1 | head -1)"'

# Hold the allocation. `--signal=B:TERM@60` plus the EXIT trap cleans up on scancel.
while true; do sleep 60; done
