#!/usr/bin/env bash
###############################################################################
# Run the full DRCC construction pipeline in order.
#
# Prerequisites (see README.md):
#   - export DRCC_DATA=/path/to/drcc_data
#   - CDS / EWDS credentials in ~/.cdsapirc and ~/.ewdsapirc
#   - Raw WB shapefiles in  $DRCC_DATA/boundaries/raw_WB   (layers WB_GAD_ADM0/1/2)
#   - Wet-bulb NetCDF in     $DRCC_DATA/raw_wetbulb        (WB CCKP product)
#   - Wet-bulb indicator table at WETBULB_TS_RDATA
#
# Run from the repository root:  ./run_pipeline.sh
###############################################################################
set -euo pipefail
cd "$(dirname "$0")"

: "${DRCC_DATA:=$HOME/drcc_data}"
export DRCC_DATA
echo "DRCC_DATA = $DRCC_DATA"

# 0. Download rasters --------------------------------------------------------
python3 0_download/download_era5.py $(seq 1950 2025)
python3 0_download/download_cems_fire.py fire_weather_index
python3 0_download/download_cems_fire.py keetch_byram_drought_index

# 1. Boundaries --------------------------------------------------------------
Rscript 1_boundaries/clean_wb_shapefiles.R
Rscript 1_boundaries/build_map_layers.R
Rscript 1_boundaries/build_region_metadata.R

# 2. Extraction --------------------------------------------------------------
Rscript 2_extract/extract_weather.R
Rscript 2_extract/extract_wetbulb.R

# 3. Panels ------------------------------------------------------------------
Rscript 3_panels/merge_daily_panels.R
Rscript 3_panels/build_annual_indicators.R
Rscript 3_panels/split_annual_by_level.R

echo "DRCC pipeline complete."
