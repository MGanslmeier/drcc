#!/usr/bin/env python3
"""
Download annual ERA5 daily-statistics rasters from the Copernicus CDS API — in parallel.

Stage 0 (download) of the DRCC climate-database pipeline. Fetches three raw
variables per requested year and writes them into per-variable subfolders that
match config.R's DIR_RAW_RASTERS (<DRCC_DATA>/raw_rasters/):
  - 2m_temperature daily mean     -> raw_rasters/2m_temperature/2m_temperature_mean_YYYY.nc
  - 2m_temperature daily maximum  -> raw_rasters/2m_temperature_max/2m_temperature_max_YYYY.nc
  - total_precipitation daily sum -> raw_rasters/total_precipitation/total_precipitation_sum_YYYY.nc

Uses the "derived-era5-single-levels-daily-statistics" dataset, which returns
daily statistics directly. All (year, variable) jobs are submitted to CDS
concurrently so they queue side-by-side and finish faster overall.

Data are delivered as-is by CDS and written unchanged: temperature stays in
KELVIN and precipitation in METRES. No unit conversion, rounding, or NA handling
happens here — those transformations are applied by later pipeline stages.

Inputs:
  - CDS API credentials in ~/.cdsapirc
  - CLI: positional years (0+ ints), --out (output root), --overwrite (flag)

Outputs:
  - Three per-variable NetCDF folders under the output root (default:
    <DRCC_DATA>/raw_rasters, DRCC_DATA env default ~/drcc_data).

Usage:
    python download_era5.py                # last completed year
    python download_era5.py 2024           # specific year
    python download_era5.py 2024 2025      # multiple years
    python download_era5.py --out /path    # custom output root
"""

import argparse
import os
import threading
import time
from datetime import date

import cdsapi

# Default output root mirrors config.R: DIR_RAW_RASTERS = <DRCC_DATA>/raw_rasters,
# with DRCC_DATA defaulting to ~/drcc_data.
DRCC_DATA = os.path.expanduser(os.environ.get("DRCC_DATA", "~/drcc_data"))
DEFAULT_OUT_ROOT = os.path.join(DRCC_DATA, "raw_rasters")

DATASET = "derived-era5-single-levels-daily-statistics"

# (variable, daily_statistic, subfolder under OUT_ROOT, filename template)
JOBS = [
    ("2m_temperature",      "daily_mean",    "2m_temperature",
     "2m_temperature_mean_{year}.nc"),
    ("2m_temperature",      "daily_maximum", "2m_temperature_max",
     "2m_temperature_max_{year}.nc"),
    ("total_precipitation", "daily_sum",     "total_precipitation",
     "total_precipitation_sum_{year}.nc"),
]


# ---- CDS request -----------------------------------------------------------
def build_request(variable: str, daily_statistic: str, year: int) -> dict:
    return {
        "product_type":    "reanalysis",
        "variable":        [variable],
        "year":            str(year),
        "month":           [f"{m:02d}" for m in range(1, 13)],
        "day":             [f"{d:02d}" for d in range(1, 32)],
        "daily_statistic": daily_statistic,
        "time_zone":       "utc+00:00",
        "frequency":       "1_hourly",
        "area":            [90, -180, -90, 180],  # global
        "format":          "netcdf",
    }


def stamp() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


# ---- Per-job worker (one thread each) --------------------------------------
def download_job(variable: str, daily_statistic: str, year: int,
                 out_path: str, overwrite: bool, out_root: str) -> None:
    tag = f"[{year} {os.path.basename(out_path)}]"
    rel = os.path.relpath(out_path, out_root)

    # Skip-if-exists idempotency (existence only; no size/integrity check).
    if os.path.exists(out_path) and not overwrite:
        size_mb = os.path.getsize(out_path) / 1e6
        print(f"{stamp()} {tag} SKIP: {rel} already exists ({size_mb:.1f} MB)",
              flush=True)
        return

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    # cdsapi clients aren't guaranteed thread-safe; one per thread.
    client = cdsapi.Client(quiet=True)
    print(f"{stamp()} {tag} submitting -> {rel}", flush=True)
    try:
        result = client.retrieve(DATASET,
                                 build_request(variable, daily_statistic, year))
        print(f"{stamp()} {tag} ready, downloading...", flush=True)
        result.download(out_path)
        size_mb = os.path.getsize(out_path) / 1e6
        print(f"{stamp()} {tag} DONE: {size_mb:.1f} MB", flush=True)
    except Exception as e:
        # Per-job failures are swallowed so one bad job doesn't abort the others.
        print(f"{stamp()} {tag} FAILED: {e}", flush=True)


# ---- CLI -------------------------------------------------------------------
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("years", nargs="*", type=int,
                   help="One or more years (default: last completed year)")
    p.add_argument("--out", default=DEFAULT_OUT_ROOT,
                   help=f"Output root (default: {DEFAULT_OUT_ROOT}). "
                        f"Per-variable subfolders are created under this.")
    p.add_argument("--overwrite", action="store_true",
                   help="Re-download even if file already exists")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    # No years given -> default to the last completed (previous) calendar year.
    years = args.years or [date.today().year - 1]
    out_root = args.out

    # Create the output root on a fresh machine (per-variable subfolders are made
    # per job inside download_job).
    os.makedirs(out_root, exist_ok=True)

    print(f"{stamp()} years={years} out_root={out_root}", flush=True)

    threads = []
    for year in years:
        for variable, daily_statistic, subfolder, fname_tpl in JOBS:
            out_path = os.path.join(out_root, subfolder,
                                    fname_tpl.format(year=year))
            t = threading.Thread(
                target=download_job,
                args=(variable, daily_statistic, year, out_path,
                      args.overwrite, out_root),
                name=f"{subfolder}-{year}",
                daemon=False,
            )
            t.start()
            threads.append(t)
            # Stagger so CDS request IDs come back in submission order.
            time.sleep(2)

    for t in threads:
        t.join()

    print(f"{stamp()} all jobs processed.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
