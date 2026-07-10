# DRCC — Database of Regional Climate Change: construction pipeline

Code to build the **Database of Regional Climate Change (DRCC)**, a research-ready
panel of daily climate indicators from **1 January 1950 to 31 December 2025** at
three administrative levels (admin-0 countries, admin-1 states, admin-2 districts).

The pipeline downloads ERA5 and CEMS fire rasters, cleans the World Bank
administrative boundaries, extracts variable-specific zonal statistics per
polygon, merges them into daily panels, and derives the annual indicators.

## Repository layout

```
drcc-pipeline/
├── config.R                      # single source of paths, years, and constants
├── R/
│   └── setup_packages.R          # shared package loading (sourced by config.R)
├── 0_download/
│   ├── download_era5.py          # ERA5 daily mean/max temperature + total precipitation (CDS)
│   └── download_cems_fire.py     # CEMS Fire Weather Index / Keetch-Byram Drought Index (EWDS)
├── 1_boundaries/
│   ├── clean_wb_shapefiles.R     # REGID, geometry repair, full-res + reduced shapefiles
│   ├── build_map_layers.R        # member-state map layers + dissolved borders
│   └── build_region_metadata.R   # META.xlsx (REGID ↔ region names / countries)
├── 2_extract/
│   ├── extract_weather.R         # zonal stats for the 6 weather variables × admin levels × years
│   └── extract_wetbulb.R         # zonal stats for the wet-bulb product (see external inputs)
├── 3_panels/
│   ├── merge_daily_panels.R      # per-variable extractions → merged daily panels (+ Stata for admin-0)
│   ├── build_annual_indicators.R # daily panels → annual indicators + composite indices (SHINY_TS)
│   └── split_annual_by_level.R   # SHINY_TS → annual_admin0/1/2 panels (+ CSV for admin-0/1)
├── 4_figures/
│   └── make_figures.R            # manuscript Figures 1-4 from the DRCC data products
├── validation/
│   ├── zonal_vs_extract_benchmark.R  # reproducibility check of the zonal aggregation
│   ├── download_berkeley.R       # fetch Berkeley Earth country series
│   ├── validate_berkeley.R       # admin-0 validation vs Berkeley Earth → Figure 5
│   ├── download_be_states.R      # fetch Berkeley Earth US-state series
│   └── validate_us_states.R      # admin-1 validation vs Berkeley Earth → Figure 6
├── R/setup_packages.R, R/setup_figure_packages.R
├── config.R, LICENSE, README.md
```

## Configuration

All paths, the year span (`1950–2025`), and every numeric constant live in
[`config.R`](config.R). Every R script begins with `source("config.R")` and must
be run with the **repository root as the working directory**.

Data lives **outside** the repository. Point one environment variable at it:

```bash
export DRCC_DATA=/path/to/drcc_data     # default: ~/drcc_data
```

Everything else (`raw_rasters/`, `boundaries/`, `intermediate/`, `final/`, …) is
derived from `DRCC_DATA`; individual directories can be overridden with an
environment variable of the same name.

## Requirements

- **R** (≥ 4.x). Packages install on first run via `pacman` (see `R/setup_packages.R`).
  - `rgeos::gBuffer(width = 0)` is used for geometry repair and kept for exact
    replication. `rgeos` was archived from CRAN in 2023 — install it from the
    archive: `remotes::install_version("rgeos", version = "0.6-4")`.
- **Python 3.9+** with `cdsapi` (`pip install cdsapi`) for the download step.
- **API credentials** (not included):
  - `~/.cdsapirc` — Copernicus Climate Data Store (ERA5).
  - `~/.ewdsapirc` — Early Warning Data Store (CEMS fire).

## Running the pipeline

Set `DRCC_DATA`, place the external inputs (below), then run in order:

```bash
# 0. Download rasters  (ERA5 needs the years explicitly; CEMS one variable per call)
python 0_download/download_era5.py $(seq 1950 2025)
python 0_download/download_cems_fire.py fire_weather_index
python 0_download/download_cems_fire.py keetch_byram_drought_index

# 1. Boundaries  (needs the raw WB shapefiles in $DRCC_DATA/boundaries/raw_WB)
Rscript 1_boundaries/clean_wb_shapefiles.R
Rscript 1_boundaries/build_map_layers.R
Rscript 1_boundaries/build_region_metadata.R

# 2. Extraction
Rscript 2_extract/extract_weather.R
Rscript 2_extract/extract_wetbulb.R          # needs the wet-bulb product (see below)

# 3. Panels
Rscript 3_panels/merge_daily_panels.R
Rscript 3_panels/build_annual_indicators.R   # needs the wet-bulb indicator table (see below)
Rscript 3_panels/split_annual_by_level.R
```

`./run_pipeline.sh` runs the same sequence. Every stage is idempotent: existing
outputs are skipped, so runs can be resumed.

## Reproducing the manuscript figures

After the panels are built, the figures are regenerated from the DRCC outputs
(written to `$DRCC_DATA/figures/`):

```bash
# Figures 1-4 (coverage map, time-series, admin-2 change densities, OWID scatter)
Rscript 4_figures/make_figures.R          # Figure 4 also needs OWID_CSV (see below)

# Figures 5-6 (external validation vs Berkeley Earth) — download then plot
Rscript validation/download_berkeley.R
Rscript validation/validate_berkeley.R    # -> Figure 5
Rscript validation/download_be_states.R
Rscript validation/validate_us_states.R   # -> Figure 6
```

Figures **7 and 8** are screenshots of the interactive map and geocode-to-region
tools and are not generated from code.

The figure/validation scripts load an extra plotting stack via
`R/setup_figure_packages.R` (ggplot2, ggsci, patchwork, countrycode, …), kept
separate from the headless core pipeline.

## External inputs (not in this repository)

The ERA5 → CEMS branch runs end-to-end from the downloads above. Three inputs are
supplied by the user because they are licensed or produced outside this pipeline:

1. **World Bank administrative shapefiles** — layers `WB_GAD_ADM0/1/2` in
   `$DRCC_DATA/boundaries/raw_WB/`. Not redistributed here (data-licence
   restriction); obtain them from the World Bank.
2. **Wet-bulb temperature product** — the WB Climate Change Knowledge Portal
   annual wet-bulb (wbt31) NetCDF, placed in `$DRCC_DATA/raw_wetbulb/`. It is a
   pre-computed product and is **not** downloadable via the CDS/EWDS scripts.
3. **Wet-bulb indicator table** (`WETBULB_TS_RDATA`) — `build_annual_indicators.R`
   carries the wet-bulb rows (`wbt27`, `wetbulbtemperature`, `wetbulbdays`) from
   this table rather than recomputing them; supply it at the configured path.
4. **Our World in Data monthly temperature CSV** (`OWID_CSV`) — used only by the
   Figure 4 validation scatter; download from https://ourworldindata.org and
   place at `$DRCC_DATA/validation/OWID_temperature.csv`. The Berkeley Earth
   series for Figures 5-6 are fetched automatically by the `download_*` scripts.

## Data sources

- ECMWF ERA5, Copernicus Climate Data Store — CC BY 4.0
- CEMS Fire Historical v1, Early Warning Data Store — CC BY 4.0
- Wet-bulb temperature, World Bank Climate Change Knowledge Portal — CC BY 4.0

The DRCC data are distributed under CC BY 4.0; see the accompanying data descriptor.

## Licence

Code released under the MIT License — see [LICENSE](LICENSE).
