###############################################################################
## Split the annual SHINY_TS panel into per-admin-level annual files.
##
## Purpose:
##   Load the pre-built long-format annual panel (SHINY_TS), keep only the
##   canonical climate indicators (dropping region attributes such as
##   st_area_sh), and split the result by admin level into
##   annual_admin{0,1,2}.RData. CSV copies are written for admin-0 and admin-1
##   only (admin-2 is large: RData only).
##
##   This file performs NO computation on the values: no temporal aggregation,
##   unit conversion, rounding, NA/Inf handling, PCA, thresholds, REGID
##   construction, or longitude rotation. All indicator values are already
##   computed upstream in the panel that produced SHINY_TS.
##
## Inputs:
##   - DIR_SHINY/SHINY_TS.RData : object `df`, long format with columns
##       REGID, NAME, COUNTRY, SHAPEFILE (character '0'/'1'/'2'),
##       DATE (year, 1950-2025), Indicator, Value.
##   - ANNUAL_LEVELS env var (optional): comma-separated admin levels to write
##       (e.g. "0,1"). Empty/unset -> c(0L, 1L, 2L).
##
## Outputs (in DIR_ANNUAL; object saved is named `d`):
##   - annual_admin0.RData + annual_admin0.csv
##   - annual_admin1.RData + annual_admin1.csv
##   - annual_admin2.RData          (no CSV)
##
## Pipeline position: final stage of 3_panels — consumes the SHINY_TS panel
## and emits the published admin-level annual deliverables.
###############################################################################

source("config.R")

suppressMessages({ library(dplyr); library(data.table) })

dir.create(DIR_ANNUAL, recursive = TRUE, showWarnings = FALSE)

## ---- Load the annual panel ----------------------------------------------
cat("Loading SHINY_TS.RData...\n")
load(file.path(DIR_SHINY, "SHINY_TS.RData"))
cat(sprintf("  loaded df: rows=%d  years=%s..%s  indicators=%d\n",
            nrow(df),
            as.character(min(df$DATE)),
            as.character(max(df$DATE)),
            length(unique(df$Indicator))))

## ---- Keep only the canonical climate indicators -------------------------
## Inclusion whitelist: any indicator not spelled exactly as in KEEP_INDICATORS
## is silently dropped (notably the region attribute st_area_sh).
df <- df %>% filter(Indicator %in% KEEP_INDICATORS)
cat(sprintf("  after filtering to climate indicators: rows=%d (%d indicators)\n",
            nrow(df), length(unique(df$Indicator))))

## ---- Per-level writer ----------------------------------------------------
## SHAPEFILE is stored as a character string; compare with as.character(level).
## The saved object is a base data.frame named `d`.
write_level <- function(level, write_csv = TRUE) {
  cat(sprintf("\n--- admin-%d ---\n", level))
  d <- df %>% filter(SHAPEFILE == as.character(level)) %>% as.data.frame()
  cat(sprintf("  rows=%d  REGIDs=%d  years=%s..%s\n",
              nrow(d), length(unique(d$REGID)),
              as.character(min(d$DATE)), as.character(max(d$DATE))))
  out_rdata <- file.path(DIR_ANNUAL, sprintf("annual_admin%d.RData", level))
  save(d, file = out_rdata)
  cat(sprintf("  SAVED %s\n", out_rdata))
  if (write_csv) {
    out_csv <- file.path(DIR_ANNUAL, sprintf("annual_admin%d.csv", level))
    fwrite(d, out_csv)
    cat(sprintf("  SAVED %s\n", out_csv))
  }
  rm(d); gc()
}

## ---- Select which levels to write ---------------------------------------
## ANNUAL_LEVELS (e.g. "0,1" to skip admin-2). Empty/unset -> all three.
.lvls <- Sys.getenv("ANNUAL_LEVELS")
levels_to_run <- if (nzchar(.lvls)) {
  as.integer(strsplit(.lvls, ",")[[1]])
} else {
  c(0L, 1L, 2L)
}
cat(sprintf("Writing admin levels: %s\n", paste(levels_to_run, collapse = ",")))

## Admin-0 and admin-1 get RData + CSV; admin-2 gets RData only (write_csv = FALSE).
if (0L %in% levels_to_run) write_level(0L)
if (1L %in% levels_to_run) write_level(1L)
if (2L %in% levels_to_run) write_level(2L, write_csv = FALSE)

cat("\nAll annual files regenerated.\n")
