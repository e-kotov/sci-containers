# sci-containers

Container image definitions and cluster run scripts for scientific computing on
HPC. Images are topical, never project-named; nothing here identifies a research
project.

Two clusters, one image per purpose, pinned by digest so both run demonstrably
the same thing:

| Image | `ghcr.io/e-kotov/…` | Platforms | What it is for |
|---|---|---|---|
| `sci-r-geo` | `sci-r-geo` | `linux/amd64`, `linux/arm64` | R 4.6.1 + GDAL/GEOS/PROJ + sf/terra/stars + tidyverse + renv |
| `sci-agent` | `sci-agent` | `linux/amd64`, `linux/arm64` | Node 22 + Claude Code + git/tmux/ripgrep |

Both images are multi-arch. `rocker/geospatial` gained `linux/arm64` in the 4.6 line;
4.5.x was amd64-only.

## Why `sci-agent` exists at all

TU Dortmund LiDO3 runs RHEL 7.9 with **glibc 2.17**. Node 18+ needs glibc 2.28.
No Node binary runs natively there, so the agent has to be containerised.

## Two runtimes, because two clusters disagree about user namespaces

| | GWDG SCC | TU Dortmund LiDO3 |
|---|---|---|
| `max_user_namespaces` | non-zero | **0**, cluster-wide, kernel 3.10 |
| `newuidmap` setuid | — | **not setuid** |
| Runtime | Apptainer 1.4.3 (`module load`) | **udocker** (userspace, no privilege) |
| Engines | — | P1 (PRoot/ptrace), F1–F4 (Fakechroot/LD_PRELOAD). R1–R3 and S1 need namespaces: dead. |

Nothing a user can do changes the LiDO3 side. Both lanes pull the same digest.

## LiDO3 quick start

```bash
# once per account, ON A GATEWAY (gw01/gw02)
slurm/lido3/udocker_bootstrap.sh

# any time; compute nodes have outbound internet, so this also works inside a job
slurm/lido3/udocker_pull.sh ghcr.io/e-kotov/sci-r-geo sha256:<amd64-manifest-digest>

# batch
mkdir -p /work/$USER/logs        # slurmd opens --output BEFORE the script runs
sbatch --export=ALL,SCI_R_GEO_DIGEST=sha256:<digest> \
       slurm/lido3/r-interactive-container.slurm R --version
```

### Two variables that are not optional

```bash
export UDOCKER_DIR="/work/$USER/.udocker"      # default ~/.udocker is READ-ONLY on compute
export PATH="/work/$USER/.local/bin:$PATH"     # udocker itself lives in /work
```

`$HOME` on LiDO3 is 32 GiB, tape-backed, and **read-only on compute nodes**. Every
write path — the udocker store, the image layers, caches, `$HOME` inside the
container — must resolve into `/work`. `/work` has **no backup**; copy anything you
care about off-cluster.

### How the digest pin survives udocker

**udocker 1.3.17 cannot pull a digest reference.** Its grammar is
`pull [options] <repo/image:tag>`; `repo@sha256:…` fails with
`Error: must specify image:tag or repository/image:tag` (verified on gw01, 2026-08-28).
Apptainer accepts `docker://repo@sha256:…`, so the two lanes cannot pin identically.

`udocker_pull.sh` therefore enforces the pin *after* the pull instead of during it:

1. ask the registry which **config digest** the pinned manifest declares;
2. `udocker pull --platform=linux/amd64 repo:tag`;
3. read the config digest out of the manifest udocker stored;
4. equal → this is the pinned image; different → delete it and fail.

Hashing udocker's stored manifest file would not work — udocker re-serializes the JSON,
so its bytes are not the registry's canonical bytes. The config digest inside it is
content-addressed by the registry and commits to every rootfs layer, so comparing it is
a real check rather than a proxy for one.

If `latest` has moved past your pinned digest the script refuses and tells you to pass
the immutable tag instead. Every CI build publishes `sha-<commit>` alongside `latest`:

```bash
slurm/lido3/udocker_pull.sh ghcr.io/e-kotov/sci-r-geo sha256:<digest> sci-r-geo sha-<commit>
```

### Execmode

`F3` (Fakechroot, LD_PRELOAD) is the default: no ptrace, far cheaper than the PRoot modes
for I/O- and syscall-heavy work. Both images are glibc, so F modes apply.

**The fallback is image-specific — do not assume `P1`.** Measured 2026-08-29:

| image | base | F3 | P1 | P2 |
|---|---|---|---|---|
| `sci-agent` | Debian 12 | works | works | — |
| `sci-r-geo` | Ubuntu 24.04 | works | **fails** (not even `/bin/echo` runs) | works |

So `sci-r-geo`'s fallback is **`P2`**, i.e. PRoot without seccomp acceleration. `P1`'s
seccomp path does not survive this image on the 3.10 kernel.

Cost, measured on a compute node (400 small RDS round-trips + a 700×700 matrix multiply,
against the site's native `R/4.4.2` module):

| runtime | `io_sec` | `cpu_sec` | one-time `setup` |
|---|---|---|---|
| F3 | 0.31–0.32 | 0.03–0.04 | 219.7 s |
| P2 | 0.52 | 0.15 | 150.4 s |
| native module | 0.30 | 0.05 | — |

F3 is within ~7 % of native on I/O. PRoot is ~1.7× worse — use F3 unless it fails.

**Set the execmode once, at pull time — never per run.** `udocker setup --execmode=` is
not a runtime flag: the F modes patch the ELF interpreter of *every binary in the
unpacked rootfs*, and switching modes un-patches them again. On a multi-GB image on
BeeGFS that is minutes of small-file I/O, and doing it inside each job also races when
two jobs share a container. `udocker_pull.sh` does it once at create time; the launchers
deliberately do not.

```bash
UDOCKER_EXECMODE=P1 slurm/lido3/udocker_pull.sh ghcr.io/e-kotov/sci-r-geo sha256:<digest>
```

## GWDG quick start

```bash
slurm/gwdg/apptainer_pull.sh ~/containers/sci-r-geo.sif \
    ghcr.io/e-kotov/sci-r-geo sha256:<same digest>
sbatch --export=ALL,SCI_R_GEO_SIF=$HOME/containers/sci-r-geo.sif \
       slurm/gwdg/r-interactive-container.slurm R --version
```

## Agent workstation on LiDO3 (`slurm/lido3/lido-agent.slurm`)

A 36 h `long` allocation holding a host-side tmux session whose window runs
`sci-agent` under udocker. Attach with plain SSH from a gateway into your own
allocated node — LiDO3 permits that, so there is no sshd inside the container.

**`$HOME` is read-only inside this job.** Compute only: no `git commit`, no memory
writes. Those happen on a gateway or off-cluster.

## Publishing

GitHub Actions builds on push to `main` when the matching Dockerfile changes, and on
`workflow_dispatch`. Push uses `secrets.GITHUB_TOKEN`, so no PAT and no
`write:packages` scope on a personal token are needed. Each run prints the immutable
digest in its job summary — that digest is what the cluster scripts take.

## Relation to `e-kotov/datasci_containers`

That repo is the working precedent for the publish workflow (ghcr.io, multi-arch by
digest with a merge job) and stays exactly as it is. This repo is separate because it
carries cluster run scripts as well as images, and is built to be public from the
first commit.
