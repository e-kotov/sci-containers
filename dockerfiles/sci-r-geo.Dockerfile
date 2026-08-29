# sci-r-geo — R + geospatial stack for HPC batch work.
#
# Base: rocker/geospatial, which already carries GDAL/GEOS/PROJ, sf, terra, stars
# and the tidyverse compiled against them. Rebuilding that stack from r-ver would
# cost an hour of CI per push and buy nothing.
#
# PLATFORM: linux/amd64 + linux/arm64. rocker/geospatial publishes both from the 4.6
# line onward (4.5.x was amd64-only; verified against the registry 2026-08-29).
FROM rocker/geospatial:4.6.1

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
