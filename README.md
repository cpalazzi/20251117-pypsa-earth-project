# PyPSA-Earth ARC Runner

Run PyPSA-Earth simulations on Oxford Advanced Research Computing (ARC) with test configurations for clean electricity scenarios.

**Scope**: 17-country Europe (AT, BG, CZ, DE, DK, ES, FR, GB, GR, HU, IT, PL, PT, RO, RS, SE) | 70 clusters | Single day | Electricity-only or green ammonia

## Quick Start

### Prerequisites

1. **PyPSA-Earth fork** (with built-in fixes):
   ```bash
   git clone https://github.com/cpalazzi/pypsa-earth.git
   cd pypsa-earth
   git remote add upstream https://github.com/pypsa-meets-earth/pypsa-earth.git
   ```

2. **This repo** (synced into PyPSA-Earth):
   ```bash
   git clone https://github.com/cpalazzi/pypsa-earth-runtools-crow.git
   # Copy configs and scripts into PyPSA-Earth
   rsync -av pypsa-earth-runtools-crow/config/ config/
   rsync -av pypsa-earth-runtools-crow/scripts/extra/ scripts/extra/
   rsync -av pypsa-earth-runtools-crow/scripts/arc/jobs/ jobs/
   ```

### Run a Job on ARC

```bash
# Log into ARC
ssh engs2523@arc-login.arc.ox.ac.uk
cd /data/engs-df-green-ammonia/engs2523/pypsa-earth

# Submit job
sbatch --clusters=arc --parsable \
  ../pypsa-earth-runtools-crow/scripts/arc/jobs/arc_snakemake.sh \
  20260127-europe-day-70n-core \
  ../pypsa-earth-runtools-crow/config/base-europe17-70n-day.yaml \
  ../pypsa-earth-runtools-crow/config/scenarios/scenario-core-electricity.yaml

# Monitor
squeue -u engs2523
tail -f slurm-<jobid>.out
```

**Expected runtime**: 6-8 hours | **Output**: `results/europe-day-core-tech-elec/networks/elec_s_70_ec_lcopt_Co2L-3h.nc`

## Configurations

| Config | Countries | Clusters | Time | Tech | Purpose |
|--------|-----------|----------|------|------|---------|
| `base-europe17-70n-day.yaml` | 17 | 70 | 1 day | - | Shared base (geography, clustering) |
| `scenario-core-electricity.yaml` | (inherit) | (inherit) | (inherit) | Renewables + CCGT/nuclear + hydro | Clean electricity only |
| `scenario-core-ammonia.yaml` | (inherit) | (inherit) | (inherit) | ↑ + green ammonia chain | Electricity + ammonia |

**Layering pattern**:
```bash
snakemake --configfile config/base-europe17-70n-day.yaml \
          --configfile config/scenarios/scenario-core-electricity.yaml
```

## Environments

### Local (analysis only)
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt  # PyPSA 0.28.0 + xarray, geopandas, etc.
```
Use for downloading results and running analysis notebooks.

### ARC (full simulation)
Built from PyPSA-Earth's `envs/environment.yaml` using:
```bash
sbatch ../pypsa-earth-runtools-crow/scripts/arc/build-pypsa-earth-env
```
Includes Snakemake, Gurobi solver, and all preprocessing tools.

## Key Scripts

- **`scripts/extra/limit_core_technologies.py`**: Filters network to allowed techs (defines `allow_generators`, `allow_storage`, `allow_links`)
- **`scripts/arc/jobs/arc_snakemake.sh`**: Slurm launcher for PyPSA-Earth
- **`scripts/arc/build-pypsa-earth-env`**: Builds conda environment on ARC

## Troubleshooting

**Lock error on job submission?**
```bash
rm -rf .snakemake/locks/* .snakemake/incomplete/*
```

**Wrong network size or clustering?**
→ See [DEVELOPMENT.md](DEVELOPMENT.md) "Configuration Issues" section for focus_weights constraint and common fixes.

**Gurobi license error?**
→ GRB_LICENSE_FILE must point to `/data/engs-df-green-ammonia/engs2523/licenses/gurobi.lic` (set in job script).

## Documentation

- **[DEVELOPMENT.md](DEVELOPMENT.md)** — Technical design, investigation notes, focus_weights constraint, and troubleshooting deep-dives
- **Repository structure** → See config/, scripts/, and notebooks/ subdirectories

## References

- PyPSA-Earth: https://github.com/pypsa-meets-earth/pypsa-earth
- PyPSA fork: https://github.com/cpalazzi/pypsa-earth
- ARC HPC: https://www.arc.ox.ac.uk/
