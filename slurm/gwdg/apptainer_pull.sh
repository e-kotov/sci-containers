#!/usr/bin/env bash
# Pull the SAME digest as the LiDO3 udocker lane into a SIF, on GWDG.
#
#   apptainer_pull.sh <sif-path> ghcr.io/e-kotov/sci-r-geo sha256:<64hex>
#
# Digest-pinned, for the reason in Decision 0024 (digest-pinned container-only R):
# a tag is mutable and an analysis that cannot name its runtime is not reproducible.
set -euo pipefail

SIF="${1:-}"; REPO="${2:-}"; DIGEST="${3:-}"
[ -n "$SIF" ] && [ -n "$REPO" ] && [ -n "$DIGEST" ] || {
  echo "usage: apptainer_pull.sh <sif-path> <repo> <sha256:digest>" >&2; exit 2; }
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "not a sha256 digest: $DIGEST" >&2; exit 2; }

module purge
module load apptainer/1.4.3

mkdir -p "$(dirname "$SIF")"
apptainer pull "$SIF" "docker://${REPO}@${DIGEST}"
sha256sum "$SIF"
