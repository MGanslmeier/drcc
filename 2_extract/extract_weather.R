###############################################################################
## extract_weather.R  —  DRCC pipeline, stage 2 (extraction)
##
## PURPOSE
##   Zonal (per-polygon) extraction of the daily ERA5/CEMS climate rasters onto
##   the World Bank admin boundaries. Produces one RData panel per
##   (admin level, weather variable, year), storing RAW values with a
##   per-variable mean/max spatial aggregation.
##
## INPUTS
##   DIR_RAW_RASTERS/<src>/<file>.nc
##       One annual NetCDF per (variable, year); one layer per day of year.
##       Temperature in Kelvin, precipitation as daily totals in metres.
##       ERA5 grids span -180..180; CEMS grids span 0..360.
##   DIR_BOUNDARIES/sh_admin<N>.RData
##       Full-resolution WB boundaries: an sp object `sh` whose @data has REGID
##       (all levels) and sovereign (used only at admin-2). Both are produced
##       upstream; this script only reads them.
##
## OUTPUTS
##   DIR_INTERMEDIATE/wb_admin<N>/<var>/<YYYY>01.RData
##       A single data.frame `val` with columns REGID, DATE, value (raw units),
##       arranged by (REGID, DATE). The filename is sprintf('%d01.RData', year),
##       i.e. the year followed by a literal '01' (e.g. 195001.RData).
##       total_precipitation_geoMax is a distinct output folder even though it
##       reads the same source raster as total_precipitation.
##
## PIPELINE POSITION
##   Runs after the raster download / boundary-prep stages and before the daily
##   merge (stage 3), which is where K->degC conversion, rounding and any Inf /
##   negative handling happen. Nothing of that kind is applied here.
##
## AGGREGATION (per WEATHER_VARS$fun; preserve exactly)
##   2m_temperature, 2m_temperature_max, total_precipitation -> zonal MEAN
##     (2m_temperature_max is the zonal MEAN of the daily-maximum grid)
##   total_precipitation_geoMax, fire_weather_index, keetch_byram_drought_index
##     -> zonal MAX
##
## PARALLELISM
##   The (variable x year) grid within each admin level runs on a PSOCK cluster
##   of N_PARALLEL_PER_LEVEL workers. PSOCK (fresh R processes) is used because
##   terra/sf C++ pointers do not survive a fork; every worker independently
##   re-loads its boundary shapefile and rebuilds its SpatVector. Set a level to
##   1 to run it serially.
##
## Re-runs are safe: any (admin, var, year) whose output already exists is
## skipped, and a missing source NC is skipped (not an error).
###############################################################################

source("config.R")
pacman::p_load(terra, dplyr, sf, lubridate, parallel)

## ---- Extraction settings -------------------------------------------------
# How many (var, year) jobs to run concurrently per admin level. Higher = faster
# but more peak RAM. Each PSOCK worker holds one annual NC plus terra working
# memory, so raise with care on a laptop.
N_PARALLEL_PER_LEVEL <- c(`0` = 5L, `1` = 5L, `2` = 5L)

## ---- Helpers -------------------------------------------------------------

# Gregorian leap-year day count.
days_in_year <- function(year) {
  is_leap <- (year %% 4 == 0) && (year %% 100 != 0 | year %% 400 == 0)
  if (is_leap) 366L else 365L
}

# Load the full-resolution boundary shapefile for an admin level and return the
# sp object `sh`. Re-loaded per job so no sp/terra pointer crosses the worker
# process boundary.
load_shapefile <- function(level) {
  path <- file.path(DIR_BOUNDARIES, sprintf("sh_admin%d.RData", level))
  e <- new.env()
  load(path, envir = e)
  e$sh
}

# Batch extract a full-year raster over an entire SpatVector in one call. Used
# for admin-0 and admin-1, where the polygon count is small enough to fit.
# `ex` is (polys x days); as.matrix flattens column-major so polygon varies
# fastest within each day, matching the rep() patterns below.
extract_year_batch <- function(r, sh_vect, regids, dates, agg, tag = "") {
  n_days <- nlyr(r)
  t0 <- Sys.time()
  ex <- terra::extract(r, sh_vect, fun = agg, na.rm = TRUE, ID = FALSE)
  cat(sprintf("%s extracted %d polys x %d days (batch) in %.1fs\n",
              tag, nrow(ex), ncol(ex),
              as.numeric(Sys.time() - t0, units = "secs")))
  data.frame(
    REGID = rep(regids, times = n_days),
    DATE  = rep(dates, each = nrow(ex)),
    value = as.numeric(as.matrix(ex)),
    stringsAsFactors = FALSE
  )
}

# Per-sovereign loop for admin-2: subset polygons by `sovereign`, crop the
# raster to a buffered bbox of that subset (buffer defines the crop window
# ONLY — extraction runs on the unbuffered polygons), then batch-extract.
# NA-sovereign polygons are kept as one final group so none are dropped.
extract_year_admin2 <- function(r, sh, dates, agg, tag = "") {
  stopifnot("sovereign" %in% names(sh@data))
  sov_vec    <- sh@data$sovereign
  na_present <- any(is.na(sov_vec))
  sovereigns <- sort(unique(sov_vec[!is.na(sov_vec)]))
  loop_keys  <- c(sovereigns, if (na_present) NA_character_ else character(0))
  cat(sprintf("%s admin-2 per-sovereign loop: %d sovereigns%s\n",
              tag, length(sovereigns),
              if (na_present) " (+1 group for NA-sovereign polygons)" else ""))

  parts <- vector("list", length(loop_keys))
  t0 <- Sys.time()
  for (i in seq_along(loop_keys)) {
    sov <- loop_keys[i]
    idx <- if (is.na(sov)) which(is.na(sov_vec)) else which(sov_vec == sov)
    if (length(idx) == 0) next

    sh_temp <- sh[idx, ]
    sh_t    <- vect(sf::st_as_sf(sh_temp))
    sh_buf  <- terra::buffer(sh_t, width = ADMIN2_BUFFER_M)
    r_crop  <- terra::crop(r, sh_buf)

    ex <- terra::extract(r_crop, sh_t, fun = agg, na.rm = TRUE, ID = FALSE)
    parts[[i]] <- data.frame(
      REGID = rep(sh_temp@data$REGID, times = nlyr(r_crop)),
      DATE  = rep(dates, each = nrow(ex)),
      value = as.numeric(as.matrix(ex)),
      stringsAsFactors = FALSE
    )

    if (i %% 10 == 0 || i == length(loop_keys)) {
      elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
      eta     <- elapsed / i * (length(loop_keys) - i)
      cat(sprintf("%s   %3d/%d groups (%.0fs elapsed, ~%.0fs remaining)\n",
                  tag, i, length(loop_keys), elapsed, eta))
    }
  }
  bind_rows(parts)
}

# Per-layer rotate for 0..360 grids (CEMS): rebuild the stack with each layer
# rotated individually. Required because terra's multi-layer rotate() silently
# drops data for layers > 1 on these files.
rotated_per_layer <- function(r) {
  rast(lapply(seq_len(nlyr(r)), function(k) rotate(r[[k]])))
}

# Single (admin, var, year) job. Self-contained for use in a PSOCK worker — the
# SpatVector is rebuilt inside from the freshly loaded `sh`.
extract_one <- function(spec, year, level, sh) {
  tag <- sprintf("[%s|%d]", spec$name, year)
  agg <- base::get(spec$fun)

  nc_path  <- file.path(DIR_RAW_RASTERS, spec$src, sprintf(spec$file, year))
  out_dir  <- file.path(DIR_INTERMEDIATE, sprintf("wb_admin%d", level), spec$name)
  out_path <- file.path(out_dir, sprintf("%d01.RData", year))

  cat(sprintf("\n=== admin-%d | %s | %d (fun=%s) ===\n",
              level, spec$name, year, spec$fun))

  if (!file.exists(nc_path)) {
    cat(sprintf("%s SKIP - NC not yet downloaded: %s\n", tag, nc_path))
    return(invisible(NULL))
  }
  if (file.exists(out_path)) {
    cat(sprintf("%s SKIP - output already exists: %s\n", tag, out_path))
    return(invisible(NULL))
  }
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  cat(sprintf("%s reading %s (%.0f MB)\n",
              tag, nc_path, file.info(nc_path)$size / 1e6))
  r <- rast(nc_path)
  n_days <- nlyr(r)
  e <- as.vector(ext(r))
  cat(sprintf("%s layers=%d dim=%s ext=[%s]\n",
              tag, n_days, paste(dim(r), collapse = "x"),
              paste(round(e, 3), collapse = ",")))

  # Day count is advisory only: dates always start Jan 1 and run one per layer.
  expected <- days_in_year(year)
  if (n_days != expected) {
    cat(sprintf("%s WARN - expected %d days, found %d\n", tag, expected, n_days))
  }
  dates <- as.Date(paste0(year, "-01-01")) + 0:(n_days - 1)

  if (e["xmax"] > 180) {
    cat(sprintf("%s grid 0..360 -> per-layer rotate\n", tag))
    r <- rotated_per_layer(r)
  }

  val <- if (level == 2L) {
    extract_year_admin2(r, sh, dates, agg, tag = tag)
  } else {
    sh_vect <- vect(sf::st_as_sf(sh))
    extract_year_batch(r, sh_vect, sh@data$REGID, dates, agg, tag = tag)
  }
  val <- val %>% arrange(REGID, DATE)

  save(val, file = out_path)
  cat(sprintf("%s SAVED %s (%d rows, %d REGIDs, %d dates)\n",
              tag, basename(out_path), nrow(val),
              length(unique(val$REGID)), length(unique(val$DATE))))
  invisible(NULL)
}

# One job, run serially or inside a PSOCK worker. Re-loads the shapefile from
# disk every call (terra/sp pointers do not survive the process boundary) and
# catches per-job errors so a single failure never aborts the run.
run_one_job <- function(j, jobs, level) {
  spec <- WEATHER_VARS[[jobs$spec_idx[j]]]
  year <- jobs$year[j]
  tryCatch({
    sh <- load_shapefile(level)
    extract_one(spec, year, level, sh)
  }, error = function(err) {
    cat(sprintf("[%s|%d] FAILED: %s\n",
                spec$name, year, conditionMessage(err)))
  })
}

## ---- Main loop -----------------------------------------------------------
for (level in ADMIN_LEVELS) {
  cat(sprintf("\n############# ADMIN-%d #############\n", level))

  # One-time inspection (parent process only).
  sh_inspect <- load_shapefile(level)
  stopifnot("REGID" %in% names(sh_inspect@data))
  cat(sprintf("Shapefile sh_admin%d: %d polygons | REGID range %s..%s\n",
              level, length(sh_inspect),
              min(sh_inspect@data$REGID), max(sh_inspect@data$REGID)))
  rm(sh_inspect); gc()

  jobs <- expand.grid(spec_idx = seq_along(WEATHER_VARS), year = YEARS,
                      KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)
  n_par <- as.integer(N_PARALLEL_PER_LEVEL[as.character(level)])
  if (is.na(n_par) || n_par < 1L) n_par <- 1L
  cat(sprintf("Running %d jobs with n_par=%d\n", nrow(jobs), n_par))

  if (n_par > 1L) {
    cl <- parallel::makeCluster(n_par, type = "PSOCK", outfile = "")
    on.exit(parallel::stopCluster(cl), add = TRUE)

    parallel::clusterExport(cl, c(
      "WEATHER_VARS", "DIR_RAW_RASTERS", "DIR_INTERMEDIATE", "DIR_BOUNDARIES",
      "ADMIN2_BUFFER_M", "load_shapefile", "extract_one", "extract_year_batch",
      "extract_year_admin2", "rotated_per_layer", "days_in_year",
      "run_one_job", "jobs", "level"
    ), envir = globalenv())

    parallel::clusterEvalQ(cl, {
      suppressMessages({
        library(terra); library(dplyr); library(sf); library(lubridate)
      })
    })

    parallel::parLapply(cl, seq_len(nrow(jobs)), function(j) {
      run_one_job(j, jobs, level)
    })

    parallel::stopCluster(cl)
    on.exit()
  } else {
    lapply(seq_len(nrow(jobs)), function(j) run_one_job(j, jobs, level))
  }
}

cat("\nAll done.\n")
