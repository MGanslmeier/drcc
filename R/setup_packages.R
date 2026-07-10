###############################################################################
## Shared package loading for the DRCC pipeline (sourced by config.R).
##
## Load order is preserved from the original pipeline because it determines
## function masking: plyr is loaded BEFORE dplyr (so dplyr's verbs win), and
## raster BEFORE terra (so terra masks raster). Geometry/zonal calls in the
## stage scripts are namespace-qualified (terra::, raster::, rmapshaper::,
## dplyr::) so results do not depend on masking, but the order is kept as-is
## to stay faithful to the environment that produced the published database.
##
## The original helper additionally loaded interactive / scraping / plotting
## stacks (shiny, leaflet, plotly, RSelenium, rvest, ggplot2, ...). Those are
## NOT used anywhere in the batch construction pipeline and are dropped here so
## the pipeline runs headless without pulling Java/Selenium or a UI stack.
##
## NOTE ON rgeos: rgeos::gBuffer(width = 0) is used to repair geometry and is
## kept for exact replication. rgeos was archived from CRAN in 2023; install it
## from the archive, e.g.
##   remotes::install_version("rgeos", version = "0.6-4")
###############################################################################

if (!requireNamespace("pacman", quietly = TRUE)) install.packages("pacman")

pacman::p_load(
  # data wrangling / IO
  plyr, dplyr, readxl, tidyr, purrr, stringr, data.table, R.utils, tibble,
  haven, openxlsx,
  # parallelism / progress
  parallel, pbmcapply, pbapply,
  # dates
  lubridate,
  # geospatial / raster (raster before terra so terra masks raster)
  raster, terra, sf, rgeos, rmapshaper,
  # units / scaling
  weathermetrics, scales
)
