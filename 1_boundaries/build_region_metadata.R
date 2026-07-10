###############################################################################
## DRCC pipeline — build the region metadata workbook (META.xlsx).
##
## Purpose:
##   Produce the human-readable region metadata workbook by extracting the
##   attribute tables of the three cleaned World Bank admin-level shapefiles,
##   sorting each by REGID, and dropping three internal geometry-bookkeeping
##   columns. Geometry is discarded; this is a tabular metadata dump.
##
## Inputs (from DIR_BOUNDARIES):
##   sh_admin0.RData, sh_admin1.RData, sh_admin2.RData — each an R object `sh`
##   (cleaned SpatialPolygonsDataFrame). Only the `@data` attribute table is used.
##
## Outputs (to DIR_META):
##   META.xlsx — three-sheet Excel workbook with sheets 'admin-0','admin-1',
##   'admin-2'. Each sheet is that admin level's polygon attribute table sorted
##   ascending by REGID with columns globalid, st_area_sh, st_length_ removed.
##   All remaining attribute columns are retained unchanged, in original order.
##
## Pipeline position:
##   Stage 1 (boundaries). Runs after the shapefiles are cleaned/REGID-tagged;
##   feeds the published metadata reference for the climate panels. No filtering:
##   ALL polygons/regions are included (non-member territories remain).
###############################################################################

source("config.R")

## ---- Load cleaned shapefiles ---------------------------------------------
## Each .RData carries an object named `sh`; capture it immediately after each
## load() so the level-to-object aliasing (admin0->sh0, admin1->sh1, admin2->sh2)
## is correct.
load(file.path(DIR_BOUNDARIES, "sh_admin0.RData"))
sh0 <- sh
load(file.path(DIR_BOUNDARIES, "sh_admin1.RData"))
sh1 <- sh
load(file.path(DIR_BOUNDARIES, "sh_admin2.RData"))
sh2 <- sh

## ---- Assemble metadata tables --------------------------------------------
## Hyphenated sheet names ('admin-0'/'admin-1'/'admin-2') become the Excel tabs.
## For each attribute table: arrange(REGID) THEN drop the three bookkeeping
## columns (arrange-then-drop order is load-bearing).
meta <- list("admin-0" = sh0@data, "admin-1" = sh1@data, "admin-2" = sh2@data) %>%
  lapply(., function(x) x %>%
           arrange(REGID) %>%
           select(-c("globalid", "st_area_sh", "st_length_")))

## ---- Write workbook -------------------------------------------------------
dir.create(DIR_META, recursive = TRUE, showWarnings = FALSE)
openxlsx::write.xlsx(meta, file = file.path(DIR_META, "META.xlsx"))
