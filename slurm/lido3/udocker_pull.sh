#!/usr/bin/env bash
# Pull a digest-pinned image into the LiDO3 udocker store.
#
#   udocker_pull.sh ghcr.io/e-kotov/sci-r-geo sha256:<64hex> [local-name]
#
# The digest is mandatory and is the SAME digest the GWDG Apptainer lane pins, so
# the two clusters demonstrably run one image. A tag is not accepted: a tag is
# mutable, and an analysis that cannot name its runtime is not reproducible.
#
# Safe to run on a gateway (image lands in /work, shared with the compute nodes)
# or inside a job — LiDO3 compute nodes have outbound internet, verified against
# ghcr.io from cstd01-001.
set -euo pipefail

WORK="${WORK:-/work/${USER}}"
export UDOCKER_DIR="${UDOCKER_DIR:-${WORK}/.udocker}"
export PATH="${UDOCKER_PREFIX:-${WORK}/.local}/bin:$PATH"

REPO="${1:-}"
DIGEST="${2:-}"
LOCAL_NAME="${3:-}"

usage() { echo "usage: udocker_pull.sh <repo> <sha256:digest> [local-name]" >&2; exit 2; }
[ -n "$REPO" ] && [ -n "$DIGEST" ] || usage
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "udocker_pull: second argument must be a full sha256: digest, got '$DIGEST'" >&2
  usage
}
[ -n "$LOCAL_NAME" ] || LOCAL_NAME="$(basename "$REPO")"

command -v udocker >/dev/null 2>&1 || {
  echo "udocker_pull: udocker not on PATH — run slurm/lido3/udocker_bootstrap.sh first." >&2
  exit 69
}

mkdir -p "$UDOCKER_DIR"

if udocker images 2>/dev/null | awk '{print $1}' | grep -qx "${LOCAL_NAME}:pinned"; then
  echo "already present: ${LOCAL_NAME}:pinned"
else
  echo "-- pulling ${REPO}@${DIGEST}"
  # udocker resolves a digest reference against the registry directly. If this
  # errors, do NOT paper over it by pulling the tag: that would silently swap the
  # pinned image for whatever :latest happens to be today.
  udocker pull "${REPO}@${DIGEST}"
  udocker tag "${REPO}@${DIGEST}" "${LOCAL_NAME}:pinned"
fi

# Create the container filesystem once; `udocker run` then costs no unpack.
if udocker ps 2>/dev/null | grep -q "[[:space:]]${LOCAL_NAME}\$"; then
  echo "container already created: ${LOCAL_NAME}"
else
  udocker create --name="${LOCAL_NAME}" "${LOCAL_NAME}:pinned"
fi

echo "-- ready: udocker run --execmode=F3 ${LOCAL_NAME} ..."
