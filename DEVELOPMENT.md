# Development Notes & Technical Reference

Deep technical documentation, design decisions, investigation findings, and advanced troubleshooting for PyPSA-Earth ARC runner.

## Configuration Architecture

### Design Philosophy

**Base + Scenario pattern**: Keep shared settings (geography, time, solver) in one base config, apply technology-specific overrides via scenario configs.

```
config/
├── base-europe17-70n-day.yaml          # 17 countries, 70 nodes, 1 day, time/solver settings
└── scenarios/
    ├── scenario-core-electricity.yaml  # Restricts techs: renewables + CCGT/nuclear + hydro
    └── scenario-core-ammonia.yaml      # Adds: H2 pipelines, ammonia synthesis, ammonia CCGT
```

**Usage**: `snakemake --configfile base.yaml --configfile scenario.yaml`

### Config Merging (Critical!)

**Problem**: PyPSA-Earth auto-loads `config.yaml`, and `--configfile` args extend it, but **nested dict merging fails** for keys like `scenario.clusters`.

**Solution**: Job script copies base config to `config.yaml` before Snakemake runs, ensuring base values are set before scenario overlays are applied.

See [scripts/arc/jobs/arc_snakemake.sh](scripts/arc/jobs/arc_snakemake.sh) lines 118-127.

## Focus Weights Constraint

### The Issue

PyPSA-Earth's clustering algorithm enforces: **`sum(focus_weights) <= 1.0`**

The weights are *proportions* (not absolute numbers), distributing 70 clusters across countries. Each weight represents the fraction of clusters for that country.

### Current Weights (base-europe17-70n-day.yaml)

```yaml
focus_weights:
  DE: 0.1558  # Germany:     ~11 clusters
  FR: 0.1840  # France:      ~13 clusters
  GB: 0.1563  # UK:          ~11 clusters
  IT: 0.1556  # Italy:       ~11 clusters
  ES: 0.1099  # Spain:       ~8 clusters
  PL: 0.0883  # Poland:      ~6 clusters
  SE: 0.0168  # Sweden:      ~1 cluster (CRITICAL)
  DK: 0.0138  # Denmark:     ~1 cluster
  AT: 0.0206  # Austria:     ~1 cluster
  BG: 0.0112  # Bulgaria:    ~1 cluster
  CZ: 0.0187  # Czech Rep:   ~1 cluster
  GR: 0.0150  # Greece:      ~1 cluster
  HU: 0.0150  # Hungary:     ~1 cluster
  PT: 0.0131  # Portugal:    ~1 cluster
  RO: 0.0168  # Romania:     ~1 cluster
  RS: 0.0090  # Serbia:      ~1 cluster
  # Sum: 0.9999 <= 1.0 ✓
```

**Key insight**: Sweden gets weight 0.0168 (1 cluster out of 70) — this is why previous runs were creating 7+ nodes for Sweden. Too much weight = too many clusters = inefficient modeling.

### Past Failures

**Job 11203186** (3.5-hour timeout):
```
AssertionError: The sum of focus_weights must be less than or equal to 1.
```
Cause: Sum was 1.0004 (rounding error). Fixed by adjusting DE and RS to sum to 0.9999.

## PyPSA-Earth Integration

### Why a Fork?

The patched [`pypsa-earth` fork](https://github.com/cpalazzi/pypsa-earth) includes:

1. **`sitecustomize.py`**: Handles gzipped Geofabrik MD5 manifests (fixes `verify_pbf` failures)
2. **`scripts/solve_network.py`**: Chains multiple `extra_functionality` hooks (so limiter + ammonia both run)

These changes are small and focused; they should be upstreamed eventually. Keep the fork synced:

```bash
git fetch upstream
git merge upstream/main
pytest test/test_gfk_download.py  # verify nothing broke
git push origin main
```

### Extra Functionality Hooks

Defined in scenario configs under `solving.options.extra_functionality`:

```yaml
solving:
  options:
    extra_functionality:
      - scripts/extra/limit_core_technologies.py::limit_core_technologies
```

The hook function receives network object and modifies it in-place. Multiple hooks are chained; order matters if they modify overlapping components.

## Technology Filtering

### allow_generators, allow_storage, allow_links Pattern

[scripts/extra/limit_core_technologies.py](scripts/extra/limit_core_technologies.py) implements component-level filtering by carrier/type.

**Example** (electricity scenario):
```python
allow_generators = {
    "solar", "onwind", "offwind-ac", "offwind-dc",
    "CCGT", "nuclear", "hydro", "ror", "load shedding"
}
# Removes: coal, lignite, H2, batteries, etc.
```

**Ammonia scenario** adds:
```python
allow_generators.add("ammonia")  # Ammonia-fired CCGT
allow_links.add("H2 pipeline", "ammonia pipeline")
allow_stores.add("H2", "ammonia")
```

This approach is **cleaner than config bloat**: define allowed techs in Python with comments, not nested YAML lists.

## Gurobi License

### Setup on ARC

Academic WLS license stored at: `/data/engs-df-green-ammonia/engs2523/licenses/gurobi.lic`

**Key fix** (Job 11201806): Must export `GRB_LICENSE_FILE` in job script:

```bash
export GRB_LICENSE_FILE=/data/engs-df-green-ammonia/engs2523/licenses/gurobi.lic
```

Without this, Gurobi falls back to HiGHS or fails with "Model too large" even though academic license allows it.

### Testing License

```bash
module load Gurobi/<version>
gurobi_cl --help
```

## Common Issues & Solutions

### 1. Focus Weights Sum > 1.0

**Error**: `AssertionError: The sum of focus_weights must be less than or equal to 1.`

**Cause**: Rounding error or too many countries listed.

**Fix**:
```python
weights = {...}
total = sum(weights.values())
if total > 1.0:
    scale = 0.99 / total  # reserve 0.01 as safety margin
    weights = {k: v * scale for k, v in weights.items()}
```

### 2. Wrong Network Size (e.g., 140 nodes instead of 70)

**Cause**: Config merging failed; `scenario.clusters: [70]` not applied. Default (34 countries, 140 nodes) used instead.

**Fix**: Ensure job script copies base config to `config.yaml` before Snakemake starts (see config merging section above).

### 3. Sweden Has 18 Nodes Instead of 1

**Cause**: focus_weights nested under `clustering:` instead of at top-level. PyPSA-Earth's `cluster_network.py` does `config.get("focus_weights", None)` — nesting makes it invisible.

**Fix**: Always keep focus_weights at YAML root level.

### 4. Snakemake Lock Error

**Error**: `LockException: Directory cannot be locked...`

**Cause**: Previous job crashed or was killed; lock file not cleaned.

**Fix**:
```bash
# On ARC, in pypsa-earth directory
rm -rf .snakemake/locks/* .snakemake/incomplete/*
# Then resubmit job
```

### 5. Gurobi "Model too large" Despite Academic License

**Cause**: `GRB_LICENSE_FILE` not exported in job script, so Gurobi uses fallback solver.

**Fix**: Add to job script (already fixed in current version):
```bash
export GRB_LICENSE_FILE=/data/engs-df-green-ammonia/engs2523/licenses/gurobi.lic
```

## Testing Checklist

When adding a new config:

- [ ] **focus_weights sum** ≤ 1.0 (verify via Python: `sum({...}.values())`)
- [ ] **All countries in focus_weights** exist in `countries:` list
- [ ] **focus_weights at top-level** (not nested under `clustering:`)
- [ ] **Scenario config doesn't redefine focus_weights** (inherits from base)
- [ ] **Dry-run Snakemake**: `snakemake -n --configfile base.yaml --configfile scenario.yaml`
- [ ] **Check DAG**: Should have ~22 rules for single-day Europe run
- [ ] **Submit test job** and monitor first 30 minutes (clustering rules)

## Investigation Timeline

This project involved systematic debugging of:

1. **Scope mismatch**: Job using 34 countries instead of 17 → diagnosed config path issue
2. **Clustering failure**: Sweden 7 nodes instead of 1 → found focus_weights nesting bug
3. **Merging architecture**: Nested dict values not overridden → implemented base-copy solution
4. **Gurobi licensing**: "Model too large" error → added GRB_LICENSE_FILE export
5. **Focus weights normalization**: Sum 1.0004 → adjusted DE and RS

Each fix was validated with test jobs (11199899, 7030108, 11201804, 11201806, 11203186, 11203671) and documented in git history.

## Future Work

- [ ] Upstream PyPSA-Earth fork fixes (sitecustomize.py, extra_functionality chaining)
- [ ] Add longer time horizons (week, month) as scenario configs
- [ ] Test multi-objective scenarios (e.g., cost vs. emissions)
- [ ] Extend to 34 countries with adjusted focus_weights
- [ ] Document results analysis patterns in notebooks/

## References

- PyPSA-Earth: https://github.com/pypsa-meets-earth/pypsa-earth
- PyPSA fork (this project): https://github.com/cpalazzi/pypsa-earth
- Gurobi WLS licensing: https://www.gurobi.com/academia/

## See Also

- [README.md](README.md) — Quick start and common tasks
- Config files — See detailed comments in `config/base-europe17-70n-day.yaml`
- Job script — [scripts/arc/jobs/arc_snakemake.sh](scripts/arc/jobs/arc_snakemake.sh)
