###############################################################################
## DRCC pipeline — Stage 3: merge daily per-region intermediates into panels.
##
## Purpose:
##   Concatenate the per-(admin, variable, year) daily intermediate RData files
##   produced by the extraction stage into merged, wide-by-variable daily
##   weather panels at World Bank admin levels 0/1/2. Unit conversion, +/-Inf ->
##   NA, and negative-precipitation clamping all happen HERE (in the merge), on
##   the compact 3-column long tables before the wide join.
##
## Inputs:
##   DIR_INTERMEDIATE/wb_admin<N>/<var>/<YYYYMM>.RData
##     Each file holds a data.frame `val` whose columns are, positionally,
##     (REGID, DATE, value). Only basenames matching ^[0-9]{6}\.RData$ are read;
##     *_local_fullyear* sanity-check files are ignored.
##   DIR_BOUNDARIES/sh_admin<N>.RData        (primary shapefile attrs)
##   DIR_MAP_LAYERS/sh_admin<N>.RData        (fallback when primary <= 1024 bytes)
##     Only the @data slot is used, joined by REGID. (Consumed only for admin-0
##     in the current control flow.)
##
## Outputs:
##   admin-0: DIR_FINAL/wb_admin0/wb_admin0.RData  (object `df`) + wb_admin0.dta
##            with shapefile @data attributes joined in.
##   admin-1: DIR_FINAL/wb_admin1/wb_admin1_<year>.RData  (object `df`), one per
##            year, REGID-keyed (sh_meta = NULL, no .dta).
##   admin-2: DIR_FINAL/wb_admin2/wb_admin2_<year>.RData  (object `df`), one per
##            year, REGID-keyed, includes total_precipitation_geoMax (no .dta).
##
## Pipeline position:
##   Runs after the zonal extraction stage and before the annual/shiny
##   aggregation stage, which reads all merged .RData panels recursively.
##
## Notes:
##   - DATE lower bound only (>= 1950-01-01); NO upper bound (full range kept).
##   - admin-1 and admin-2 are written per-year because the wide all-years table
##     is too large to dplyr-process in memory on most machines.
###############################################################################

source("config.R")
pacman::p_load(dplyr, purrr, stringr, haven)

## ---- Variable set per level ----------------------------------------------
# VARS_BASE gives the exact left-join order for all levels; total_precipitation_geoMax
# is appended only at admin-2.
vars_for_level <- function(level) {
  if (level == 2L) c(VARS_BASE, VARS_ADMIN2_EXTRA) else VARS_BASE
}

## ---- Helpers -------------------------------------------------------------
# Concatenate all per-variable intermediate RData files under <path> into one
# long (REGID, DATE, <var>) data.frame. If `year_filter` is given, only loads
# files whose basename starts with that 4-digit year (used by the per-year loop
# to avoid loading the whole 1950..now history into RAM at once).
mergeExtractedResults <- function(path, year_filter = NULL) {
  varname <- basename(path)
  files <- list.files(path, recursive = TRUE, full.names = TRUE)
  # Skip locally-re-extracted full-year sanity-check files (they duplicate the
  # canonical per-year files).
  files <- files[!grepl("_local_fullyear", basename(files), fixed = TRUE)]
  # Keep only canonical YYYYMM.RData filenames (6 digits + .RData).
  files <- files[grepl("^[0-9]{6}\\.RData$", basename(files))]
  if (!is.null(year_filter)) {
    files <- files[str_sub(basename(files), 1, 4) == as.character(year_filter)]
  }
  if (length(files) == 0) stop("No intermediate files for ", varname,
                               " under ", path,
                               if (!is.null(year_filter))
                                 sprintf(" (year=%s)", year_filter) else "")

  parts <- vector("list", length(files))
  for (i in seq_along(files)) {
    load(files[i])
    sub <- val %>% subset(DATE >= as.Date("1950-01-01"))
    if (!is.null(year_filter)) {
      sub <- sub %>% subset(str_sub(as.character(DATE), 1, 4) ==
                            as.character(year_filter))
    }
    parts[[i]] <- sub
    rm(val); gc()
  }
  out <- bind_rows(parts) %>%
    arrange(REGID, DATE) %>%
    purrr::set_names("REGID", "DATE", varname)

  # Apply variable-specific transformations while we are still in compact
  # 3-column long format. This avoids doing them later on the multi-billion-cell
  # wide table (which OOMs at admin-1).
  v <- out[[varname]]
  v[is.infinite(v)] <- NA_real_
  if (varname %in% c("2m_temperature", "2m_temperature_max")) {
    # Kelvin -> Celsius, rounded to TEMP_ROUND_DP decimals.
    v <- round(v - KELVIN_OFFSET, TEMP_ROUND_DP)
  }
  if (varname %in% c("total_precipitation", "total_precipitation_geoMax")) {
    neg <- !is.na(v) & v < 0
    v[neg] <- 0
  }
  out[[varname]] <- v
  out
}

# Post-join cleanup: column rename + ordering (+ optional shapefile-attr join).
# For admin-0 sh_meta is the shapefile @data and is joined in; for admin-1/2
# sh_meta is NULL (kept REGID-keyed). Unit conversion / NA cleanup / negative
# clamp are done upstream in mergeExtractedResults, not here.
finalise_df <- function(df, sh_meta, include_geoMax = FALSE) {
  if (!is.null(sh_meta)) df <- df %>% left_join(sh_meta, by = "REGID")
  cols <- c("REGID", "DATE", "t2m_temperature", "t2m_temperature_max",
            "fire_weather_index", "keetch_byram_drought_index",
            "total_precipitation")
  if (include_geoMax) cols <- c(cols, "total_precipitation_geoMax")
  df %>%
    dplyr::rename(t2m_temperature     = `2m_temperature`,
                  t2m_temperature_max = `2m_temperature_max`) %>%
    dplyr::select(all_of(cols), everything())
}

# Load the shapefile @data attribute table for a level. Primary location is
# DIR_BOUNDARIES; fall back to the DIR_MAP_LAYERS copy when the canonical file is
# missing or a 0-byte placeholder (size <= 1024). The object may be named
# `sh` (canonical) or `sh_admin<N>` (map-layers copy).
load_shapefile_attrs <- function(level) {
  e <- new.env()
  primary  <- file.path(DIR_BOUNDARIES, sprintf("sh_admin%d.RData", level))
  fallback <- file.path(DIR_MAP_LAYERS, sprintf("sh_admin%d.RData", level))
  use <- if (file.exists(primary) && file.info(primary)$size > 1024) primary else fallback
  load(use, envir = e)
  obj_name <- if ("sh" %in% ls(e)) "sh" else sprintf("sh_admin%d", level)
  e[[obj_name]]@data
}

## ---- Admin-0: all-years single output ------------------------------------
merge_level_single <- function(level) {
  cat(sprintf("\n############# ADMIN-%d #############\n", level))
  sh_meta <- load_shapefile_attrs(level)
  in_dir  <- file.path(DIR_INTERMEDIATE, sprintf("wb_admin%d", level))

  vars_here <- vars_for_level(level)
  # Incremental join: hold only the wide df + the variable being joined at any
  # time, instead of all long data.frames at once.
  cat(sprintf("  joining %d variables incrementally...\n", length(vars_here)))
  df <- mergeExtractedResults(file.path(in_dir, vars_here[1]))
  cat(sprintf("    [%d/%d] %s loaded (%d rows)\n",
              1L, length(vars_here), vars_here[1], nrow(df)))
  for (i in seq_along(vars_here)[-1]) {
    v <- vars_here[i]
    this_var <- mergeExtractedResults(file.path(in_dir, v))
    df <- left_join(df, this_var, by = c("REGID", "DATE"))
    rm(this_var); gc()
    cat(sprintf("    [%d/%d] %s joined (df %d rows, %d cols)\n",
                i, length(vars_here), v, nrow(df), ncol(df)))
  }
  df <- arrange(df, REGID, DATE)

  df <- finalise_df(df, sh_meta = sh_meta,
                    include_geoMax = "total_precipitation_geoMax" %in% vars_here)

  cat(sprintf("  rows=%d  REGIDs=%d  DATE %s..%s\n",
              nrow(df), length(unique(df$REGID)),
              as.character(min(df$DATE)), as.character(max(df$DATE))))

  out_dir <- file.path(DIR_FINAL, sprintf("wb_admin%d", level))
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  out_rdata <- file.path(out_dir, sprintf("wb_admin%d.RData", level))
  out_dta   <- file.path(out_dir, sprintf("wb_admin%d.dta", level))
  save(df, file = out_rdata)
  haven::write_dta(df, out_dta)
  cat(sprintf("  SAVED %s\n  SAVED %s\n", out_rdata, out_dta))
  rm(df); gc()
}

## ---- Admin-1 / Admin-2: one output file per year -------------------------
# Used for both admin-1 and admin-2 because the wide all-years table is too
# large to dplyr-process in memory on most machines. Downstream code reads all
# .RData under DIR_FINAL recursively, so it doesn't care whether a level is one
# file or many.
merge_level_per_year <- function(level) {
  cat(sprintf("\n############# ADMIN-%d (per-year) #############\n", level))
  in_dir  <- file.path(DIR_INTERMEDIATE, sprintf("wb_admin%d", level))
  out_dir <- file.path(DIR_FINAL, sprintf("wb_admin%d", level))
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  vars_here <- vars_for_level(level)

  # Discover which years exist on disk (the union across variables).
  years_seen <- c()
  for (v in vars_here) {
    fs <- list.files(file.path(in_dir, v), full.names = FALSE)
    # Only count canonical YYYYMM.RData files, ignoring _local_fullyear etc.
    fs <- fs[grepl("^[0-9]{6}\\.RData$", fs)]
    years_seen <- union(years_seen, as.integer(str_sub(fs, 1, 4)))
  }
  years_seen <- sort(unique(years_seen[!is.na(years_seen)]))
  cat(sprintf("Admin-%d years on disk: %s..%s\n",
              level, min(years_seen), max(years_seen)))

  for (year in years_seen) {
    out_path <- file.path(out_dir, sprintf("wb_admin%d_%d.RData", level, year))
    # Skip years that already have a non-empty output (allows resuming).
    if (file.exists(out_path) && file.info(out_path)$size > 1024) {
      cat(sprintf("\n--- admin-%d | %d --- (SKIP: already %.1f MB)\n",
                  level, year, file.info(out_path)$size / 1e6))
      next
    }
    cat(sprintf("\n--- admin-%d | %d ---\n", level, year))
    df <- lapply(vars_here, function(v)
      mergeExtractedResults(file.path(in_dir, v), year_filter = year)) %>%
      reduce(left_join, by = c("REGID", "DATE")) %>%
      arrange(REGID, DATE)

    df <- finalise_df(df, sh_meta = NULL,
                      include_geoMax = "total_precipitation_geoMax" %in% vars_here)

    save(df, file = out_path)
    cat(sprintf("  SAVED %s  (rows=%d, REGIDs=%d)\n",
                out_path, nrow(df), length(unique(df$REGID))))
    rm(df); gc()
  }
}

## ---- Run driver ----------------------------------------------------------
# Restrict which levels to run via the env var MERGE_LEVELS, e.g.:
#   MERGE_LEVELS=1,2 Rscript merge_daily_panels.R
# (used to re-run only admin-1/admin-2 after admin-0 has succeeded once).
levels_to_run <- ADMIN_LEVELS
.lvls <- Sys.getenv("MERGE_LEVELS")
if (nzchar(.lvls)) {
  levels_to_run <- as.integer(strsplit(.lvls, ",")[[1]])
  cat(sprintf("Overridden ADMIN_LEVELS via env: %s\n",
              paste(levels_to_run, collapse = ",")))
}

for (level in levels_to_run) {
  out <- try({
    # admin-0 fits comfortably as a single file. admin-1 and admin-2 are too
    # large for single-file dplyr operations, so they are saved per-year.
    if (level == 0L) merge_level_single(0L) else merge_level_per_year(level)
  }, silent = FALSE)
  if (inherits(out, "try-error")) {
    cat(sprintf("\n*** admin-%d FAILED, continuing to next level ***\n", level))
  }
}

cat("\nAll done.\n")
