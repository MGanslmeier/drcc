"""
Download one CEMS fire-danger variable from EWDS for 1950-2025 — in parallel.

Where this sits in the pipeline
    Stage 0 (download). Fetches raw CEMS fire NetCDFs that later stages extract
    zonally against the WB admin boundaries. This is a raw-download step only:
    no unit conversion, aggregation, rounding, or any other computation happens
    here — files are written exactly as delivered by EWDS.

Source
    The CEMS fire dataset lives on the ECMWF Early Warning Data Store (EWDS),
    NOT on the Copernicus Climate Data Store (CDS). Credentials are read from
    ~/.ewdsapirc (url/key), parsed by splitting each line on the FIRST ':'.

Inputs
    argv[1]         CEMS variable name to download, e.g.:
                        fire_weather_index
                        keetch_byram_drought_index
                        drought_code
                        duff_moisture_code
                        fine_fuel_moisture_code
    ~/.ewdsapirc    EWDS API credentials (keys 'url' and 'key').
    DRCC_DATA       Env var for the data root (default ~/drcc_data).

Outputs
    <DRCC_DATA>/raw_rasters/<variable>/<variable>_<year>.nc
        One NetCDF per year (1950-2025), all months and all days, on a
        0.25/0.25 degree grid.

Usage
    python3 download_cems_fire.py <variable_name>

Re-runs are safe: any year whose target file already exists is skipped
(existence-only check, no integrity validation).
"""

import os
import sys
import time
import threading
import cdsapi

# ---- Configuration -------------------------------------------------------
# Data root: one switch to relocate all downloads (mirrors config.R DRCC_DATA).
DRCC_DATA = os.environ.get("DRCC_DATA", os.path.expanduser("~/drcc_data"))
RAW_ROOT = os.path.join(DRCC_DATA, "raw_rasters")

DATASET = "cems-fire-historical-v1"
YEARS = list(range(1950, 2026))

MONTHS = [f"{m:02d}" for m in range(1, 13)]
DAYS = [f"{d:02d}" for d in range(1, 32)]


# ---- Helpers -------------------------------------------------------------
def load_ewds_credentials(path: str = "~/.ewdsapirc") -> tuple[str, str]:
    """Parse ~/.ewdsapirc: split each 'key: value' line on the FIRST ':'."""
    cfg = {}
    with open(os.path.expanduser(path)) as f:
        for line in f:
            if ":" in line:
                k, v = line.split(":", 1)
                cfg[k.strip()] = v.strip()
    return cfg["url"], cfg["key"]


def build_request(variable: str, year: int) -> dict:
    return {
        "product_type": "reanalysis",
        "variable": [variable],
        "dataset_type": "consolidated_dataset",
        "system_version": ["4_1"],
        "year": [str(year)],
        "month": MONTHS,
        "day": DAYS,
        "grid": "0.25/0.25",
        "data_format": "netcdf",
    }


def target_path(variable: str, year: int, outdir: str) -> str:
    return os.path.join(outdir, f"{variable}_{year}.nc")


def stamp() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


# ---- Per-year worker -----------------------------------------------------
def download_year(variable: str, year: int, outdir: str, url: str, key: str) -> None:
    tag = f"[{variable} {year}]"
    target = target_path(variable, year, outdir)

    if os.path.exists(target):
        size_mb = os.path.getsize(target) / (1024 * 1024)
        print(f"{stamp()} {tag} SKIP: {target} already exists ({size_mb:.1f} MB)", flush=True)
        return

    client = cdsapi.Client(url=url, key=key, quiet=True)
    print(f"{stamp()} {tag} submitting request -> {target}", flush=True)
    try:
        result = client.retrieve(DATASET, build_request(variable, year))
        print(f"{stamp()} {tag} ready, downloading...", flush=True)
        result.download(target=target)
        size_mb = os.path.getsize(target) / (1024 * 1024)
        print(f"{stamp()} {tag} DONE: {size_mb:.1f} MB", flush=True)
    except Exception as e:
        print(f"{stamp()} {tag} FAILED: {e}", flush=True)


# ---- Driver --------------------------------------------------------------
def main(variable: str) -> int:
    outdir = os.path.join(RAW_ROOT, variable)
    os.makedirs(outdir, exist_ok=True)

    url, key = load_ewds_credentials()
    print(f"{stamp()} variable={variable} | EWDS endpoint: {url}", flush=True)

    threads = []
    for year in YEARS:
        t = threading.Thread(
            target=download_year,
            args=(variable, year, outdir, url, key),
            name=f"{variable}-{year}",
            daemon=False,
        )
        t.start()
        threads.append(t)
        time.sleep(2)  # stagger so EWDS request IDs come back in year order

    for t in threads:
        t.join()

    print(f"{stamp()} all years for {variable} processed.", flush=True)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 download_cems_fire.py <variable_name>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
