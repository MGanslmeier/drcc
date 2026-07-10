###############################################################################
## DRCC pipeline — validation benchmark: extract vs. zonal (admin-2).
##
## Purpose:
##   One-off validation/benchmark confirming that two admin-2 zonal-aggregation
##   methods produce identical per-REGID means on a single raster layer:
##     - Method A (production reference): terra::extract() per polygon.
##     - Method B (proposed optimization): rasterize the polygons ONCE into a
##       REGID raster at the climate grid, then terra::zonal() per layer.
##   Both rely on terra's default centroid-containment pixel-to-polygon
##   assignment, so for non-overlapping polygons their per-REGID means should
##   match within float tolerance. If they do, Method B (5-20x faster) is a
##   safe drop-in for Method A.
##
## Inputs:
##   - DIR_RAW_RASTERS/2m_temperature/2m_temperature_mean_<YEAR>.nc : ERA5 2m
##     mean-temperature stack (one layer per day, values in Kelvin). Only BAND=1
##     is used.
##   - DIR_BOUNDARIES/sh_admin2.RData : World Bank admin-2 shapefile, loaded via
##     load() as object `sh`, each polygon carrying a REGID field.
##
## Outputs (written under DIR_FINAL/validation):
##   - admin2_zonal_vs_extract.RData      : data.frame `cmp` (per-REGID join of
##     value_extract, value_zonal, diff, abs_diff; arranged by REGID).
##   - admin2_zonal_vs_extract_timing.txt : three timing lines
##     (ta_extract_seconds, tb1_rasterize_seconds, tb2_zonal_seconds).
##   - stdout: progress logs, HEAD of cmp, coverage counts, abs_diff summary,
##     exact/within-tolerance match counts, max abs diff, top-10 largest diffs.
##
## Pipeline position:
##   Standalone validation. It does NOT build or write any panel/annual
##   database; a clean rewrite of the database does not depend on its outputs.
##   It only PRINTS the pass criterion — it does not enforce it.
###############################################################################

source("config.R")

suppressMessages({
  library(terra); library(dplyr); library(sf); library(tidyr)
})

# === CONFIG ====================================================================
VALIDATION_YEAR <- 2024L                    # representative year within YEARS
BAND            <- 1L                        # first day of the year (e.g. 2024-01-01)

# Reuse the config-defined source folder and NetCDF filename template so the
# validation reads exactly the same raster the production extraction would.
VAR_2M   <- Filter(function(v) v$name == "2m_temperature", WEATHER_VARS)[[1]]
NC_PATH  <- file.path(DIR_RAW_RASTERS, VAR_2M$src, sprintf(VAR_2M$file, VALIDATION_YEAR))
SHAPEFILE <- file.path(DIR_BOUNDARIES, "sh_admin2.RData")
OUT_DIR   <- file.path(DIR_FINAL, "validation")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# === LOAD ======================================================================
cat("Loading shapefile...\n"); t0 <- Sys.time()
load(SHAPEFILE)                              # brings object `sh` into scope
sh_vect <- vect(sf::st_as_sf(sh))
cat(sprintf("  %d polygons in %.1fs\n",
            nrow(sh_vect), as.numeric(Sys.time() - t0, units = "secs")))

cat(sprintf("Opening NC + selecting layer %d...\n", BAND)); t0 <- Sys.time()
r_full <- rast(NC_PATH)
r1     <- r_full[[BAND]]
cat(sprintf("  ext=[%s] dim=%s in %.1fs\n",
            paste(round(as.vector(ext(r1)), 3), collapse = ","),
            paste(dim(r1), collapse = "x"),
            as.numeric(Sys.time() - t0, units = "secs")))

# === METHOD A: per-polygon extract (production approach) ======================
# Arithmetic mean of pixels whose centroid falls in each polygon, NA dropped.
cat("\n--- METHOD A: terra::extract per polygon ---\n"); t0 <- Sys.time()
ex_a <- terra::extract(r1, sh_vect, fun = mean, na.rm = TRUE, ID = FALSE)
ta <- as.numeric(Sys.time() - t0, units = "secs")
df_a <- data.frame(REGID = sh_vect$REGID, value_extract = ex_a[[1]])
cat(sprintf("  done in %.1fs (%.2f ms per polygon)\n",
            ta, 1000 * ta / nrow(df_a)))

# === METHOD B: rasterize once + zonal ==========================================
cat("\n--- METHOD B: rasterize + terra::zonal ---\n")
cat("Step B1: rasterize polygons -> REGID raster\n"); t0 <- Sys.time()
regid_raster <- terra::rasterize(sh_vect, r1, field = "REGID")
tb1 <- as.numeric(Sys.time() - t0, units = "secs")
n_assigned <- sum(!is.na(values(regid_raster)))
cat(sprintf("  done in %.1fs; %d pixels assigned to a polygon\n",
            tb1, n_assigned))

cat("Step B2: zonal aggregate on this layer\n"); t0 <- Sys.time()
zn <- terra::zonal(r1, regid_raster, fun = "mean", na.rm = TRUE)
tb2 <- as.numeric(Sys.time() - t0, units = "secs")
df_b <- data.frame(REGID = zn[[1]], value_zonal = zn[[2]])
cat(sprintf("  done in %.1fs (returned %d REGIDs)\n", tb2, nrow(df_b)))

cat(sprintf("Method B total (one-time rasterize + per-layer zonal): %.1fs\n",
            tb1 + tb2))

# === COMPARE ===================================================================
cmp <- df_a %>%
  full_join(df_b, by = "REGID") %>%
  arrange(REGID) %>%
  mutate(diff     = value_zonal - value_extract,
         abs_diff = abs(diff))

cat("\n=== HEAD ===\n"); print(head(cmp, 10))

cat("\n=== COVERAGE ===\n")
cat(sprintf("Total REGIDs in shapefile      : %d\n", nrow(sh_vect)))
cat(sprintf("REGIDs covered by extract (non-NA): %d\n",
            sum(!is.na(cmp$value_extract))))
cat(sprintf("REGIDs covered by zonal   (non-NA): %d\n",
            sum(!is.na(cmp$value_zonal))))
cat(sprintf("REGIDs only in extract           : %d\n",
            sum(!is.na(cmp$value_extract) & is.na(cmp$value_zonal))))
cat(sprintf("REGIDs only in zonal             : %d\n",
            sum(is.na(cmp$value_extract) & !is.na(cmp$value_zonal))))

cat("\n=== NUMERIC DIFFERENCES (where both methods have a value) ===\n")
both <- cmp %>% subset(!is.na(value_extract) & !is.na(value_zonal))
print(summary(both$abs_diff))
cat(sprintf("\nMatches exactly       : %d / %d (%.4f%%)\n",
            sum(both$abs_diff == 0), nrow(both),
            100 * mean(both$abs_diff == 0)))
cat(sprintf("Matches within 1e-6 K : %d / %d (%.4f%%)\n",
            sum(both$abs_diff < 1e-6), nrow(both),
            100 * mean(both$abs_diff < 1e-6)))
# Max abs diff is labelled both 'K' and 'degC' using the SAME number: a
# difference in Kelvin equals the same difference in degC (delta invariance),
# not a K->degC conversion.
cat(sprintf("Max abs diff          : %g K (= %g degC)\n",
            max(both$abs_diff), max(both$abs_diff)))

cat("\n=== TOP 10 LARGEST DIFFS ===\n")
print(both %>% arrange(desc(abs_diff)) %>% head(10))

# === SAVE ======================================================================
save(cmp, file = file.path(OUT_DIR, "admin2_zonal_vs_extract.RData"))
writeLines(c(
  sprintf("ta_extract_seconds: %.3f", ta),
  sprintf("tb1_rasterize_seconds: %.3f", tb1),
  sprintf("tb2_zonal_seconds: %.3f", tb2)
), file.path(OUT_DIR, "admin2_zonal_vs_extract_timing.txt"))
cat(sprintf("\nSaved to %s\n", file.path(OUT_DIR, "admin2_zonal_vs_extract.RData")))
