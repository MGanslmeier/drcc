###############################################################################
## External validation vs Berkeley Earth at US-state (admin-1) level.
## Produces manuscript Figure 6 (FIGURE_VAL_US.png) plus comparison statistics.
##
## Inputs:  DIR_VALIDATION/be_states_log.RData + be_states/*.txt (download_be_states.R)
##          DIR_MAP_LAYERS/SHINY_admin1.RData
## Outputs: DIR_VALIDATION/be_states_comparison.RData ; DIR_FIGURES/FIGURE_VAL_US.png
###############################################################################

source("config.R")
source("R/setup_figure_packages.R")
dir.create(DIR_FIGURES, recursive = TRUE, showWarnings = FALSE)

raw_dir <- file.path(DIR_VALIDATION, "be_states")
load(file.path(DIR_VALIDATION, "be_states_log.RData"))
log <- subset(log, ok)

parse_be <- function(name, slug, path) {
  L <- readLines(path, warn = FALSE)
  base_line <- grep("Estimated Jan 1951-Dec 1980 absolute temperature", L, value = TRUE)
  if (length(base_line) == 0) return(NULL)
  baseline <- as.numeric(sub(".*:\\s*([\\-\\d\\.]+).*", "\\1", base_line, perl = TRUE))
  data_lines <- L[grepl("^\\s*\\d{4}\\s+\\d+\\s", L)]
  if (length(data_lines) == 0) return(NULL)
  x <- read.table(text = data_lines, header = FALSE, fill = TRUE, na.strings = c("NaN", "NA"))
  june <- subset(x, V2 == 6)
  data.frame(NAME = name, YEAR = june$V1, be_annual_abs = baseline + june$V5, stringsAsFactors = FALSE)
}

be_states <- list()
for (i in seq_len(nrow(log))) {
  path <- file.path(raw_dir, paste0(log$slug[i], "-TAVG-Trend.txt"))
  r <- try(parse_be(log$NAME[i], log$slug[i], path), silent = TRUE)
  if (!inherits(r, "try-error") && !is.null(r)) be_states[[i]] <- r
}
be_states <- bind_rows(be_states)

# Load DRCC admin-1 data for US states
load(file.path(DIR_MAP_LAYERS, "SHINY_admin1.RData"))
drcc_states <- df_admin1 %>%
  filter(Indicator == "mean_t2m_temperature" & grepl("United States", COUNTRY, ignore.case = TRUE)) %>%
  select(NAME, YEAR, drcc = Value)

# Merge
cmp_states <- inner_join(be_states, drcc_states, by = c("NAME", "YEAR")) %>%
  filter(YEAR >= 1950 & YEAR <= 2025) %>%
  mutate(abs_dev = abs(drcc - be_annual_abs), diff = drcc - be_annual_abs)

cat("US state country-years matched:", nrow(cmp_states), "across", length(unique(cmp_states$NAME)), "states\n")
stats <- cmp_states %>% summarize(
  n_obs = n(),
  n_states = length(unique(NAME)),
  med_abs = median(abs_dev, na.rm = TRUE),
  p95_abs = quantile(abs_dev, 0.95, na.rm = TRUE),
  mean_diff = mean(diff, na.rm = TRUE),
  sd_diff = sd(diff, na.rm = TRUE),
  cor = cor(drcc, be_annual_abs, use = "complete.obs")
)
print(stats, digits = 4)

# Per-state stats to check for outliers
per_state <- cmp_states %>% group_by(NAME) %>% summarize(
  n = n(),
  med_abs = median(abs_dev, na.rm = TRUE),
  cor = cor(drcc, be_annual_abs, use = "complete.obs"),
  .groups = "drop"
) %>% arrange(desc(med_abs))
cat("\n=== Worst 10 states ===\n")
print(head(as.data.frame(per_state), 10), digits = 3)

# Plot: DRCC vs BE for all US states
p <- ggplot(cmp_states, aes(x = be_annual_abs, y = drcc)) +
  geom_point(alpha = 0.5, size = 1.2) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "grey40") +
  labs(
    x = "Berkeley Earth state annual mean temperature (°C)",
    y = "DRCC admin-1 annual mean temperature (°C)",
    title = NULL
  ) +
  theme_light(base_size = 14) +
  theme(panel.grid.major = element_line(color = "grey85", linewidth = 0.3),
        panel.grid.minor = element_line(color = "grey92", linewidth = 0.15),
        axis.text = element_text(size = 12),
        axis.title = element_text(size = 13))
ggsave(file.path(DIR_FIGURES, "FIGURE_VAL_US.png"), p, width = 7, height = 5.5, dpi = 300)
save(cmp_states, stats, per_state, file = file.path(DIR_VALIDATION, "be_states_comparison.RData"))
cat("\nplot saved: FIGURE_VAL_US.png\n")
