#!/usr/bin/env bash
# Pull an image into the LiDO3 udocker store and PROVE it is the pinned one.
#
#   udocker_pull.sh <repo> <sha256:manifest-digest> [local-name] [tag]
#
# e.g. udocker_pull.sh ghcr.io/e-kotov/sci-r-geo sha256:9ce8... sci-r-geo latest
#
# ---------------------------------------------------------------------------------
# WHY THIS IS NOT JUST `udocker pull repo@digest`
#
# udocker 1.3.17 CANNOT pull a digest reference. Verified on gw01, 2026-08-28:
#
#     $ udocker pull ghcr.io/e-kotov/sci-agent@sha256:bc7edec6...
#     Error: must specify image:tag or repository/image:tag
#
# `udocker pull --help` confirms it: the grammar is `pull [options] <repo/image:tag>`,
# with `--platform` but no digest form. Apptainer takes `docker://repo@sha256:...`
# happily, so the two lanes cannot pin the same way.
#
# Pulling the tag and hoping is not acceptable — a tag is mutable, and an analysis that
# cannot name its runtime is not reproducible (Decision 0024). So the pin is enforced
# AFTER the fact instead of during:
#
#   1. Ask the registry what CONFIG digest the pinned manifest declares.
#   2. Pull the tag with --platform=linux/amd64.
#   3. Read the config digest out of the manifest udocker stored.
#   4. Equal -> this is the pinned image. Different -> delete it and fail.
#
# Hashing udocker's stored manifest file directly does NOT work: udocker re-serializes
# the JSON, so its bytes differ from the registry's canonical bytes and its sha256 is
# not the manifest digest (measured: ef1bd4f3… stored vs bc7edec6… registry). The
# config digest inside it is content-addressed by the registry and commits to every
# rootfs layer, so comparing it is a real check, not a proxy for one.
#
# LiDO3 compute nodes have outbound internet (ghcr.io reachable from cstd01-001), so
# step 1 works inside a job as well as on a gateway.
# ---------------------------------------------------------------------------------
set -euo pipefail

WORK="${WORK:-/work/${USER}}"
export UDOCKER_DIR="${UDOCKER_DIR:-${WORK}/.udocker}"
export PATH="${UDOCKER_PREFIX:-${WORK}/.local}/bin:$PATH"

REPO="${1:-}"
DIGEST="${2:-}"
LOCAL_NAME="${3:-}"
TAG="${4:-latest}"
PLATFORM="${UDOCKER_PLATFORM:-linux/amd64}"

usage() { echo "usage: udocker_pull.sh <repo> <sha256:manifest-digest> [local-name] [tag]" >&2; exit 2; }
[ -n "$REPO" ] && [ -n "$DIGEST" ] || usage
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "udocker_pull: second argument must be a full sha256: digest, got '$DIGEST'" >&2; usage; }
[ -n "$LOCAL_NAME" ] || LOCAL_NAME="$(basename "$REPO")"

command -v udocker >/dev/null 2>&1 || {
  echo "udocker_pull: udocker not on PATH — run slurm/lido3/udocker_bootstrap.sh first." >&2
  exit 69
}
mkdir -p "$UDOCKER_DIR"

# Already built and verified? `udocker create` is the expensive step (it unpacks every
# layer), so do not repeat it.
if udocker ps 2>/dev/null | grep -q "[[:space:]]${LOCAL_NAME}\$"; then
  echo "container already present: ${LOCAL_NAME}"
  exit 0
fi

expected_config="$(python3 - "$REPO" "$DIGEST" <<'PY'
# Ask the registry for the CONFIG digest declared by the pinned manifest.
# stdlib only: LiDO3 gateways ship Python 3.6 and no third-party packages.
import json, sys, urllib.request, urllib.error

repo_ref, digest = sys.argv[1], sys.argv[2]
host, _, path = repo_ref.partition("/")
if "." not in host and ":" not in host:          # bare name -> Docker Hub
    host, path = "registry-1.docker.io", ("library/" + repo_ref if "/" not in repo_ref else repo_ref)

ACCEPT = ",".join([
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
])

def token():
    if host == "ghcr.io":
        url = "https://ghcr.io/token?scope=repository:%s:pull" % path
    else:
        url = ("https://auth.docker.io/token?service=registry.docker.io"
               "&scope=repository:%s:pull" % path)
    return json.load(urllib.request.urlopen(url, timeout=30))["token"]

try:
    req = urllib.request.Request(
        "https://%s/v2/%s/manifests/%s" % (host, path, digest),
        headers={"Authorization": "Bearer " + token(), "Accept": ACCEPT})
    manifest = json.load(urllib.request.urlopen(req, timeout=60))
except urllib.error.HTTPError as exc:
    sys.exit("udocker_pull: registry rejected the pinned digest (HTTP %s). "
             "Is %s@%s published?" % (exc.code, repo_ref, digest))

if "config" not in manifest:
    sys.exit("udocker_pull: %s@%s is a multi-arch INDEX, not a platform manifest. "
             "Pin the linux/amd64 child digest instead." % (repo_ref, digest))
print(manifest["config"]["digest"])
PY
)"

echo "-- pinned ${REPO}@${DIGEST}"
echo "   declares config ${expected_config}"
echo "-- pulling ${REPO}:${TAG} (${PLATFORM})"
udocker pull --platform="$PLATFORM" "${REPO}:${TAG}"

stored_manifest="${UDOCKER_DIR}/repos/${REPO}/${TAG}/manifest"
[ -r "$stored_manifest" ] || {
  echo "udocker_pull: udocker stored no manifest at $stored_manifest" >&2; exit 1; }

actual_config="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"]["digest"])' "$stored_manifest")"

if [ "$actual_config" != "$expected_config" ]; then
  echo "udocker_pull: REFUSING — ${REPO}:${TAG} is not the pinned image." >&2
  echo "  pinned config : $expected_config" >&2
  echo "  pulled config : $actual_config" >&2
  echo "  The tag has moved past the pinned digest. Pass the immutable tag that" >&2
  echo "  carries it — every CI build publishes sha-<commit> alongside latest:" >&2
  echo "      udocker_pull.sh $REPO $DIGEST $LOCAL_NAME sha-<commit>" >&2
  udocker rmi "${REPO}:${TAG}" >/dev/null 2>&1 || true
  exit 1
fi
echo "   verified: pulled image matches the pinned digest"

udocker create --name="${LOCAL_NAME}" "${REPO}:${TAG}"
echo "-- ready: udocker run --execmode=F3 ${LOCAL_NAME} ..."
