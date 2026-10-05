#!/bin/bash -l
#SBATCH --job-name=lido-agent
#SBATCH --partition=long
#SBATCH --time=36:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=24G
#SBATCH --signal=B:TERM@60
#SBATCH --output=/work/%u/logs/lido-agent-%j.out
#SBATCH --error=/work/%u/logs/lido-agent-%j.err
#
# Mode B — the agent workstation as a LiDO3 compute allocation.
#
# The persistent terminal multiplexer lives on a gateway. Its window SSHes into
# this allocated node and runs the sci-agent image under udocker. Compute-node
# $HOME is read-only, so the interactive project checkout and agent HOME live in
# /work. Brain-global memory remains off this project workspace.
#
# --output must exist before submission: slurmd opens it before this script runs.
# lido-agent-remote creates /work/$USER/logs; do not remove it.

set -euo pipefail

WORK="${WORK:-/work/${USER}}"
REPO="${SCI_AGENT_REPO:-ghcr.io/e-kotov/sci-agent}"
DIGEST="${SCI_AGENT_DIGEST:-}"
PROJECT="${SCI_AGENT_PROJECT:-${WORK}}"
READY_FILE="${LIDO_AGENT_READY_FILE:-${WORK}/.state/lido-agent/ready-${SLURM_JOB_ID}}"
TUDO_ROUTE="${LIDO_TUDO_ROUTE:-cluster-default}"
GPU_TYPE="${LIDO_AGENT_GPU:-}"

[ -n "$DIGEST" ] || { echo "set SCI_AGENT_DIGEST=sha256:..." >&2; exit 2; }

export UDOCKER_DIR="${UDOCKER_DIR:-${WORK}/.udocker}"
export PATH="${UDOCKER_PREFIX:-${WORK}/.local}/bin:$PATH"

SCRATCH_DIR="/scratch/${USER}/${SLURM_JOB_ID}"
mkdir -p "$SCRATCH_DIR" "${WORK}/agent-home" "$(dirname "$READY_FILE")"
rm -f "$READY_FILE"
trap 'rm -rf "$SCRATCH_DIR"; rm -f "$READY_FILE"' EXIT
trap 'exit 143' TERM

# Resolve the helper by REPO PATH, never by $(dirname "$0"): Slurm copies the batch
# script into the node's spool directory before running it, so $0 is
# /var/spool/slurm/d/jobNNN/slurm_script and dirname $0 contains nothing else.
# (Observed as "No such file or directory" on job 40190615, 2026-08-28.)
SCI_CONTAINERS_DIR="${SCI_CONTAINERS_DIR:-${WORK}/sci-containers}"
PULL="${SCI_CONTAINERS_DIR}/slurm/lido3/udocker_pull.sh"
[ -x "$PULL" ] || { echo "missing $PULL — clone e-kotov/sci-containers into $SCI_CONTAINERS_DIR" >&2; exit 1; }
"$PULL" "$REPO" "$DIGEST" sci-agent
# Execmode was set once at create time by udocker_pull.sh; see the note there.
# Do NOT call `udocker setup` per run: it re-patches the whole rootfs.

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
Node:       $(hostname -s)
Job:        ${SLURM_JOB_ID}
Image:      sci-agent (execmode ${UDOCKER_EXECMODE:-F3})
Project:    ${PROJECT}
GPU:        ${GPU_TYPE:-none}
TUDO route: ${TUDO_ROUTE} (selected; VPN not started or probed)
NOTE:       cluster $HOME is read-only; this project checkout and agent HOME live in /work
INFO

# Prove the image actually runs before anyone tries to attach to it, so a broken pull
# surfaces here, in the job log, instead of as a confusing failure at attach time.
if [[ -d "${WORK}/.ssh" && ! -e "${WORK}/agent-home/.ssh" ]]; then
    ln -s "${WORK}/.ssh" "${WORK}/agent-home/.ssh"
fi
declare -a CONTAINER_ARGS=(
    --nobanner
    --volume="${WORK}:${WORK}"
    --env="HOME=${WORK}/agent-home"
    --env="TERM=xterm-256color"
    --env="LIDO_AGENT_MODE=work-project"
    --env="SCI_AGENT_PROJECT=${PROJECT}"
    --env="LIDO_TUDO_ROUTE=${TUDO_ROUTE}"
    --workdir="${PROJECT}"
)
[[ -z "${CUDA_VISIBLE_DEVICES:-}" ]] || CONTAINER_ARGS+=(--env="CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}")
[[ -z "${NVIDIA_VISIBLE_DEVICES:-}" ]] || CONTAINER_ARGS+=(--env="NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES}")
if [[ -n "$GPU_TYPE" ]]; then
    CONTAINER_ARGS+=(--env="LIDO_AGENT_GPU=${GPU_TYPE}")
    [[ -d /usr/lib64 && -e /usr/lib64/libcuda.so.1 ]] || {
        echo 'GPU requested, but host CUDA driver libraries were not found in /usr/lib64' >&2
        exit 1
    }
    CONTAINER_ARGS+=(--volume=/usr/lib64:/opt/lido-nvidia)
    CONTAINER_ARGS+=(--env=LIDO_CUDA_HOST_LIBS=/opt/lido-nvidia)
fi
if [[ -n "$GPU_TYPE" ]]; then
    udocker run "${CONTAINER_ARGS[@]}" sci-agent bash -lc \
        'export LD_LIBRARY_PATH="${LIDO_CUDA_HOST_LIBS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; python3 -c '\''import ctypes; d=ctypes.CDLL("/opt/lido-nvidia/libcuda.so.1"); assert d.cuInit(0)==0; print("ready: CUDA driver initialized")'\''; echo "ready: node $(node -v), $(claude --version 2>&1 | head -1)"'
else
    udocker run "${CONTAINER_ARGS[@]}" sci-agent bash -lc \
        'echo "ready: node $(node -v), $(claude --version 2>&1 | head -1)"'
fi

tmp_ready="${READY_FILE}.tmp"
printf 'JOBID=%s\nNODE=%s\nGPU=%s\nTUDO_ROUTE=%s\nPROJECT=%s\nCUDA_VISIBLE_DEVICES=%s\nNVIDIA_VISIBLE_DEVICES=%s\n' \
    "$SLURM_JOB_ID" "$(hostname -s)" "${GPU_TYPE:-none}" "$TUDO_ROUTE" "$PROJECT" \
    "${CUDA_VISIBLE_DEVICES:-}" "${NVIDIA_VISIBLE_DEVICES:-}" >"$tmp_ready"
chmod 600 "$tmp_ready"
mv -f "$tmp_ready" "$READY_FILE"

# Hold the allocation. `--signal=B:TERM@60` plus the EXIT trap cleans up on scancel.
while true; do sleep 60; done
