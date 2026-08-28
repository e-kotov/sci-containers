#!/bin/bash -l
#SBATCH --job-name=sci-r-geo
#SBATCH --partition=med
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --constraint=cstd01
#SBATCH --output=/work/%u/logs/%x-%j.out
#SBATCH --error=/work/%u/logs/%x-%j.err
#
# Run R from the digest-pinned sci-r-geo image on a LiDO3 compute node.
#
# /work/$USER/logs MUST exist before submission — slurmd opens --output before this
# script runs, and a missing directory fails the job with no log to explain why.
#
# Submit with the digest exported:
#   sbatch --export=ALL,SCI_R_GEO_DIGEST=sha256:... slurm/lido3/r-interactive-container.slurm

set -euo pipefail

WORK="${WORK:-/work/${USER}}"
REPO="${SCI_R_GEO_REPO:-ghcr.io/e-kotov/sci-r-geo}"
DIGEST="${SCI_R_GEO_DIGEST:-}"
[ -n "$DIGEST" ] || { echo "set SCI_R_GEO_DIGEST=sha256:..." >&2; exit 2; }

export UDOCKER_DIR="${UDOCKER_DIR:-${WORK}/.udocker}"
export PATH="${UDOCKER_PREFIX:-${WORK}/.local}/bin:$PATH"

# Node-local scratch: a real 1.8 TB disk on compute (/dev/sda3). /tmp is only 40 GB
# and BeeGFS must not absorb temp churn.
SCRATCH_DIR="/scratch/${USER}/${SLURM_JOB_ID}"
mkdir -p "$SCRATCH_DIR"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

"$(dirname "$0")/udocker_pull.sh" "$REPO" "$DIGEST" sci-r-geo

# Execmode: F3 (Fakechroot, LD_PRELOAD) is far cheaper than P1 (PRoot, ptrace) for
# I/O- and syscall-heavy work. F modes need a glibc image — this one is Debian, so
# they should apply; P1 remains correct everywhere and is the documented fallback.
EXECMODE="${UDOCKER_EXECMODE:-F3}"
udocker setup --execmode="$EXECMODE" sci-r-geo

# NOTE: no --rm. In udocker, `run --rm <name>` DELETES the named container created by
# `udocker create`, not just the run — the next job then finds nothing and tries to pull
# "sci-agent" from Docker Hub ("manifest not found"). Verified on cstd01-001, 2026-08-28.
exec udocker run \
  --env=HOME="${WORK}" \
  --env=TMPDIR="$SCRATCH_DIR" \
  --env=R_LIBS_USER="${WORK}/R/%V" \
  --env=RENV_PATHS_CACHE="${WORK}/.cache/renv" \
  --env=OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}" \
  --env=NCPUS="${SLURM_CPUS_PER_TASK:-1}" \
  --volume="${WORK}:${WORK}" \
  --volume="${SCRATCH_DIR}:${SCRATCH_DIR}" \
  --workdir="${WORK}" \
  sci-r-geo "$@"
