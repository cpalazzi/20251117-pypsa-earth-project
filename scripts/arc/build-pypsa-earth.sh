#! /bin/bash
#SBATCH --job-name=build-pypsa-earth
#SBATCH --chdir='/data/engs-df-green-ammonia/engs2523'
#SBATCH --nodes=1
#SBATCH --cpus-per-task=8
#SBATCH --partition=short,medium
#SBATCH --time=02:00:00
#SBATCH --clusters=all
#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --mail-user=carlo.palazzi@eng.ox.ac.uk

set -euo pipefail

module purge
module load Anaconda3/2023.09

WORKDIR=/data/engs-df-green-ammonia/engs2523/pypsa-earth
CONPREFIX=/data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-2025-11
LOGDIR=/data/engs-df-green-ammonia/engs2523/envs/logs
mkdir -p "$(dirname "$CONPREFIX")" "$LOGDIR"

conda env remove --prefix "$CONPREFIX" -y || true
conda env create --prefix "$CONPREFIX" --file "$WORKDIR/envs/environment.yaml"

source activate "$CONPREFIX"
export CONDA_ALWAYS_YES=true

pip install --upgrade pip
pip install -U snakemake snakemake-executor-plugin-slurm linopy

unset CONDA_ALWAYS_YES

conda list --explicit > "$LOGDIR/pypsa-earth-2025-11-conda.txt"
pip freeze > "$LOGDIR/pypsa-earth-2025-11-pip.txt"

echo "Environment created at $CONPREFIX"
