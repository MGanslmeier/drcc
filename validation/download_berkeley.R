###############################################################################
## Download Berkeley Earth country temperature series (external validation).
##
## For every DRCC admin-0 country, fetch the Berkeley Earth "<slug>-TAVG-Trend"
## file into DIR_VALIDATION/be_raw/, and record a download log. Consumed by
## validate_berkeley.R (manuscript Figure 5).
###############################################################################

source("config.R")

load(file.path(DIR_MAP_LAYERS, "SHINY_admin0.RData"))
countries <- unique(df_admin0$COUNTRY)

# BE file naming: lowercase, spaces/punctuation to dashes, no apostrophes
be_slug <- function(x) {
  x <- tolower(x)
  x <- gsub("[^a-z0-9 -]", "", x)
  x <- gsub("\\s+", "-", x)
  x
}

# Known BE name remappings where WB names differ from BE's conventions
remap <- c(
  "Arab Republic of Egypt" = "egypt",
  "Islamic Republic of Iran" = "iran",
  "Bolivarian Republic of Venezuela" = "venezuela",
  "R. B. de Venezuela" = "venezuela",
  "Syrian Arab Republic" = "syria",
  "Russian Federation" = "russia",
  "United Kingdom of Great Britain and Northern Ireland" = "united-kingdom",
  "United Kingdom" = "united-kingdom",
  "United States" = "united-states",
  "United States of America" = "united-states",
  "Democratic Republic of the Congo" = "democratic-republic-of-the-congo",
  "Democratic Republic of Congo" = "democratic-republic-of-the-congo",
  "Republic of the Congo" = "republic-of-the-congo",
  "Republic of Korea" = "south-korea",
  "Korea, Republic of" = "south-korea",
  "Democratic People's Republic of Korea" = "north-korea",
  "D. P. R. of Korea" = "north-korea",
  "Kyrgyz Republic" = "kyrgyzstan",
  "Slovak Republic" = "slovakia",
  "Czech Republic" = "czech-republic",
  "Lao People's Democratic Republic" = "laos",
  "Lao PDR" = "laos",
  "Federated States of Micronesia" = "federated-states-of-micronesia",
  "Micronesia, Fed. Sts." = "federated-states-of-micronesia",
  "Republic of Moldova" = "moldova",
  "Moldova" = "moldova",
  "Cabo Verde" = "cape-verde",
  "Cote d'Ivoire" = "ivory-coast",
  "Côte d'Ivoire" = "ivory-coast",
  "C^ote d'Ivoire" = "ivory-coast",
  "Türkiye" = "turkey",
  "Turkiye" = "turkey",
  "Myanmar" = "burma",
  "Palestine" = "palestina",
  "West Bank and Gaza" = "palestina",
  "Eswatini" = "swaziland",
  "Kingdom of Eswatini" = "swaziland",
  "North Macedonia" = "macedonia",
  "Timor-Leste" = "east-timor",
  "Brunei Darussalam" = "brunei",
  "Saint Kitts and Nevis" = "saint-kitts-and-nevis",
  "Saint Lucia" = "saint-lucia",
  "Saint Vincent and the Grenadines" = "saint-vincent-and-the-grenadines",
  "The Gambia" = "gambia",
  "Republic of Yemen" = "yemen",
  "São Tomé and Príncipe" = "sao-tome-and-principe",
  "Sao Tome and Principe" = "sao-tome-and-principe"
)

ascii_only <- function(x) iconv(x, from = "UTF-8", to = "ASCII//TRANSLIT")

get_slug <- function(country) {
  if (country %in% names(remap)) return(remap[[country]])
  a <- ascii_only(country)
  if (!is.na(a) && a %in% names(remap)) return(remap[[a]])
  be_slug(a)
}

out_dir <- file.path(DIR_VALIDATION, "be_raw")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

log <- data.frame(COUNTRY = character(), slug = character(), ok = logical(), stringsAsFactors = FALSE)
for (c in countries) {
  slug <- get_slug(c)
  dest <- file.path(out_dir, paste0(slug, "-TAVG-Trend.txt"))
  if (file.exists(dest) && file.info(dest)$size > 2000) {
    log <- rbind(log, data.frame(COUNTRY = c, slug = slug, ok = TRUE))
    next
  }
  url <- paste0("https://berkeley-earth-temperature.s3.us-west-1.amazonaws.com/Regional/TAVG/", slug, "-TAVG-Trend.txt")
  r <- try(download.file(url, dest, quiet = TRUE, mode = "wb"), silent = TRUE)
  ok <- !inherits(r, "try-error") && file.exists(dest) && file.info(dest)$size > 2000
  log <- rbind(log, data.frame(COUNTRY = c, slug = slug, ok = ok))
}
save(log, file = file.path(DIR_VALIDATION, "be_download_log.RData"))
cat("ok:", sum(log$ok), "/", nrow(log), "\n")
cat("failed examples:", paste(head(log$COUNTRY[!log$ok], 15), collapse = "; "), "\n")
