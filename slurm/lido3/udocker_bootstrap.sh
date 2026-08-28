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
#
# WHY A VENV, NOT `pip install --user`:
#   `pip install --user` with PYTHONUSERBASE pointed at /work puts the package in
#   $PREFIX/lib/pythonX.Y/site-packages, which Python only searches when
#   PYTHONUSERBASE is ALSO set at run time. Every later shell that had PATH but not
#   PYTHONUSERBASE got `ModuleNotFoundError: No module named 'udocker'` from udocker's
#   own launcher — observed on gw01, 2026-08-28. Worse, config/hpc-env.sh legitimately
#   points PYTHONUSERBASE at the project cache, which would shadow the install.
#   A venv's launcher shebang names its own interpreter, so PATH alone is sufficient
#   and nothing can shadow it.
set -euo pipefail

WORK="${WORK:-/work/${USER}}"
export UDOCKER_DIR="${UDOCKER_DIR:-${WORK}/.udocker}"
PREFIX="${UDOCKER_PREFIX:-${WORK}/.local}"
VENV="${PREFIX}/venvs/udocker"

case "$(hostname -s)" in
  gw01|gw02) ;;
  *)
    echo "udocker_bootstrap: refusing to run outside a LiDO3 gateway." >&2
    echo "  \$HOME is read-only on compute nodes; bootstrap there cannot be undone." >&2
    exit 1
    ;;
esac

[ -d "$WORK" ] || { echo "udocker_bootstrap: no such directory: $WORK" >&2; exit 1; }

mkdir -p "$UDOCKER_DIR" "$PREFIX/bin" "$(dirname "$VENV")"

if [ ! -x "$VENV/bin/udocker" ]; then
  echo "-- creating venv at $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/python" -m pip install --quiet --upgrade pip
  "$VENV/bin/python" -m pip install --quiet --upgrade udocker
fi

ln -sfn "$VENV/bin/udocker" "$PREFIX/bin/udocker"
export PATH="$PREFIX/bin:$PATH"

command -v udocker >/dev/null 2>&1 || {
  echo "udocker_bootstrap: udocker is still not on PATH after install." >&2
  echo "  Expected it at $PREFIX/bin/udocker" >&2
  exit 1
}

# Prove it can import itself with NOTHING but PATH set — the exact failure this
# venv layout exists to prevent. `env -i` strips PYTHONUSERBASE and everything else.
env -i PATH="$PREFIX/bin:/usr/bin:/bin" HOME="$WORK" UDOCKER_DIR="$UDOCKER_DIR" \
  udocker --version >/dev/null 2>&1 || {
  echo "udocker_bootstrap: udocker cannot run with PATH alone; the install is not self-contained." >&2
  exit 1
}

# Fetches PRoot/Fakechroot/runc engine binaries into $UDOCKER_DIR. Idempotent.
udocker install

cat <<SHELL

udocker $(udocker --version 2>/dev/null | head -1) is installed and self-contained.

Add to your shell profile (or source config/hpc-env.sh from a project, which
exports the same two variables):

    export UDOCKER_DIR="$UDOCKER_DIR"
    export PATH="$PREFIX/bin:\$PATH"

UDOCKER_DIR MUST be set inside every job: udocker defaults it to ~/.udocker,
which is read-only on compute nodes and fails with a bare permission error.
SHELL
