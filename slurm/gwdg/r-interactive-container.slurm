#!/bin/bash -l
#SBATCH --job-name=sci-r-geo
#SBATCH --partition=standard
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err
#
# GWDG counterpart of slurm/lido3/r-interactive-container.slurm: same image, same
# digest, Apptainer instead of udocker because GWDG permits user namespaces.
#
# Submit with:
#   sbatch --export=ALL,SCI_R_GEO_SIF=/path/to.sif slurm/gwdg/r-interactive-container.slurm

set -euo pipefail

SIF="${SCI_R_GEO_SIF:-}"
[ -n "$SIF" ] && [ -r "$SIF" ] || { echo "set SCI_R_GEO_SIF to a readable SIF" >&2; exit 2; }

module purge
module load apptainer/1.4.3

export APPTAINERENV_OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
export APPTAINERENV_NCPUS="${SLURM_CPUS_PER_TASK:-1}"

exec apptainer exec --cleanenv --no-home \
  --bind "$PWD:$PWD" \
  --pwd "$PWD" \
  "$SIF" "$@"
