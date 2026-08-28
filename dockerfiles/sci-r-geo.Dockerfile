# sci-r-geo — R + geospatial stack for HPC batch work.
#
# Base: rocker/geospatial, which already carries GDAL/GEOS/PROJ, sf, terra, stars
# and the tidyverse compiled against them. Rebuilding that stack from r-ver would
# cost an hour of CI per push and buy nothing.
#
# PLATFORM: linux/amd64 ONLY, and this is not a preference.
#   rocker/geospatial publishes no linux/arm64 manifest (verified 2026-08-28 against
#   registry-1.docker.io for 4.5.0/4.5.1/4.5.2 — each index lists amd64 and the
#   attestation blob, nothing else). Both target clusters are amd64, so the matrix
#   would only ever have produced a failing arm64 leg.
FROM rocker/geospatial:4.5.2

# Cluster-side needs the rocker image does not ship:
#   - tmux/less/procps: interactive attach and self-inspection inside udocker
#   - openssh-client:   git over SSH from a compute node (LiDO3 has outbound internet)
#   - unzip/zip:        GTFS and other zipped inputs
RUN apt-get update && apt-get install -y --no-install-recommends \
        tmux less procps openssh-client unzip zip rsync \
    && rm -rf /var/lib/apt/lists/*

# renv is the project-library manager on both clusters; installing it here means a
# fresh project does not pay a bootstrap compile before it can restore.
RUN install2.r --error --skipinstalled renv

# udocker's PRoot/Fakechroot engines do not run an init, and P1 in particular is
# sensitive to entrypoint scripts that expect a TTY. Keep the entrypoint trivial.
ENTRYPOINT []
CMD ["R", "--version"]
