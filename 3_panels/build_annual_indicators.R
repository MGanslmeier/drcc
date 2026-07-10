###############################################################################
## build_annual_indicators.R  —  DRCC pipeline, stage 3 (derived indicators)
##
## PURPOSE
##   Reads the merged daily per-polygon panels, aggregates each to
##   (REGID, year), derives the heat / cold / flood day counts and the two
##   heat indices, reshapes to a long annual-indicator table (SHINY_TS),
##   re-attaches the externally supplied wet-bulb rows, and writes the
##   decadal per-admin-level map datasets.
##
## INPUTS
##   DIR_FINAL/**/*.RData        Daily per-polygon merged panels. Each file
##                               loads an object `df` with columns REGID,
##                               DATE (daily date), t2m_temperature,
##                               t2m_temperature_max, fire_weather_index,
##                               keetch_byram_drought_index, total_precipitation
##                               and (admin-2 only) total_precipitation_geoMax.
##                               Files matching 'SHINY|shapefiles' are dropped
##                               and files <= 1024 bytes (stale placeholders)
##                               are skipped.
##   DIR_MAP_LAYERS/sh_admin0/1/2.RData   SpatialPolygonsDataFrame objects; only
##                               the @data slots are used (REGID, NAME, COUNTRY,
##                               SHAPEFILE) for the region attribute join.
##   WETBULB_TS_RDATA (optional) Externally supplied wet-bulb annual-indicator
##                               table. Rows whose Indicator is in
##                               WETBULB_INDICATORS (wetbulbdays, wbt27,
##                               wetbulbtemperature) are carried through verbatim
##                               — they are NOT recomputed by this ERA5/CEMS
##                               branch of the pipeline. If the file is absent
##                               the wet-bulb rows are simply omitted.
##
## OUTPUTS
##   DIR_SHINY/SHINY_TS.RData         Long-format annual-indicator table `df`.
##   DIR_MAP_LAYERS/SHINY_admin0.RData  `df_admin0`: decadal subset, SHAPEFILE 0.
##   DIR_MAP_LAYERS/SHINY_admin1.RData  `df_admin1`: decadal subset, SHAPEFILE 1.
##   DIR_MAP_LAYERS/SHINY_admin2.RData  `df_admin2`: decadal subset, SHAPEFILE 2.
##
## PIPELINE POSITION
##   Runs after the daily-panel merge and before the published annual-file
##   builder. Consumes DIR_FINAL, produces the SHINY long table + map datasets.
##
## PRESERVED QUIRKS (define the published data — do not "fix")
##   - MONTH bug: DATE is overwritten with the integer year BEFORE MONTH is
##     derived via str_sub(DATE, 1, 7), so MONTH equals the year string. The
##     two-step sd therefore collapses to a plain annual sd of daily
##     t2m_temperature.
##   - heat_index_pca (prcomp center+scale, PC1) and heat_index_mean
##     (per-var min-max rescale) are computed PER FILE (hence per-year for
##     admin-1/2) before annual aggregation, then annually averaged. PC1 sign
##     is arbitrary and only direction-comparable within a year.
##   - Per-variable aggregation is exact: SUM (precip, heat/cold/flood days),
##     MEAN (t2m mean, both heat indices), MAX (t2m max, fire, drought), SD.
##   - Strict > / < thresholds; flood conversion factor is exactly *24*1000.
##   - Wet-bulb rows (incl. wbt27) come from WETBULB_TS_RDATA, not from here.
###############################################################################

source("config.R")

# The 4 variables feeding both heat indices; column names carry the merged-panel
# 't2m_' prefix (HEAT_VARS in config), not the raw raster names.
heat_vars <- HEAT_VARS

# === STAGE 1 — read daily panels, aggregate to (REGID, year) ==================
res <- data.frame(stringsAsFactors = FALSE)
files <- list.files(DIR_FINAL, full.names = TRUE, recursive = TRUE) %>%
  subset(., grepl('\\.RData$', .)) %>%
  subset(., !grepl('SHINY|shapefiles', .))
# Skip stale placeholder files (empty wb_admin1/wb_admin2 left by prior merges).
files <- files[file.info(files)$size > 1024]
cat(sprintf("Processing %d input files\n", length(files)))

for (i in seq_along(files)) {
  load(files[i])
  is_admin2 <- grepl('wb_admin2', files[i])

  # Per-file daily frame: drop days with any NA, then derive daily quantities.
  # NOTE: DATE is overwritten with the year FIRST, so MONTH (str_sub 1:7) is the
  # year string, not YYYY-MM (preserved bug; see header).
  temp <- df %>%
    subset(., complete.cases(.)) %>%
    mutate(DATE = year(DATE),
           MONTH = str_sub(DATE, 1, 7),
           SHAPEFILE = gsub('\\.RData|wb\\_admin', '', basename(files[i]))) %>%
    mutate(heat_index_pca = prcomp(.[, heat_vars], center = TRUE, scale = TRUE,
                                   rank. = 1)[["x"]] %>% as.numeric()) %>%
    mutate(heat_index_mean = 0.25 * (
      scales::rescale(t2m_temperature, c(0, 1)) +
      scales::rescale(t2m_temperature_max, c(0, 1)) +
      scales::rescale(fire_weather_index, c(0, 1)) +
      scales::rescale(keetch_byram_drought_index, c(0, 1)))) %>%
    mutate(heat_days = as.numeric(t2m_temperature_max > HEAT_DAY_THRESHOLD),
           cold_days = as.numeric(t2m_temperature_max < COLD_DAY_THRESHOLD))
  rm(df); gc()

  # Admin-2 only: heavy-rain day flags (geoMax hourly metres -> mm/day).
  # Keep the exact two-step "* 24 * 1000" multiplication order: folding it into a
  # single 24000 factor changes float rounding and can flip a strict > flag.
  if (is_admin2) {
    temp <- temp %>%
      mutate(flood_days50 = as.numeric(total_precipitation_geoMax * 24 * 1000 > FLOOD_MM_PER_DAY[["50"]]),
             flood_days20 = as.numeric(total_precipitation_geoMax * 24 * 1000 > FLOOD_MM_PER_DAY[["20"]]))
  }

  # sd stage: two-step group_by (monthly-then-annual by intent), but because
  # MONTH == year the first group already spans the whole year, so this is the
  # yearly sd of daily t2m_temperature.
  temp1 <- temp %>%
    group_by(REGID, DATE, MONTH, SHAPEFILE) %>%
    dplyr::summarize(sd_t2m_temperature = sd(t2m_temperature, na.rm = TRUE),
                     .groups = 'drop') %>%
    group_by(REGID, DATE, SHAPEFILE) %>%
    dplyr::summarize(sd_t2m_temperature = mean(sd_t2m_temperature, na.rm = TRUE),
                     .groups = 'drop')

  temp2 <- temp %>%
    group_by(REGID, DATE, SHAPEFILE) %>%
    dplyr::summarize(
      total_precipitation             = sum(total_precipitation, na.rm = TRUE),
      mean_t2m_temperature            = mean(t2m_temperature, na.rm = TRUE),
      max_t2m_temperature_max         = max(t2m_temperature_max, na.rm = TRUE),
      heat_days                       = sum(heat_days, na.rm = TRUE),
      cold_days                       = sum(cold_days, na.rm = TRUE),
      max_fire_weather_index          = max(fire_weather_index, na.rm = TRUE),
      max_keetch_byram_drought_index  = max(keetch_byram_drought_index, na.rm = TRUE),
      heat_index_pca                  = mean(heat_index_pca, na.rm = TRUE),
      heat_index_mean                 = mean(heat_index_mean, na.rm = TRUE),
      .groups = 'drop')

  if (is_admin2) {
    temp3 <- temp %>%
      group_by(REGID, DATE, SHAPEFILE) %>%
      dplyr::summarize(flood_days50 = sum(flood_days50, na.rm = TRUE),
                       flood_days20 = sum(flood_days20, na.rm = TRUE),
                       .groups = 'drop')
    temp2 <- left_join(temp2, temp3, by = c('REGID', 'DATE', 'SHAPEFILE'))
  }

  res <- temp2 %>%
    left_join(., temp1, by = c('REGID', 'DATE', 'SHAPEFILE')) %>%
    bind_rows(res, .)
  rm(temp, temp1, temp2); if (is_admin2) rm(temp3); gc()
  cat(sprintf("  [%3d/%d] %s -> res rows=%d\n",
              i, length(files), basename(files[i]), nrow(res)))
}

# === STAGE 2 — attach region attributes & reshape to long =====================
load(file.path(DIR_MAP_LAYERS, 'sh_admin0.RData'))
load(file.path(DIR_MAP_LAYERS, 'sh_admin1.RData'))
load(file.path(DIR_MAP_LAYERS, 'sh_admin2.RData'))

sh <- sh_admin0@data %>% bind_rows(sh_admin1@data) %>% bind_rows(sh_admin2@data)
df_new <- res %>%
  mutate(SHAPEFILE = str_sub(SHAPEFILE, 1, 1)) %>%
  arrange(SHAPEFILE, REGID, DATE) %>%
  left_join(., sh, by = c('REGID', 'SHAPEFILE')) %>%
  subset(., !is.na(NAME)) %>%
  dplyr::select(REGID, NAME, COUNTRY, SHAPEFILE, DATE, everything()) %>%
  gather(., Indicator, Value, -c(REGID, DATE, SHAPEFILE, NAME, COUNTRY))
cat(sprintf("df_new rows=%d  (indicators=%d, regions=%d, years=%d)\n",
            nrow(df_new), length(unique(df_new$Indicator)),
            length(unique(df_new$REGID)),
            length(unique(df_new$DATE))))

# === STAGE 3 — re-attach externally supplied wet-bulb rows ====================
# Strip any wet-bulb indicators produced upstream, then re-insert the verbatim
# wet-bulb rows (incl. wbt27) from the external WETBULB_TS_RDATA table. If that
# table is absent the wet-bulb indicators are simply omitted.
df_new <- df_new %>% subset(., !Indicator %in% WETBULB_INDICATORS)
if (file.exists(WETBULB_TS_RDATA)) {
  cat("Attaching wet-bulb rows from WETBULB_TS_RDATA...\n")
  e <- new.env(); load(WETBULB_TS_RDATA, envir = e)
  df_wb <- e$df %>% subset(., Indicator %in% WETBULB_INDICATORS)
  cat(sprintf("  wet-bulb rows: %d (years %s..%s)\n",
              nrow(df_wb),
              as.character(min(df_wb$DATE)),
              as.character(max(df_wb$DATE))))
  df <- bind_rows(df_new, df_wb)
  rm(e, df_wb)
} else {
  cat("WETBULB_TS_RDATA not found; saving without wet-bulb indicators.\n")
  df <- df_new
}
rm(df_new); gc()
cat(sprintf("FINAL df rows=%d\n", nrow(df)))

# === STAGE 4 — save SHINY_TS long table =======================================
dir.create(DIR_SHINY, recursive = TRUE, showWarnings = FALSE)
save(df, file = file.path(DIR_SHINY, 'SHINY_TS.RData'))
cat("SAVED SHINY_TS.RData\n")

# === STAGE 5 — decadal per-admin-level map datasets ===========================
# DATE -> YEAR; keep only decadal + recent years; complete.cases drops NA-Value
# long rows (e.g. the NA flood rows carried by admin-0/1).
dir.create(DIR_MAP_LAYERS, recursive = TRUE, showWarnings = FALSE)

df_admin0 <- df %>% dplyr::rename(YEAR = DATE) %>%
  subset(., SHAPEFILE == 0 & complete.cases(.)) %>%
  subset(., YEAR %in% DECADAL_YEARS)
save(df_admin0, file = file.path(DIR_MAP_LAYERS, 'SHINY_admin0.RData'))
cat(sprintf("SAVED SHINY_admin0.RData (rows=%d)\n", nrow(df_admin0)))

df_admin1 <- df %>% dplyr::rename(YEAR = DATE) %>%
  subset(., SHAPEFILE == 1 & complete.cases(.)) %>%
  subset(., YEAR %in% DECADAL_YEARS)
save(df_admin1, file = file.path(DIR_MAP_LAYERS, 'SHINY_admin1.RData'))
cat(sprintf("SAVED SHINY_admin1.RData (rows=%d)\n", nrow(df_admin1)))

df_admin2 <- df %>% dplyr::rename(YEAR = DATE) %>%
  subset(., SHAPEFILE == 2 & complete.cases(.)) %>%
  subset(., YEAR %in% DECADAL_YEARS)
save(df_admin2, file = file.path(DIR_MAP_LAYERS, 'SHINY_admin2.RData'))
cat(sprintf("SAVED SHINY_admin2.RData (rows=%d)\n", nrow(df_admin2)))

cat("\nAll done.\n")
