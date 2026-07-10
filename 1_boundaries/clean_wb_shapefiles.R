###############################################################################
## clean_wb_shapefiles.R
##
## Purpose:
##   Load the three raw World Bank admin-level shapefiles (ADM0/1/2), repair
##   admin-0 geometry with a zero-width buffer, assign a numeric REGID derived
##   from globalid, and save full-resolution RData copies. Then produce
##   geometrically simplified (mapshaper Douglas-Peucker) copies for downstream
##   zonal extraction.
##
## Inputs:
##   DIR_BOUNDARIES_RAW/admin0  (layer WB_GAD_ADM0)  raw admin-0 (country) polygons
##   DIR_BOUNDARIES_RAW/admin1  (layer WB_GAD_ADM1)  raw admin-1 (province) polygons
##   DIR_BOUNDARIES_RAW/admin2  (layer WB_GAD_ADM2)  raw admin-2 (district) polygons
##
## Outputs:
##   DIR_BOUNDARIES/sh_admin{0,1,2}.RData          full-resolution SPDF (object `sh`)
##   DIR_BOUNDARIES_REDUCED/sh_admin{0,1,2}.RData  simplified SPDF (object `sh`)
##
## Pipeline position:
##   First boundaries stage. The full-resolution copies feed the map-layer
##   builder; the simplified copies feed the zonal weather extraction stages.
##
## Quirks preserved exactly:
##   - gBuffer(byid=TRUE, width=0) is applied to ADMIN-0 ONLY; admin-1/2 raw.
##   - REGID = as.numeric(as.factor(globalid)): 1-based integer keyed to the
##     lexicographic sort order of globalid strings, NOT the shapefile row order.
##   - The globalid uniqueness check is a printed boolean only (not stopifnot);
##     execution never halts.
##   - dplyr::select(REGID, everything()) only reorders columns (REGID first).
##   - The saved object is always named `sh`; simplified copies are re-loaded
##     from the full-resolution saves, so simplification applies to the
##     REGID-augmented (and admin-0-buffered) geometries.
###############################################################################

source("config.R")

dir.create(DIR_BOUNDARIES, recursive = TRUE, showWarnings = FALSE)
dir.create(DIR_BOUNDARIES_REDUCED, recursive = TRUE, showWarnings = FALSE)

## ---------------------------------------------------------------------------
## Full-resolution: load, add REGID, save
## ---------------------------------------------------------------------------

# ADMIN-0 (zero-width buffer applied here ONLY)
sh <- readOGR(dsn = file.path(DIR_BOUNDARIES_RAW, "admin0"), layer = "WB_GAD_ADM0")
sh <- sh %>% gBuffer(byid = TRUE, width = 0)
message(sh@data$globalid %>% unique() %>% length() == length(sh))
sh@data <- sh@data %>%
  mutate(REGID = globalid %>% as.factor() %>% as.numeric()) %>%
  dplyr::select(REGID, everything())
save(sh, file = file.path(DIR_BOUNDARIES, "sh_admin0.RData"))

# ADMIN-1 (no gBuffer)
sh <- readOGR(dsn = file.path(DIR_BOUNDARIES_RAW, "admin1"), layer = "WB_GAD_ADM1")
message(sh@data$globalid %>% unique() %>% length() == length(sh))
sh@data <- sh@data %>%
  mutate(REGID = globalid %>% as.factor() %>% as.numeric()) %>%
  dplyr::select(REGID, everything())
save(sh, file = file.path(DIR_BOUNDARIES, "sh_admin1.RData"))

# ADMIN-2 (no gBuffer)
sh <- readOGR(dsn = file.path(DIR_BOUNDARIES_RAW, "admin2"), layer = "WB_GAD_ADM2")
message(sh@data$globalid %>% unique() %>% length() == length(sh))
sh@data <- sh@data %>%
  mutate(REGID = globalid %>% as.factor() %>% as.numeric()) %>%
  dplyr::select(REGID, everything())
save(sh, file = file.path(DIR_BOUNDARIES, "sh_admin2.RData"))

## ---------------------------------------------------------------------------
## Simplified copies (Douglas-Peucker via rmapshaper::ms_simplify)
## Re-load each full-resolution save and simplify with identical parameters.
## ---------------------------------------------------------------------------

load(file.path(DIR_BOUNDARIES, "sh_admin0.RData"))
sh <- ms_simplify(sh, keep = SIMPLIFY_KEEP_REDUCED, method = 'dp', keep_shapes = TRUE)
save(sh, file = file.path(DIR_BOUNDARIES_REDUCED, "sh_admin0.RData"))

load(file.path(DIR_BOUNDARIES, "sh_admin1.RData"))
sh <- ms_simplify(sh, keep = SIMPLIFY_KEEP_REDUCED, method = 'dp', keep_shapes = TRUE)
save(sh, file = file.path(DIR_BOUNDARIES_REDUCED, "sh_admin1.RData"))

load(file.path(DIR_BOUNDARIES, "sh_admin2.RData"))
sh <- ms_simplify(sh, keep = SIMPLIFY_KEEP_REDUCED, method = 'dp', keep_shapes = TRUE)
save(sh, file = file.path(DIR_BOUNDARIES_REDUCED, "sh_admin2.RData"))
