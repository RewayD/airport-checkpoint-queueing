args <- commandArgs(trailingOnly = FALSE)
script_arg <- grep("^--file=", args, value = TRUE)
script_path <- normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)

suppressPackageStartupMessages({
  library(dplyr)
  library(lubridate)
  library(purrr)
  library(readr)
  library(tidyr)
})

source(file.path(project_root, "R", "queueing_functions.R"))

set.seed(20260828)

# These parameters define a fictional screening checkpoint. They are not based
# on an airport, an instructor-provided dataset, or any real passenger records.
scenario <- tibble::tribble(
  ~period,           ~start_hour, ~arrival_rate, ~service_rate, ~servers,
  "Morning peak",             6,            84,            15,        6,
  "Midday",                  10,            52,            15,        5,
  "Afternoon peak",          14,            68,            15,        5,
  "Evening",                 18,            35,            15,        4
) %>%
  mutate(
    observation_hours = 2,
    warmup_hours = 2
  )

service_dates <- seq.Date(as.Date("2026-01-05"), by = "day", length.out = 84)

window_schedule <- tidyr::crossing(
  service_date = service_dates,
  scenario
) %>%
  arrange(service_date, start_hour) %>%
  mutate(
    day_type = if_else(wday(service_date, week_start = 1) <= 5, "Weekday", "Weekend"),
    window_start = as.POSIXct(service_date, tz = "UTC") + hours(start_hour),
    window_end = window_start + hours(observation_hours)
  )

event_list <- pmap(
  window_schedule %>%
    select(
      service_date,
      period,
      start_hour,
      arrival_rate,
      service_rate,
      servers,
      observation_hours,
      warmup_hours
    ),
  function(service_date, period, start_hour, arrival_rate, service_rate, servers,
           observation_hours, warmup_hours) {
    simulate_mmc_window(
      service_date = service_date,
      period = period,
      start_hour = start_hour,
      lambda = arrival_rate,
      mu = service_rate,
      servers = servers,
      observation_hours = observation_hours,
      warmup_hours = warmup_hours,
      timezone = "UTC"
    )
  }
)

events <- bind_rows(event_list) %>%
  arrange(arrival_time) %>%
  group_by(service_date, period) %>%
  mutate(
    passenger_sequence = row_number(),
    passenger_id = sprintf(
      "SYN-%s-%s-%04d",
      format(service_date, "%Y%m%d"),
      gsub("[^A-Z]", "", toupper(period)),
      passenger_sequence
    )
  ) %>%
  ungroup() %>%
  select(
    passenger_id,
    service_date,
    period,
    arrival_time,
    service_start_time,
    service_end_time,
    server_id,
    servers_scheduled
  )

# Only operational exposure and staffing are released in the schedule. The
# latent rates used by the generator remain in this source file so the analysis
# must estimate lambda and mu from timestamps instead of reading the truth.
released_schedule <- window_schedule %>%
  transmute(
    service_date,
    period,
    day_type,
    window_start,
    window_end,
    observation_hours,
    servers_scheduled = servers
  )

readr::write_csv(
  events,
  file.path(project_root, "data", "synthetic_checkpoint_events.csv"),
  na = ""
)
readr::write_csv(
  released_schedule,
  file.path(project_root, "data", "synthetic_window_schedule.csv"),
  na = ""
)

message(sprintf(
  "Generated %s synthetic passenger events across %s operating windows.",
  format(nrow(events), big.mark = ","),
  nrow(released_schedule)
))
