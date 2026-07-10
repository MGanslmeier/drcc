###############################################################################
## Additional packages for the figure and external-validation scripts.
##
## The core pipeline (R/setup_packages.R) is deliberately plotting-free so it
## runs headless. The figure/validation scripts need a plotting + country-coding
## stack on top of it; source this after config.R:
##   source("config.R"); source("R/setup_figure_packages.R")
###############################################################################

if (!requireNamespace("pacman", quietly = TRUE)) install.packages("pacman")

pacman::p_load(
  ggplot2, ggsci, patchwork, RColorBrewer,   # plotting
  countrycode,                                # country <-> ISO / region mapping
  sf, sp,                                     # spatial (maps)
  dplyr, tidyr, stringr, lubridate, scales    # wrangling (also in core; harmless)
)
