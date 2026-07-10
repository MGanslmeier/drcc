###############################################################################
## Download Berkeley Earth US-state temperature series (external validation).
##
## For every DRCC admin-1 unit in the United States, fetch the Berkeley Earth
## "<slug>-TAVG-Trend" file into DIR_VALIDATION/be_states/, with a download log.
## Consumed by validate_us_states.R (manuscript Figure 6).
###############################################################################

source("config.R")

load(file.path(DIR_MAP_LAYERS, "sh_admin1.RData"))
us_states <- sh_admin1@data %>% as.data.frame() %>%
  filter(grepl("United States", COUNTRY, ignore.case = TRUE)) %>%
  pull(NAME) %>% unique()
cat("Found", length(us_states), "US admin-1 units\n")

# Extract clean state name (before "(United States of America)")
clean_name <- function(x) {
  x <- sub("\\s*\\(.*", "", x)
  tolower(gsub("\\s+", "-", x))
}

out_dir <- file.path(DIR_VALIDATION, "be_states")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

slug_map <- list()
for (n in us_states) slug_map[[n]] <- clean_name(n)

log <- data.frame(NAME = character(), slug = character(), ok = logical(), stringsAsFactors = FALSE)
for (n in us_states) {
  slug <- slug_map[[n]]
  dest <- file.path(out_dir, paste0(slug, "-TAVG-Trend.txt"))
  if (file.exists(dest) && file.info(dest)$size > 2000) {
    log <- rbind(log, data.frame(NAME = n, slug = slug, ok = TRUE))
    next
  }
  url <- paste0("https://berkeley-earth-temperature.s3.us-west-1.amazonaws.com/Regional/TAVG/", slug, "-TAVG-Trend.txt")
  r <- try(download.file(url, dest, quiet = TRUE, mode = "wb"), silent = TRUE)
  ok <- !inherits(r, "try-error") && file.exists(dest) && file.info(dest)$size > 2000
  log <- rbind(log, data.frame(NAME = n, slug = slug, ok = ok))
}
save(log, file = file.path(DIR_VALIDATION, "be_states_log.RData"))
cat("US states downloaded:", sum(log$ok), "/", nrow(log), "\n")
cat("failures:", paste(log$NAME[!log$ok], collapse = "; "), "\n")
