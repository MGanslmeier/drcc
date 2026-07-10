###############################################################################
## build_map_layers.R
##
## Purpose
##   Build the member-state map layers and dissolved per-country border layers
##   used by the Shiny front end, from the three cleaned World Bank admin-level
##   shapefiles. Also dump the raw attribute tables to a metadata workbook.
##
##   For each admin level (0/1/2) the script:
##     * keeps only World Bank "Member State" polygons,
##     * deduplicates to the single largest-area polygon per (NAME, COUNTRY),
##     * simplifies geometry with a level-specific ms_simplify tolerance, and
##     * (admin-2 only) applies a zero-width buffer to repair geometry.
##   It then dissolves each simplified layer by COUNTRY (valid geometries only)
##   into per-country borders.
##
## Inputs (DIR_BOUNDARIES)
##   sh_admin0.RData / sh_admin1.RData / sh_admin2.RData
##     Each contains a single SpatialPolygonsDataFrame named `sh`.
##     @data columns used: REGID, nam_0/nam_1/nam_2, iso_a3, wb_status, st_area_sh.
##
## Outputs
##   DIR_BOUNDARIES/meta.xlsx      raw attribute dump (sheets admin0/admin1/admin2,
##                                 full @data, all columns and rows).
##   DIR_MAP_LAYERS/sh_admin0.RData  object `sh_admin0` (member-state map layer).
##   DIR_MAP_LAYERS/sh_admin1.RData  object `sh_admin1`.
##   DIR_MAP_LAYERS/sh_admin2.RData  object `sh_admin2`.
##   DIR_MAP_LAYERS/admin_iso.RData  object `admin_iso` = list(admin0_iso,
##                                   admin1_iso, admin2_iso) of dissolved borders.
##
## Pipeline position
##   Stage 1 (boundaries). Consumes the cleaned WB shapefiles and produces the
##   map/border layers that later Shiny and wet-bulb extraction stages read.
###############################################################################

source("config.R")

dir.create(DIR_BOUNDARIES, recursive = TRUE, showWarnings = FALSE)
dir.create(DIR_MAP_LAYERS, recursive = TRUE, showWarnings = FALSE)

## ---------------------------------------------------------------------------
## 1. Raw attribute dump -> meta.xlsx
##    Load each raw shapefile and export its full @data (all columns, all rows,
##    including non-Member-States) as one sheet per admin level.
## ---------------------------------------------------------------------------
load(file.path(DIR_BOUNDARIES, "sh_admin0.RData"))
sh_raw0 <- sh
load(file.path(DIR_BOUNDARIES, "sh_admin1.RData"))
sh_raw1 <- sh
load(file.path(DIR_BOUNDARIES, "sh_admin2.RData"))
sh_raw2 <- sh

res <- list(admin0 = sh_raw0@data, admin1 = sh_raw1@data, admin2 = sh_raw2@data)
openxlsx::write.xlsx(res, file = file.path(DIR_BOUNDARIES, "meta.xlsx"))

## ---------------------------------------------------------------------------
## 2. ADMIN-0 map layer
##    Member-State filter + largest-area dedup per (NAME, COUNTRY), then simplify.
##    st_area_sh is carried from the ORIGINAL @data (the lookup carries no area).
## ---------------------------------------------------------------------------
load(file.path(DIR_BOUNDARIES, "sh_admin0.RData"))
sh0 <- sh@data %>% mutate(SHAPEFILE = "0") %>%
  mutate(NAME = paste0(nam_0, " (", iso_a3, ") (admin-0)")) %>%
  mutate(COUNTRY = nam_0) %>%
  subset(., wb_status == "Member State") %>%
  group_by(NAME, COUNTRY) %>% filter(st_area_sh == max(st_area_sh, na.rm = T)) %>%
  dplyr::select(REGID, COUNTRY, SHAPEFILE, NAME)
sh@data <- sh@data %>%
  left_join(., sh0, by = "REGID") %>%
  select(REGID, COUNTRY, SHAPEFILE, NAME, st_area_sh)
sh <- sh %>% subset(., !is.na(COUNTRY)) %>%
  rmapshaper::ms_simplify(., keep = SIMPLIFY_KEEP_MAP["0"], keep_shapes = T)
sh_admin0 <- sh
save(sh_admin0, file = file.path(DIR_MAP_LAYERS, "sh_admin0.RData"))

## ---------------------------------------------------------------------------
## 3. ADMIN-1 map layer
##    NOTE (preserve exactly): the admin-1 lookup carries the group-MAX area as
##    st_area_sh_new, which REPLACES st_area_sh on the join. This asymmetry with
##    admin-0/admin-2 (which keep the original per-polygon area) is intentional.
## ---------------------------------------------------------------------------
load(file.path(DIR_BOUNDARIES, "sh_admin1.RData"))
sh1 <- sh@data %>% mutate(SHAPEFILE = "1") %>%
  mutate(NAME = paste0(nam_1, " (", nam_0, ") (", iso_a3, ") (admin-1)")) %>%
  mutate(COUNTRY = nam_0) %>%
  subset(., wb_status == "Member State") %>%
  group_by(NAME, COUNTRY) %>% filter(st_area_sh == max(st_area_sh, na.rm = T)) %>%
  dplyr::select(REGID, COUNTRY, SHAPEFILE, NAME, st_area_sh_new = st_area_sh)
sh@data <- sh@data %>%
  left_join(., sh1, by = "REGID") %>%
  select(REGID, COUNTRY, SHAPEFILE, NAME, st_area_sh = st_area_sh_new)
sh <- sh %>% subset(., !is.na(COUNTRY)) %>%
  rmapshaper::ms_simplify(., keep = SIMPLIFY_KEEP_MAP["1"], keep_shapes = T)
sh_admin1 <- sh
save(sh_admin1, file = file.path(DIR_MAP_LAYERS, "sh_admin1.RData"))

## ---------------------------------------------------------------------------
## 4. ADMIN-2 map layer
##    Member-State filter + dedup + simplify, then gBuffer(width = 0) to repair
##    geometry. The zero-width buffer is applied at ADMIN-2 ONLY.
##    st_area_sh is carried from the ORIGINAL @data (lookup carries no area).
## ---------------------------------------------------------------------------
load(file.path(DIR_BOUNDARIES, "sh_admin2.RData"))
sh2 <- sh@data %>% mutate(SHAPEFILE = "2") %>%
  mutate(NAME = paste0(nam_2, " (", nam_1, ") (", nam_0, ") (", iso_a3, ") (admin-2)")) %>%
  mutate(COUNTRY = nam_0) %>%
  subset(., wb_status == "Member State") %>%
  group_by(NAME, COUNTRY) %>% filter(st_area_sh == max(st_area_sh, na.rm = T)) %>%
  dplyr::select(REGID, COUNTRY, SHAPEFILE, NAME)
sh@data <- sh@data %>%
  left_join(., sh2, by = "REGID") %>%
  select(REGID, COUNTRY, SHAPEFILE, NAME, st_area_sh)
sh <- sh %>% subset(., !is.na(COUNTRY)) %>%
  rmapshaper::ms_simplify(., keep = SIMPLIFY_KEEP_MAP["2"], keep_shapes = T) %>%
  rgeos::gBuffer(., byid = TRUE, width = 0)
sh_admin2 <- sh
save(sh_admin2, file = file.path(DIR_MAP_LAYERS, "sh_admin2.RData"))

## ---------------------------------------------------------------------------
## 5. Dissolved per-country border layers (admin_iso)
##    Reload the SAVED simplified layers, keep only valid geometries, then
##    st_union per COUNTRY and convert back to sp. Output order: 0, 1, 2.
## ---------------------------------------------------------------------------
load(file.path(DIR_MAP_LAYERS, "sh_admin0.RData"))
temp_sf <- st_as_sf(sh_admin0)
valid_geom <- st_is_valid(temp_sf)
temp_sf <- temp_sf[valid_geom, ]
admin0_iso <- temp_sf %>% dplyr::group_by(COUNTRY) %>%
  dplyr::summarize(geometry = st_union(geometry)) %>% as(., "Spatial")

load(file.path(DIR_MAP_LAYERS, "sh_admin1.RData"))
temp_sf <- st_as_sf(sh_admin1)
valid_geom <- st_is_valid(temp_sf)
temp_sf <- temp_sf[valid_geom, ]
admin1_iso <- temp_sf %>% dplyr::group_by(COUNTRY) %>%
  dplyr::summarize(geometry = st_union(geometry)) %>% as(., "Spatial")

load(file.path(DIR_MAP_LAYERS, "sh_admin2.RData"))
temp_sf <- st_as_sf(sh_admin2)
valid_geom <- st_is_valid(temp_sf)
temp_sf <- temp_sf[valid_geom, ]
admin2_iso <- temp_sf %>% dplyr::group_by(COUNTRY) %>%
  dplyr::summarize(geometry = st_union(geometry)) %>% as(., "Spatial")

admin_iso <- list(admin0_iso, admin1_iso, admin2_iso)
save(admin_iso, file = file.path(DIR_MAP_LAYERS, "admin_iso.RData"))
