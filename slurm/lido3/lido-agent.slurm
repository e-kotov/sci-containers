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

"$(dirname "$0")/udocker_pull.sh" "$REPO" "$DIGEST" sci-agent
udocker setup --execmode="${UDOCKER_EXECMODE:-F3}" sci-agent

# Report where to attach, into the job log, before blocking.
cat <<INFO
Node:    $(hostname -s)
Session: ${SESSION}
Socket:  ${SOCK}
Job:     ${SLURM_JOB_ID}
Attach:  lido-agent-remote attach ${SLURM_JOB_ID}
INFO

# --- Why tmux runs INSIDE the container ---------------------------------------------
# The obvious design puts tmux on the host and the container in a tmux window. That does
# not work here: LiDO3 compute nodes have NO tmux (`bash: tmux: command not found` on
# cstd01-001, 2026-08-28) — it exists only on the gateways. The sci-agent image does ship
# tmux, so the session host is the container's tmux, with its socket on /work so a second
# udocker invocation (the attach) can reach the same server.
#
# And this udocker wrapper stays in the FOREGROUND for the whole job rather than
# detaching. Under P1 the engine is PRoot, which traces its children: if the launching
# wrapper exited, the tmux server it started would be torn down with the tracer. Holding
# the wrapper open makes the session survive in every execmode, not just the F ones.
exec udocker run --nobanner \
    --env=HOME="${WORK}/agent-home" \
    --env=TMPDIR="$SCRATCH_DIR" \
    --env=TERM=xterm-256color \
    --env=SLURM_JOB_ID="${SLURM_JOB_ID}" \
    --env=LIDO_AGENT_MODE=compute-readonly-home \
    --volume="${WORK}:${WORK}" \
    --volume="${SCRATCH_DIR}:${SCRATCH_DIR}" \
    --workdir="${WORK}" \
    sci-agent bash -lc '
      set -e
      tmux -S "'"$SOCK"'" new-session -d -s "'"$SESSION"'" -c "'"$WORK"'"
      # Hold the allocation while the session lives; exit early once it is closed.
      while tmux -S "'"$SOCK"'" has-session -t "'"$SESSION"'" 2>/dev/null; do sleep 30; done
    '
