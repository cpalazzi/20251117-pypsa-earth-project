#!/bin/bash
#SBATCH --job-name=pypsa-earth
#SBATCH --partition=long
#SBATCH --clusters=all
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=384G
#SBATCH --time=24:00:00
#SBATCH --mail-type=BEGIN,END
#SBATCH --mail-user=carlo.palazzi@eng.ox.ac.uk

set -euo pipefail

# Batch jobs on ARC do not automatically preload the environment-modules
# function, so source it manually if available before calling `module`.
if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "This script requires bash" >&2
  exit 2
fi
if ! command -v module >/dev/null 2>&1; then
  # Some ARC profile scripts reference MODULEPATH and other vars that may be
  # unset; temporarily disable nounset so sourcing them does not explode.
  set +u
  if [[ -f /etc/profile.d/modules.sh ]]; then
    # shellcheck disable=SC1091
    source /etc/profile.d/modules.sh
  elif [[ -f /usr/share/Modules/init/bash ]]; then
    # shellcheck disable=SC1091
    source /usr/share/Modules/init/bash
  fi
  set -u
fi

if [[ $# -lt 2 ]]; then
  echo "Usage: sbatch scripts/arc/jobs/arc_snakemake.sh <run-label> <configfile> [configfile ...]" >&2
  echo "Example: sbatch scripts/arc/jobs/arc_snakemake.sh 20251126-baseline config/default-single-timestep.yaml" >&2
  echo "         sbatch scripts/arc/jobs/arc_snakemake.sh 20251126-green config/default-single-timestep.yaml config/overrides/green-ammonia.yaml" >&2
  exit 2
fi

# Scenario name (used for log filenames). Recommend yyyyMMdd-tag style, e.g.
# 20251126-baseline or 20251126-europe-3h-green, so ARC logs stay ordered.
SCENARIO="$1"
shift

CONFIG_FILES=("$@")
CONFIG_ARGS=()
for cfg in "${CONFIG_FILES[@]}"; do
  CONFIG_ARGS+=("--configfile" "$cfg")
done

module restore 2>/dev/null || true
ANACONDA_MODULE=${ARC_ANACONDA_MODULE:-"Anaconda3/2023.09"}
module load "$ANACONDA_MODULE"

TOOLS_ENV=${ARC_CONDA_TOOLS:-"/data/engs-df-green-ammonia/engs2523/envs/conda-tools"}
PYPSA_ENV=${ARC_PYPSA_ENV:-"/data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-env"}

source activate "$TOOLS_ENV"
eval "$(micromamba shell hook --shell bash)"
micromamba activate "$PYPSA_ENV"

# Determine a sensible default working directory: prefer ARC_WORKDIR, then
# SLURM_SUBMIT_DIR (where sbatch was invoked), otherwise fall back to the
# repository root (three directories above this `scripts/arc/jobs/` folder).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WORKDIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKDIR=${ARC_WORKDIR:-${SLURM_SUBMIT_DIR:-$DEFAULT_WORKDIR}}
cd "$WORKDIR"
export PYTHONPATH="$WORKDIR:${PYTHONPATH:-}"
mkdir -p logs

# Central logfile for this run
LOGFILE="logs/snakemake-${SCENARIO}-$(date +%Y%m%d-%H%M%S).log"
echo "Snakemake log: $LOGFILE"

MEM_MB=${SLURM_MEM_PER_NODE:-256000}
CPUS=${SLURM_CPUS_PER_TASK:-16}
LATENCY_WAIT=${ARC_SNAKE_LATENCY_WAIT:-60}
EXTRA_ARGS=()
if [[ "${ARC_SNAKE_DRYRUN:-0}" == "1" ]]; then
  EXTRA_ARGS+=("-n")
fi

# Snakemake does not automatically forward custom env vars like PYTHONPATH into
# conda/job environments, so make sure we explicitly propagate the list.
ENV_VARS=("PYTHONPATH")
if [[ -n "${ARC_SNAKE_ENVVARS:-}" ]]; then
  # ARC_SNAKE_ENVVARS may contain a space-separated list, e.g. "PYTHONPATH FOO".
  read -r -a ENV_VARS <<<"${ARC_SNAKE_ENVVARS}"
fi

if [[ "${ARC_STAGE_DATA:-0}" == "1" ]]; then
  mapfile -t AVAILABLE_RULES < <(snakemake --list)
  stage_targets=()
  for rule in retrieve_databundle_light download_osm_data build_cutout; do
    if printf '%s\n' "${AVAILABLE_RULES[@]}" | grep -qx "$rule"; then
      stage_targets+=("$rule")
    fi
  done
  if [[ ${#stage_targets[@]} -gt 0 ]]; then
    if [[ " ${stage_targets[*]} " == *" retrieve_databundle_light "* ]]; then
      # Pipe "all" (plus final newline) so the databundle CLI auto-selects every bundle and exits cleanly.
      printf 'all\n\n' | snakemake --cores "$CPUS" "${stage_targets[@]}" \
        --resources mem_mb="$MEM_MB" --keep-going --rerun-incomplete \
        --latency-wait "$LATENCY_WAIT"
    else
      snakemake --cores "$CPUS" "${stage_targets[@]}" \
        --resources mem_mb="$MEM_MB" --keep-going --rerun-incomplete \
        --latency-wait "$LATENCY_WAIT"
    fi
  fi
fi

run_snakemake() {
  snakemake \
    "$@" \
    "${EXTRA_ARGS[@]}" \
    -j "${CPUS}" \
    --resources mem_mb="${MEM_MB}" \
    --envvars "${ENV_VARS[@]}" \
    --latency-wait "${LATENCY_WAIT}" \
    --keep-going --rerun-incomplete --printshellcmds \
    --stats "logs/snakemake-${SCENARIO}.stats.json" 2>&1 | tee -a "$LOGFILE"
}

run_snakemake solve_all_networks "${CONFIG_ARGS[@]}"
