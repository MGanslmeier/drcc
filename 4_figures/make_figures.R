###############################################################################
## Reproduce manuscript Figures 1-4 from the DRCC data products.
##
## Inputs (built by the pipeline):
##   DIR_MAP_LAYERS/sh_admin0/1/2.RData, SHINY_admin2.RData
##   DIR_SHINY/SHINY_TS.RData
##   DIR_FINAL/wb_admin{0,1,2}/... daily panels
##   OWID_CSV  (Our World in Data monthly temperature; external, see config.R)
## Outputs:
##   DIR_FIGURES/FIGURE_1.png ... FIGURE_4.png
##
## Figures 5-6 (validation) are produced under validation/; Figures 7-8 are
## screenshots of the interactive tools and are not generated from code.
###############################################################################

source("config.R")
source("R/setup_figure_packages.R")
dir.create(DIR_FIGURES, recursive = TRUE, showWarnings = FALSE)

# ---- FIGURE 1 — admin-2 world map ------------------------------------------
load(file.path(DIR_MAP_LAYERS, "sh_admin0.RData"))
load(file.path(DIR_MAP_LAYERS, "sh_admin1.RData"))
load(file.path(DIR_MAP_LAYERS, "sh_admin2.RData"))

fig1 <- ggplot() +
  geom_sf(data = st_as_sf(sh_admin2), linewidth = 0.06, fill = 'white', color = 'grey50') +
  geom_sf(data = st_as_sf(sh_admin0), linewidth = 0.22, fill = NA, color = 'grey30') +
  theme_minimal(base_size = 14) +
  theme(legend.position = "none",
        axis.text = element_text(size = 12),
        panel.grid.major = element_line(color = "grey70", linewidth = 0.3))
ggsave(filename = file.path(DIR_FIGURES, "FIGURE_1.png"), fig1, width = 20, height = 12, dpi = 300)
cat("FIGURE_1 done\n")

# ---- FIGURE 2 — Panel A (country trends), B (US daily), C (India heat days) --

# Panel C: India heat-day maps across snapshot years
load(file.path(DIR_MAP_LAYERS, "sh_admin2.RData"))
sh <- sh_admin2 %>% st_as_sf(., region = 'REGID')
load(file.path(DIR_MAP_LAYERS, "SHINY_admin2.RData"))
df <- df_admin2

reshape_year <- function(df, sh, yr) {
  df %>%
    subset(., YEAR == yr) %>% select(REGID, Indicator, Value) %>%
    spread(., Indicator, Value) %>% select(-st_area_sh) %>%
    left_join(sh, ., by = 'REGID') %>%
    mutate(COUNTRY = COUNTRY %>% replace(., . == 'D. P. R. of Korea', 'North Korea')) %>%
    mutate(ISO = countrycode::countrycode(COUNTRY, 'country.name', 'iso3c')) %>%
    subset(., !is.na(ISO)) %>%
    mutate(continent = countrycode::countrycode(ISO, 'iso3c', "region")) %>%
    mutate(YEAR = yr)
}
temp <- bind_rows(
  reshape_year(df, sh, 1950),
  reshape_year(df, sh, 1970),
  reshape_year(df, sh, 1990),
  reshape_year(df, sh, 2025)
)
p4_india <- ggplot() +
  geom_sf(data = temp %>% subset(., COUNTRY == 'India'),
          aes(fill = heat_days), color = 'black', linewidth = 0.04) +
  scale_fill_distiller(palette = "YlOrRd", direction = 2, limits = c(0, 180), oob = scales::squish) +
  xlab('number of heat days in India') +
  ggtitle('(C)') +
  theme_minimal(base_size = 14) +
  theme(legend.position = 'right',
        legend.title = element_blank(),
        legend.key.width = unit(0.6, 'cm'),
        axis.text = element_blank(),
        axis.title.x = element_text(size = 15),
        strip.text = element_text(size = 15),
        plot.title = element_text(hjust = 0.5)) +
  facet_wrap(~YEAR, nrow = 1)

# Panel A: Eastern European country annual mean temperature
load(file.path(DIR_SHINY, "SHINY_TS.RData"))
temp_a <- df %>%
  subset(., SHAPEFILE == 0) %>%
  subset(., Indicator == 'mean_t2m_temperature') %>%
  subset(., NAME %in% c("Lithuania (LTU) (admin-0)", "Ukraine (UKR) (admin-0)",
                         "Latvia (LVA) (admin-0)", "Belarus (BLR) (admin-0)",
                         "Estonia (EST) (admin-0)"))
p1 <- ggplot() +
  geom_line(data = temp_a, aes(x = DATE, y = Value, group = REGID, color = COUNTRY), linewidth = 0.4) +
  geom_point(data = temp_a, aes(x = DATE, y = Value, color = COUNTRY), size = 0.75) +
  scale_x_continuous(breaks = seq(1950, 2030, 10)) +
  scale_y_continuous(breaks = seq(0, 2050, 1)) +
  scale_color_aaas() +
  ylab(expression(paste("annual temperature (", degree, "C)"))) + xlab('') +
  ggtitle('(A)') +
  guides(color = guide_legend(override.aes = list(size = 5))) +
  theme_light(base_size = 14) +
  theme(legend.title = element_blank(),
        legend.position = 'bottom',
        axis.text = element_text(size = 11),
        axis.title = element_text(size = 13),
        plot.title = element_text(hjust = 0.5))

# Panel B: US states daily temperature for 2024-2025
load(file.path(DIR_MAP_LAYERS, "sh_admin1.RData"))
# admin-1 is per-year; bind just the years we need
e <- new.env(); load(file.path(DIR_FINAL, "wb_admin1", "wb_admin1_2024.RData"), envir = e); df_2024 <- e$df
load(file.path(DIR_FINAL, "wb_admin1", "wb_admin1_2025.RData"), envir = e); df_2025 <- e$df
df_b <- bind_rows(df_2024, df_2025)
rm(df_2024, df_2025, e)
temp_b <- df_b %>%
  left_join(., sh_admin1@data, by = 'REGID') %>%
  subset(., COUNTRY %in% c('United States of America')) %>%
  subset(., grepl('Florida|Texas|Illinois|California|New York', NAME)) %>%
  mutate(NAME = NAME %>% gsub(' .*', '', .) %>% gsub('New', 'New York', .)) %>%
  mutate(Value = t2m_temperature)
p2 <- ggplot() +
  geom_line(data = temp_b, aes(x = DATE, y = Value, group = REGID, color = NAME), linewidth = 0.25) +
  geom_point(data = temp_b, aes(x = DATE, y = Value, color = NAME), size = 0.1) +
  scale_y_continuous(breaks = seq(-100, 2050, 5)) +
  scale_x_date(date_break = '2 months', date_labels = "%b '%y") +
  scale_color_aaas() +
  ylab(expression(paste("daily temperature (", degree, "C)"))) + xlab('') +
  ggtitle('(B)') +
  guides(color = guide_legend(override.aes = list(size = 5))) +
  theme_light(base_size = 14) +
  theme(legend.title = element_blank(),
        legend.position = 'bottom',
        plot.title = element_text(hjust = 0.5),
        axis.text = element_text(size = 11),
        axis.title = element_text(size = 13),
        axis.text.x = element_text(angle = 45, hjust = 1, size = 11))

# Combine
fig2 <- ( p1 | p2 ) / p4_india
ggsave(filename = file.path(DIR_FIGURES, "FIGURE_2.png"), fig2, width = 12, height = 7, dpi = 300)
cat("FIGURE_2 done\n")

# ---- FIGURE 3 — density of 1950-2025 changes at admin-2 --------------------
load(file.path(DIR_MAP_LAYERS, "sh_admin2.RData"))
load(file.path(DIR_FINAL, "wb_admin2", "wb_admin2_2025.RData"))
df_2025 <- df %>%
  left_join(., sh_admin2@data, by = 'REGID') %>%
  mutate(CONT = countrycode::countrycode(COUNTRY, 'country.name', 'region')) %>%
  subset(., year(DATE) == 2025) %>%
  dplyr::select(-c(COUNTRY, SHAPEFILE, NAME, DATE)) %>%
  group_by(REGID, CONT) %>% summarize_all(mean, na.rm = T) %>% ungroup() %>%
  gather(., var, val_2025, -c(REGID, CONT))
load(file.path(DIR_FINAL, "wb_admin2", "wb_admin2_1950.RData"))
df_1950 <- df %>%
  left_join(., sh_admin2@data, by = 'REGID') %>%
  mutate(CONT = countrycode::countrycode(COUNTRY, 'country.name', 'region')) %>%
  subset(., year(DATE) == 1950) %>%
  dplyr::select(-c(COUNTRY, SHAPEFILE, NAME, DATE)) %>%
  group_by(REGID, CONT) %>% summarize_all(mean, na.rm = T) %>% ungroup() %>%
  gather(., var, val_1950, -c(REGID, CONT))
temp <- df_2025 %>%
  left_join(., df_1950, by = c('REGID', 'CONT', 'var')) %>%
  mutate(val_diff = val_2025 - val_1950) %>%
  # Convert precipitation from metres to mm for interpretable axis
  mutate(val_diff = ifelse(var == 'total_precipitation', val_diff * 1000, val_diff)) %>%
  mutate(CONT = CONT %>% replace(., . %in% c("East Asia & Pacific", "South Asia"), 'South-East Asia & Pacific')) %>%
  subset(., !is.na(CONT)) %>%
  mutate(CONT = factor(CONT, levels = c("Middle East & North Africa", "Europe & Central Asia", 'South-East Asia & Pacific',
                                        "North America", "Sub-Saharan Africa", "Latin America & Caribbean")))

make_density <- function(temp, var_name, xlab_text, bw_val = NULL, trim_pct = NULL) {
  d <- temp %>% subset(., var == var_name)
  if (!is.null(trim_pct)) {
    d <- d %>%
      filter(val_diff < quantile(val_diff, 1 - trim_pct, na.rm = T)) %>%
      filter(val_diff > quantile(val_diff, trim_pct, na.rm = T))
  }
  ggplot() +
    geom_density(data = d, aes(x = val_diff, fill = CONT), alpha = 0.75, linewidth = 0.25,
                 bw = ifelse(is.null(bw_val), 0.25, bw_val)) +
    geom_vline(xintercept = 0, linetype = 'dashed') +
    scale_fill_brewer(palette = 'Set2', guide = 'none') +
    ylab('density') +
    xlab(xlab_text) +
    theme_light(base_size = 14) +
    theme(legend.position = 'none',
          strip.background = element_blank(),
          strip.text = element_text(size = 12, face = 'bold', color = 'black'),
          plot.title = element_text(hjust = 0.5),
          axis.text.x = element_text(size = 9, angle = 30, hjust = 1),
          axis.text.y = element_text(size = 11),
          axis.title = element_text(size = 13)) +
    facet_wrap(~CONT, nrow = 6, scales = 'free_y')
}

p3a <- make_density(temp, 't2m_temperature',
                    bquote(atop(Delta~"temperature ("*degree*"C)", "(1950-2025)")),
                    bw_val = 0.25)
p3b <- make_density(temp, 'total_precipitation',
                    expression(atop(Delta~"precipitation (mm)", "(1950-2025)")),
                    trim_pct = 0.025, bw_val = 0.02) + ylab('')
p3c <- make_density(temp, 'fire_weather_index',
                    expression(atop(Delta~"fire-weather index", "(1950-2025)")),
                    bw_val = 0.25, trim_pct = 0.05) + ylab('')
p3d <- make_density(temp, 'keetch_byram_drought_index',
                    expression(atop(Delta~"KBDI", "(1950-2025)")),
                    bw_val = 0.25, trim_pct = 0.05) + ylab('')

fig3 <- p3a | p3b | p3c | p3d
ggsave(fig3, filename = file.path(DIR_FIGURES, "FIGURE_3.png"), width = 14, height = 9, dpi = 300)
cat("FIGURE_3 done\n")

# ---- FIGURE 4 — OWID validation scatter ------------------------------------
load(file.path(DIR_MAP_LAYERS, "sh_admin0.RData"))
load(file.path(DIR_FINAL, "wb_admin0", "wb_admin0.RData"))
temp1 <- df %>%
  mutate(MONTH = DATE %>% str_sub(., 1, 7)) %>%
  group_by(REGID, MONTH) %>% summarize(era5 = mean(t2m_temperature, na.rm = T)) %>% ungroup() %>%
  left_join(., sh_admin0@data %>% select(REGID, COUNTRY), by = 'REGID') %>%
  mutate(ISO = countrycode::countrycode(COUNTRY, 'country.name', 'iso3c')) %>%
  subset(., !is.na(ISO)) %>%
  dplyr::select(ISO, MONTH, era5)
temp2 <- read.csv(OWID_CSV) %>%
  mutate(ISO = countrycode::countrycode(Entity, 'country.name', 'iso3c')) %>%
  dplyr::select(ISO, MONTH = Year, starts_with('X')) %>%
  subset(., !is.na(ISO)) %>%
  gather(., YEAR, owid, -c(ISO, MONTH)) %>%
  mutate(MONTH = paste(sep = '-', gsub('X', '', YEAR), str_pad(MONTH, 2, pad = '0'))) %>%
  dplyr::select(ISO, MONTH, owid)
temp <- left_join(temp1, temp2, by = c('ISO', 'MONTH')) %>%
  subset(., complete.cases(.)) %>%
  subset(., !ISO %in% c('FRA', 'FIN')) %>%
  mutate(CONT = countrycode::countrycode(ISO, 'iso3c', "region")) %>%
  mutate(CONT = CONT %>% replace(., . %in% c("East Asia & Pacific", "South Asia"), 'South-East Asia & Pacific'))
fig4 <- ggplot() +
  geom_point(data = temp, aes(y = era5, x = owid, color = CONT), size = 0.75) +
  geom_abline(slope = 1, intercept = 0, linetype = 'dashed', color = 'grey40') +
  scale_color_aaas() +
  xlab(expression(paste("monthly temperature in ", degree, "C (source: Our World in Data)"))) +
  ylab(expression(paste("monthly temperature in ", degree, "C (source: DRCC, based on ERA5)"))) +
  theme_light(base_size = 14) +
  guides(color = "none") +
  theme(legend.title = element_blank(),
        panel.border = element_rect(color = "black", fill = NA, linewidth = 0.5),
        panel.grid.major = element_line(color = "grey85", linewidth = 0.3),
        panel.grid.minor = element_line(color = "grey92", linewidth = 0.15),
        strip.background = element_blank(),
        strip.text = element_text(size = 15),
        axis.text = element_text(size = 12),
        axis.title = element_text(size = 13),
        plot.title = element_text(hjust = 0.5)) +
  facet_wrap(~CONT, nrow = 2)
ggsave(fig4, filename = file.path(DIR_FIGURES, "FIGURE_4.png"), width = 10, height = 6, dpi = 300)
cat("FIGURE_4 done\n")
cat("All figures regenerated.\n")
