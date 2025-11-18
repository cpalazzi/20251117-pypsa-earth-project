#!/bin/bash
#SBATCH --job-name=pypsa-earth
#SBATCH --partition=standard
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=48G
#SBATCH --time=08:00:00
#SBATCH --output=logs/%x-%j.out
#SBATCH --error=logs/%x-%j.err

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: sbatch jobs/arc_snakemake.sh <baseline|green-ammonia>" >&2
  exit 2
fi

module restore 2>/dev/null || true
ANACONDA_MODULE=${ARC_ANACONDA_MODULE:-"Anaconda3/2023.09"}
module load "$ANACONDA_MODULE"
source ~/.bashrc 2>/dev/null || true
conda activate pypsa-earth

WORKDIR=${ARC_WORKDIR:-"$SLURM_SUBMIT_DIR/pypsa-earth"}
cd "$WORKDIR"
mkdir -p logs

MEM_MB=${SLURM_MEM_PER_NODE:-48000}
CPUS=${SLURM_CPUS_PER_TASK:-16}

case "$1" in
  baseline)
    snakemake -call solve_elec_networks \
      --configfile config/default-single-timestep.yaml \
      -j "${CPUS}" \
      --resources mem_mb="${MEM_MB}" \
      --keep-going --rerun-incomplete
    ;;
  green-ammonia)
    snakemake -call solve_elec_networks \
      --configfile config/default-single-timestep.yaml \
      --configfile config/overrides/green-ammonia.yaml \
      -j "${CPUS}" \
      --resources mem_mb="${MEM_MB}" \
      --keep-going --rerun-incomplete
    ;;
  *)
    echo "Unknown scenario '$1'" >&2
    exit 3
    ;;
esac
