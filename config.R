###############################################################################
## DRCC pipeline — central configuration.
##
## Source this at the top of every R stage script:  source("config.R")
## Run all R scripts with the repository root as the working directory.
##
## All data lives OUTSIDE the code repository (it is large). Point DRCC_DATA at
## the directory that holds the raw rasters, intermediate extractions, cleaned
## boundaries, and final panels. Every path below is derived from it and can be
## overridden individually via an environment variable of the same name.
###############################################################################

`%||%` <- function(a, b) if (is.null(a) || is.na(a) || !nzchar(a)) b else a

## ---- Root ----------------------------------------------------------------
# One switch to relocate all data. Default: ~/drcc_data (override with DRCC_DATA).
DRCC_DATA <- Sys.getenv("DRCC_DATA", unset = path.expand("~/drcc_data"))

## ---- Data subdirectories -------------------------------------------------
DIR_RAW_RASTERS        <- file.path(DRCC_DATA, "raw_rasters")            # downloaded ERA5 / CEMS NetCDFs
DIR_WETBULB_RAW        <- file.path(DRCC_DATA, "raw_wetbulb")            # WB CCKP wet-bulb product (supplied separately)
DIR_BOUNDARIES         <- file.path(DRCC_DATA, "boundaries")            # cleaned WB shapefiles (sh_admin*.RData)
DIR_BOUNDARIES_RAW     <- file.path(DIR_BOUNDARIES, "raw_WB")           # raw WB shapefiles (layers WB_GAD_ADM0/1/2)
DIR_BOUNDARIES_REDUCED <- file.path(DIR_BOUNDARIES, "reduced")          # simplified full-coverage shapefiles
DIR_MAP_LAYERS         <- file.path(DIR_BOUNDARIES, "map_layers")       # member-state map layers + borders
DIR_INTERMEDIATE       <- file.path(DRCC_DATA, "intermediate")          # per-(admin, variable, year) extractions
DIR_FINAL              <- file.path(DRCC_DATA, "final")                 # merged daily panels
DIR_ANNUAL             <- file.path(DIR_FINAL, "annual")               # annual panels split by admin level
DIR_META               <- file.path(DIR_FINAL, "meta")                # META.xlsx
DIR_SHINY              <- file.path(DIR_FINAL, "shiny")                # SHINY_TS long annual-indicator table
DIR_VALIDATION         <- file.path(DRCC_DATA, "validation")           # external-validation downloads + comparison outputs
DIR_FIGURES            <- file.path(DRCC_DATA, "figures")              # generated manuscript figures (PNG)

# Our World in Data monthly temperature CSV, used for the admin-0 validation
# figure (Figure 4). Obtain from https://ourworldindata.org and place here.
OWID_CSV <- Sys.getenv("OWID_CSV", unset = file.path(DIR_VALIDATION, "OWID_temperature.csv"))

# The wet-bulb annual-indicator table carried forward for wbt27 / wetbulbtemperature
# rows (see build_annual_indicators.R). Supplied externally; not produced by the
# ERA5/CEMS branch of this pipeline.
WETBULB_TS_RDATA <- Sys.getenv("WETBULB_TS_RDATA", unset = file.path(DIR_SHINY, "wetbulb_ts.RData"))

## ---- Time span -----------------------------------------------------------
YEAR_START <- 1950L
YEAR_END   <- 2025L
YEARS      <- YEAR_START:YEAR_END

ADMIN_LEVELS <- 0:2

## ---- Weather variables and per-variable zonal aggregation ----------------
## name = intermediate/output folder and column name; src = raw raster subfolder;
## file = NetCDF filename template (sprintf %d = year); fun = zonal aggregation
## function applied over the pixels inside each polygon.
##   NOTE (preserve exactly): 2m_temperature_max stores the zonal MEAN of the
##   daily-maximum grid; total_precipitation and total_precipitation_geoMax read
##   the SAME source raster but use mean vs max.
WEATHER_VARS <- list(
  list(name = "2m_temperature",             src = "2m_temperature",             file = "2m_temperature_mean_%d.nc",     fun = "mean"),
  list(name = "2m_temperature_max",         src = "2m_temperature_max",         file = "2m_temperature_max_%d.nc",      fun = "mean"),
  list(name = "total_precipitation",        src = "total_precipitation",        file = "total_precipitation_sum_%d.nc", fun = "mean"),
  list(name = "total_precipitation_geoMax", src = "total_precipitation",        file = "total_precipitation_sum_%d.nc", fun = "max"),
  list(name = "fire_weather_index",         src = "fire_weather_index",         file = "fire_weather_index_%d.nc",      fun = "max"),
  list(name = "keetch_byram_drought_index", src = "keetch_byram_drought_index", file = "keetch_byram_drought_index_%d.nc", fun = "max")
)

# Join order for the daily merge (must match the published panels).
VARS_BASE         <- c("2m_temperature", "2m_temperature_max", "fire_weather_index",
                       "keetch_byram_drought_index", "total_precipitation")
VARS_ADMIN2_EXTRA <- c("total_precipitation_geoMax")   # appended only at admin-2

## ---- Numeric constants that define the published database ----------------
KELVIN_OFFSET    <- 273.15      # K -> degC
TEMP_ROUND_DP    <- 3L          # temperatures rounded to 3 dp after conversion
ADMIN2_BUFFER_M  <- 60000       # 60 km crop buffer at admin-2 (crop window only; extraction stays on unbuffered polygons)

## Shapefile simplification (Douglas-Peucker via rmapshaper::ms_simplify, keep_shapes = TRUE)
SIMPLIFY_KEEP_REDUCED <- 0.0005                          # extraction-ready reduced copies (all levels)
SIMPLIFY_KEEP_MAP     <- c(`0` = 0.5, `1` = 0.2, `2` = 0.002)  # member-state map layers, per level

## Derived-indicator thresholds (units as supplied: temperatures already in degC)
HEAT_VARS            <- c("t2m_temperature", "t2m_temperature_max",
                          "fire_weather_index", "keetch_byram_drought_index")
HEAT_DAY_THRESHOLD   <- 35      # heat_days = sum(t2m_temperature_max > 35)
COLD_DAY_THRESHOLD   <- 0       # cold_days = sum(t2m_temperature_max < 0)
FLOOD_MM_PER_DAY     <- c(`50` = 50, `20` = 20)  # flood_days50 / flood_days20 (admin-2)
# NB: the mm/day conversion is applied inline as `geoMax * 24 * 1000` (two-step,
# to preserve the exact float rounding of the published database) — not folded
# into a single 24000 factor.

## Years retained in the decadal map datasets (SHINY_admin*)
DECADAL_YEARS <- c(seq(1950, 2020, 10), 2021:2025)

## Canonical 14-indicator whitelist for the annual panels (order and spelling are load-bearing).
KEEP_INDICATORS <- c(
  "total_precipitation", "mean_t2m_temperature", "max_t2m_temperature_max",
  "heat_days", "cold_days", "max_fire_weather_index", "max_keetch_byram_drought_index",
  "heat_index_pca", "heat_index_mean", "sd_t2m_temperature", "flood_days50", "flood_days20",
  "wbt27", "wetbulbtemperature"
)

## Wet-bulb indicators carried forward from WETBULB_TS_RDATA (not recomputed by ERA5/CEMS branch).
WETBULB_INDICATORS <- c("wetbulbdays", "wbt27", "wetbulbtemperature")

## ---- Shared packages -----------------------------------------------------
source("R/setup_packages.R")
