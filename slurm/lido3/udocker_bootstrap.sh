#!/usr/bin/env bash
# Install udocker into /work on TU Dortmund LiDO3, once per account.
#
# Run this ON A GATEWAY (gw01/gw02). $HOME is read-only on compute nodes, so an
# install that lands anywhere under $HOME is an install that cannot be repaired,
# updated, or even completed from inside a job.
#
# Why udocker and not Apptainer: /proc/sys/user/max_user_namespaces is 0 on every
# LiDO3 node and newuidmap/newgidmap carry no setuid bit, so rootless Apptainer
# cannot work and a setuid install needs an admin. udocker needs no privilege at
# all — it unpacks OCI layers into a plain directory tree and enters them with
# PRoot (ptrace) or Fakechroot (LD_PRELOAD).
set -euo pipefail

WORK="${WORK:-/work/${USER}}"
export UDOCKER_DIR="${UDOCKER_DIR:-${WORK}/.udocker}"
PREFIX="${UDOCKER_PREFIX:-${WORK}/.local}"

case "$(hostname -s)" in
  gw01|gw02) ;;
  *)
    echo "udocker_bootstrap: refusing to run outside a LiDO3 gateway." >&2
    echo "  \$HOME is read-only on compute nodes; bootstrap there cannot be undone." >&2
    exit 1
    ;;
esac

[ -d "$WORK" ] || { echo "udocker_bootstrap: no such directory: $WORK" >&2; exit 1; }

mkdir -p "$UDOCKER_DIR" "$PREFIX"

# pip --user honours PYTHONUSERBASE. Without this it writes to ~/.local, which on a
# stock LiDO3 account does not exist and, once created, sits on the read-only-on-
# compute home. See the account-setup section of the README.
export PYTHONUSERBASE="$PREFIX"
export PATH="$PREFIX/bin:$PATH"

if command -v udocker >/dev/null 2>&1; then
  echo "udocker already on PATH: $(command -v udocker)  ($(udocker --version 2>/dev/null | head -1))"
else
  echo "-- installing udocker into $PREFIX"
  python3 -m pip install --user --upgrade udocker
fi

command -v udocker >/dev/null 2>&1 || {
  echo "udocker_bootstrap: udocker is still not on PATH after install." >&2
  echo "  Expected it at $PREFIX/bin/udocker" >&2
  exit 1
}

# Fetches PRoot/Fakechroot/runc engine binaries into $UDOCKER_DIR. Idempotent.
udocker install

cat <<SHELL

udocker is installed.

Add to your shell profile (or source config/hpc-env.sh from a project, which
exports the same two variables):

    export UDOCKER_DIR="$UDOCKER_DIR"
    export PATH="$PREFIX/bin:\$PATH"

Both MUST be set inside every job: udocker defaults UDOCKER_DIR to ~/.udocker,
which is read-only on compute nodes and fails with a bare permission error.
SHELL
