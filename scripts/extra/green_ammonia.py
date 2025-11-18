"""Custom extra functionality hook for PyPSA-Earth.

The ``add_green_ammonia`` entry point is meant to be referenced from the
``solving.options.extra_functionality`` list.  When enabled, it injects three
components at (or near) the requested country node:

* An electricity -> NH3 link that represents a green-ammonia electrolyser.
* An NH3 store (energy-equivalent tank) with extendable energy volume.
* An NH3 -> electricity link that behaves like an ammonia-fuelled CCGT.

All techno-economic assumptions are configured in
``config/overrides/green-ammonia.yaml`` under ``custom.green_ammonia``.
"""

from __future__ import annotations

from math import inf
from typing import Any, Dict, Optional

import numpy as np
import pandas as pd

try:
    import pypsa  # type: ignore
except ImportError as exc:  # pragma: no cover - only executed inside snakemake
    raise RuntimeError("PyPSA must be installed in the runtime environment") from exc


def _get_cfg(config: Dict[str, Any]) -> Dict[str, Any]:
    """Pull the nested green ammonia dictionary or return an empty dict."""

    return config.get("custom", {}).get("green_ammonia", {})


def _ensure_carrier(network: "pypsa.Network", name: str) -> None:
    """Create a carrier if it does not already exist."""

    if name in network.carriers.index:
        return
    network.add("Carrier", name)


def _closest_bus(
    network: "pypsa.Network",
    country_code: str,
    latitude: Optional[float],
    longitude: Optional[float],
    bus_substring: Optional[str] = None,
) -> str:
    """Pick the closest bus inside ``country_code`` to the provided lat/lon."""

    candidates = network.buses[network.buses.country == country_code]
    if candidates.empty:
        raise ValueError(
            f"No buses found for country '{country_code}'. Did you run add_electricity?"
        )

    if bus_substring:
        narrowed = candidates[candidates.index.str.contains(bus_substring)]
        if not narrowed.empty:
            candidates = narrowed

    if latitude is None or longitude is None:
        return candidates.index[0]

    coords = candidates[["y", "x"]].to_numpy(dtype=float)
    target = np.array([latitude, longitude], dtype=float)
    distances = np.linalg.norm(coords - target, axis=1)
    idx = distances.argmin()
    return candidates.index[idx]


def _add_bus(network: "pypsa.Network", base_bus: str, carrier: str) -> str:
    base = network.buses.loc[base_bus]
    label = f"{base_bus}-NH3"
    if label in network.buses.index:
        return label
    network.add(
        "Bus",
        label,
        x=base.x,
        y=base.y,
        country=base.country,
        carrier=carrier,
        sub_network=base.get("sub_network", "")
        if isinstance(base, pd.Series)
        else None,
    )
    return label


def _add_electrolyser(
    network: "pypsa.Network",
    base_bus: str,
    nh3_bus: str,
    cfg: Dict[str, Any],
    carrier_name: str,
) -> None:
    label = f"{base_bus}-NH3-electrolyser"
    if label in network.links.index:
        return
    network.add(
        "Link",
        label,
        bus0=base_bus,
        bus1=nh3_bus,
        carrier=carrier_name,
        efficiency=cfg.get("efficiency", 0.6),
        capital_cost=cfg.get("capital_cost", 7.5e5),
        marginal_cost=cfg.get("marginal_cost", 0.5),
        lifetime=cfg.get("lifetime", 20),
        p_nom_extendable=True,
        p_nom_max=cfg.get("p_nom_max", inf),
    )


def _add_storage(
    network: "pypsa.Network",
    nh3_bus: str,
    cfg: Dict[str, Any],
    carrier_name: str,
) -> None:
    label = f"{nh3_bus}-store"
    if label in network.stores.index:
        return
    network.add(
        "Store",
        label,
        bus=nh3_bus,
        carrier=carrier_name,
        e_cyclic=cfg.get("e_cyclic", True),
        standing_loss=cfg.get("standing_loss", 0.0),
        capital_cost=cfg.get("capital_cost", 1.5e5),
        e_nom_extendable=True,
        e_nom_max=cfg.get("e_nom_max", inf),
    )


def _add_ccgt(
    network: "pypsa.Network",
    base_bus: str,
    nh3_bus: str,
    cfg: Dict[str, Any],
    carrier_name: str,
) -> None:
    label = f"{base_bus}-NH3-CCGT"
    if label in network.links.index:
        return
    network.add(
        "Link",
        label,
        bus0=nh3_bus,
        bus1=base_bus,
        carrier=carrier_name,
        efficiency=cfg.get("efficiency", 0.55),
        capital_cost=cfg.get("capital_cost", 9e5),
        marginal_cost=cfg.get("marginal_cost", 2.5),
        lifetime=cfg.get("lifetime", 25),
        p_nom_extendable=True,
        p_nom_max=cfg.get("p_nom_max", inf),
    )


def add_green_ammonia(
    network: "pypsa.Network",
    snapshots,
    config: Dict[str, Any],
    **_,
) -> None:
    """Entry point expected by Snakemake's ``extra_functionality`` hook."""

    ga_cfg = _get_cfg(config)
    if not ga_cfg.get("enable", False):
        return

    country = ga_cfg.get("country_code", "ES")
    location = ga_cfg.get("location", {})
    base_bus = _closest_bus(
        network,
        country,
        location.get("latitude"),
        location.get("longitude"),
        location.get("bus_substring"),
    )

    carriers = ga_cfg.get("carriers", {})
    carrier_store = carriers.get("ammonia", "NH3")
    carrier_electrolyser = carriers.get("to_store", "NH3-electrolyser")
    carrier_ccgt = carriers.get("to_power", "NH3-power")

    for name in (carrier_store, carrier_electrolyser, carrier_ccgt):
        _ensure_carrier(network, name)

    nh3_bus = _add_bus(network, base_bus, carrier_store)
    _add_electrolyser(network, base_bus, nh3_bus, ga_cfg.get("electrolyser", {}), carrier_electrolyser)
    _add_storage(network, nh3_bus, ga_cfg.get("storage", {}), carrier_store)
    _add_ccgt(network, base_bus, nh3_bus, ga_cfg.get("ccgt", {}), carrier_ccgt)

    print(  # pragma: no cover - informational log inside snakemake
        f"Injected green-ammonia chain at {base_bus}: electrolyser, store, CCGT"
    )
