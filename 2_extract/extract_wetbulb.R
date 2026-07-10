###############################################################################
## extract_wetbulb.R
##
## Purpose:
##   Polygon zonal extraction of the wet-bulb-temperature (wbt31) multi-band
##   annual NetCDF over World Bank admin-0/1/2 shapefiles. Two passes over the
##   SAME source raster produce two derived variables:
##     - wetbulbtemperature : polygon MEAN of the annual wet-bulb field
##     - wetbulbdays        : polygon MAX  of the same field
##   One per-year RData file (object `val`, columns REGID, DATE, value) is
##   written per admin level per variable per band/year.
##
## Inputs:
##   DIR_WETBULB_RAW/<wbt NetCDF>   multi-band annual wet-bulb raster (1 band =
##                                  1 year). This is the World Bank CCKP wet-bulb
##                                  product; it is SUPPLIED EXTERNALLY and is NOT
##                                  downloaded by 0_download in this pipeline.
##   DIR_MAP_LAYERS/sh_admin{0,1,2}.RData   member-state MAP layers (objects
##                                  sh_admin0/1/2), each an SPDF with a REGID
##                                  column. The original consumes the MAP layers
##                                  here (not the reduced extraction copies);
##                                  that choice is preserved.
##
## Outputs:
##   DIR_INTERMEDIATE/wb_admin{n}/<var>/<YYYY>.RData   (n in 0:2;
##       var in {wetbulbtemperature, wetbulbdays}; YYYY = 4-digit band year)
##   Each holds a data.frame `val` with exactly REGID, DATE, value, one row per
##   polygon. Written only if the target file does not already exist.
##
## Pipeline position:
##   Extraction stage, alongside extract_weather.R. Feeds the wet-bulb branch of
##   the downstream annual-indicator build.
##
## Quirks preserved exactly:
##   - Aggregation differs by output variable over the SAME source raster:
##     wetbulbtemperature -> fun = mean, wetbulbdays -> fun = max.
##   - NO unit conversion, rounding, longitude rotation, negative clamping, or
##     Inf handling. Values are written raw as returned by raster::extract with
##     na.rm = TRUE only.
##   - Output files are named by YEAR (first 4 chars of the band z-date), while
##     the DATE column stores the FULL band date (as.Date(temp@z[[1]])).
##   - REGID is taken from the shapefile @data via select(matches('REGID')) and
##     prepended before the extraction values; positional set_names then labels
##     the four columns ('REGID','value.ID','value','DATE') and value.ID is
##     dropped, leaving exactly REGID, DATE, value.
##   - `sh` is consumed as a GLOBAL inside extractWeatherRegion (set by the
##     caller loop), not passed as an argument.
##   - Idempotent/resumable: a band is skipped if its target .RData exists.
###############################################################################

source("config.R")

rasterOptions(maxmemory = 6e+11, chunksize = 1e+10)

## ---- Zonal extraction helper --------------------------------------------
## Extracts every band of the raster at `path` over the global shapefile `sh`,
## aggregating pixels inside each polygon with `fun`, and writes one per-year
## RData per band under wb_admin<n>/<var>/. `sh` is read from the enclosing
## environment (global), matching the original control flow.
extractWeatherRegion <- function(path, var, n, fun){
  library(dplyr)
  library(raster)
  library(purrr)
  library(stringr)
  library(lubridate)
  outDir <- file.path(DIR_INTERMEDIATE, paste0('wb_admin', n), var)
  dir.create(outDir, recursive = TRUE, showWarnings = FALSE)
  meta <- raster(path)
  nBand <- meta %>% nbands(.)
  for(k in 1:nBand){
    temp <- raster(path, band = k)
    date <- temp@z[[1]] %>% as.Date() %>% gsub('-', '', .) %>% str_sub(., 1, 4)
    fileName <- file.path(outDir, paste0(date, '.RData'))
    if(!file.exists(fileName)){
      val <- temp %>%
        raster::extract(., sh, df = T, na.rm = T, fun = fun) %>%
        data.frame(value = ., stringsAsFactors = F) %>%
        bind_cols(sh@data %>% dplyr::select(matches('REGID')), .) %>%
        as.data.frame() %>% mutate(DATE = as.Date(temp@z[[1]])) %>%
        purrr::set_names('REGID', 'value.ID', 'value', 'DATE') %>%
        dplyr::select(REGID, DATE, value)
      save(val, file = fileName)
      system(paste("echo ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), ' \\| ', temp@z[[1]], collapse = ''))
      rm('temp')
      gc()
    }
  }
}

## ---- Load MAP-layer shapefiles ------------------------------------------
## sh_admin0/1/2 come from the member-state MAP layers (original behaviour).
load(file.path(DIR_MAP_LAYERS, 'sh_admin0.RData'))
load(file.path(DIR_MAP_LAYERS, 'sh_admin1.RData'))
load(file.path(DIR_MAP_LAYERS, 'sh_admin2.RData'))

## Path to the externally supplied WB CCKP wet-bulb (wbt31) annual NetCDF.
path <- file.path(DIR_WETBULB_RAW,
                  'timeseries-wbt31-annual-mean_era5-x0.25_era5-x0.25-historical_timeseries_mean_1950-2023.nc')

## ---- Pass 1: wetbulbtemperature (polygon mean) --------------------------
var <- 'wetbulbtemperature'
for(n in ADMIN_LEVELS){
  sh <- get(paste0('sh_admin', n))
  extractWeatherRegion(path = path, var = var, n = n, fun = mean)
}

## ---- Pass 2: wetbulbdays (polygon max, same source raster) --------------
var <- 'wetbulbdays'
for(n in ADMIN_LEVELS){
  sh <- get(paste0('sh_admin', n))
  extractWeatherRegion(path = path, var = var, n = n, fun = max)
}
