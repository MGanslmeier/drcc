###############################################################################
## External validation vs Berkeley Earth at country (admin-0) level.
## Produces manuscript Figure 5 (FIGURE_VAL_BE.png) plus comparison statistics.
##
## Inputs:  DIR_VALIDATION/be_download_log.RData + be_raw/*.txt (download_berkeley.R)
##          DIR_MAP_LAYERS/SHINY_admin0.RData, sh_admin0.RData
## Outputs: DIR_VALIDATION/be_drcc_comparison.RData ; DIR_FIGURES/FIGURE_VAL_BE.png
###############################################################################

source("config.R")
source("R/setup_figure_packages.R")
dir.create(DIR_FIGURES, recursive = TRUE, showWarnings = FALSE)

raw_dir <- file.path(DIR_VALIDATION, "be_raw")
load(file.path(DIR_VALIDATION, "be_download_log.RData"))
log <- subset(log, ok)

parse_be <- function(country, slug, path) {
  L <- readLines(path, warn = FALSE)
  base_line <- grep("Estimated Jan 1951-Dec 1980 absolute temperature", L, value = TRUE)
  if (length(base_line) == 0) return(NULL)
  baseline <- as.numeric(sub(".*:\\s*([\\-\\d\\.]+).*", "\\1", base_line, perl = TRUE))
  area_line <- grep("Area:", L, value = TRUE)
  be_area <- if (length(area_line) > 0) as.numeric(sub(".*:\\s*([\\d\\.]+).*", "\\1", area_line[1], perl = TRUE)) else NA
  data_lines <- L[grepl("^\\s*\\d{4}\\s+\\d+\\s", L)]
  if (length(data_lines) == 0) return(NULL)
  x <- read.table(text = data_lines, header = FALSE, fill = TRUE, na.strings = c("NaN", "NA"))
  june <- subset(x, V2 == 6)
  df <- data.frame(
    COUNTRY = country,
    YEAR = june$V1,
    be_annual_anom = june$V5,
    be_baseline = baseline,
    be_area_km2 = be_area,
    stringsAsFactors = FALSE
  )
  df$be_annual_abs <- df$be_baseline + df$be_annual_anom
  df
}

be_annual <- list()
for (i in seq_len(nrow(log))) {
  path <- file.path(raw_dir, paste0(log$slug[i], "-TAVG-Trend.txt"))
  if (!file.exists(path)) next
  r <- try(parse_be(log$COUNTRY[i], log$slug[i], path), silent = TRUE)
  if (!inherits(r, "try-error") && !is.null(r)) be_annual[[i]] <- r
}
be_annual <- bind_rows(be_annual)

# Load DRCC admin-0 panel and sh metadata (area per admin-0 feature)
load(file.path(DIR_MAP_LAYERS, "SHINY_admin0.RData"))
load(file.path(DIR_MAP_LAYERS, "sh_admin0.RData"))
a0_areas <- sh_admin0@data %>% as.data.frame() %>% select(REGID, COUNTRY, st_area_sh)
a0_areas$st_area_sh <- as.numeric(a0_areas$st_area_sh)

# Aggregate DRCC admin-0 to COUNTRY-YEAR via area-weighted mean over features
drcc_country <- df_admin0 %>%
  filter(Indicator == "mean_t2m_temperature") %>%
  inner_join(a0_areas, by = c("REGID", "COUNTRY")) %>%
  group_by(COUNTRY, YEAR) %>%
  summarize(
    drcc = sum(Value * st_area_sh, na.rm = TRUE) / sum(st_area_sh),
    drcc_area = sum(st_area_sh, na.rm = TRUE),
    .groups = "drop"
  )

# Merge
cmp <- be_annual %>%
  filter(YEAR >= 1950 & YEAR <= 2025) %>%
  inner_join(drcc_country, by = c("COUNTRY", "YEAR")) %>%
  mutate(abs_dev = abs(drcc - be_annual_abs), diff = drcc - be_annual_abs)

# Flag countries with multiple admin-0 features (likely territory mismatch).
n_features <- a0_areas %>% group_by(COUNTRY) %>% summarize(n_feat = n(), .groups = "drop")
cmp <- cmp %>% left_join(n_features, by = "COUNTRY")

# Overall
overall <- cmp %>% summarize(
  n_obs = n(),
  n_countries = length(unique(COUNTRY)),
  med_abs = median(abs_dev, na.rm = TRUE),
  p95_abs = quantile(abs_dev, 0.95, na.rm = TRUE),
  mean_diff = mean(diff, na.rm = TRUE),
  sd_diff = sd(diff, na.rm = TRUE),
  cor = cor(drcc, be_annual_abs, use = "complete.obs")
)
cat("=== All matched country-years ===\n")
print(overall, digits = 4)

# Known geographic-definition mismatches (BE's region differs from WB admin-0 extent).
# BE's "Denmark" includes Greenland; WB Denmark admin-0 is mainland only.
geo_mismatch <- c("Denmark")

# Subset: single-feature countries with aligned geographic definitions
cmp_single <- subset(cmp, n_feat == 1 & !(COUNTRY %in% geo_mismatch))
single_stats <- cmp_single %>% summarize(
  n_obs = n(),
  n_countries = length(unique(COUNTRY)),
  med_abs = median(abs_dev, na.rm = TRUE),
  p95_abs = quantile(abs_dev, 0.95, na.rm = TRUE),
  mean_diff = mean(diff, na.rm = TRUE),
  sd_diff = sd(diff, na.rm = TRUE),
  cor = cor(drcc, be_annual_abs, use = "complete.obs")
)
cat("\n=== Single-admin-0-feature countries only (geographic-definition match) ===\n")
print(single_stats, digits = 4)

# Worst offenders by country
worst <- cmp %>% group_by(COUNTRY) %>%
  summarize(med_abs = median(abs_dev, na.rm = TRUE), n_feat = first(n_feat), .groups = "drop") %>%
  arrange(desc(med_abs)) %>% head(15)
cat("\n=== Largest country-level deviations (likely geographic-definition mismatches) ===\n")
print(as.data.frame(worst), digits = 3)

# Continent mapping
suppressWarnings({
  cmp_single$continent <- countrycode(cmp_single$COUNTRY, origin = "country.name", destination = "region23")
})
cmp_single$continent[is.na(cmp_single$continent)] <- "Other"
region_map <- list(
  "Europe & Central Asia" = c("Western Europe", "Eastern Europe", "Northern Europe", "Southern Europe", "Central Asia"),
  "Sub-Saharan Africa" = c("Eastern Africa", "Middle Africa", "Southern Africa", "Western Africa"),
  "Middle East & North Africa" = c("Northern Africa", "Western Asia"),
  "South & East Asia" = c("Southern Asia", "South-Eastern Asia", "Eastern Asia"),
  "Latin America & Caribbean" = c("Caribbean", "Central America", "South America"),
  "North America" = c("Northern America"),
  "Oceania" = c("Australia and New Zealand", "Melanesia", "Micronesia", "Polynesia")
)
cmp_single$region <- "Other"
for (r in names(region_map)) cmp_single$region[cmp_single$continent %in% region_map[[r]]] <- r

by_region <- cmp_single %>% group_by(region) %>% summarize(
  n_obs = n(), n_countries = length(unique(COUNTRY)),
  med_abs = median(abs_dev, na.rm = TRUE),
  p95_abs = quantile(abs_dev, 0.95, na.rm = TRUE),
  cor = cor(drcc, be_annual_abs, use = "complete.obs"),
  .groups = "drop"
) %>% arrange(region)
cat("\n=== By region (single-feature countries only) ===\n")
print(as.data.frame(by_region), digits = 3)

save(cmp, cmp_single, overall, single_stats, by_region,
     file = file.path(DIR_VALIDATION, "be_drcc_comparison.RData"))

# Plot: single-feature countries only
p <- ggplot(cmp_single, aes(x = be_annual_abs, y = drcc, colour = region)) +
  geom_point(alpha = 0.4, size = 0.8) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "grey40") +
  facet_wrap(~region) +
  labs(
    x = "Berkeley Earth country annual mean temperature (°C)",
    y = "DRCC admin-0 annual mean temperature (°C)"
  ) +
  theme_light(base_size = 14) +
  theme(legend.position = "none",
        panel.grid.major = element_line(color = "grey85", linewidth = 0.3),
        panel.grid.minor = element_line(color = "grey92", linewidth = 0.15),
        strip.background = element_blank(),
        strip.text = element_text(size = 13),
        axis.text = element_text(size = 12),
        axis.title = element_text(size = 13))
ggsave(file.path(DIR_FIGURES, "FIGURE_VAL_BE.png"), p, width = 10, height = 6, dpi = 300)
cat("\nplot saved: FIGURE_VAL_BE.png\n")
