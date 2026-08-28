args <- commandArgs(trailingOnly = FALSE)
script_arg <- grep("^--file=", args, value = TRUE)
script_path <- normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(purrr)
  library(readr)
  library(tidyr)
})

source(file.path(project_root, "R", "queueing_functions.R"))

target_minutes <- 10
service_level_goal <- 0.85
bootstrap_repetitions <- 500L
period_order <- c("Morning peak", "Midday", "Afternoon peak", "Evening")

events <- readr::read_csv(
  file.path(project_root, "data", "synthetic_checkpoint_events.csv"),
  col_types = cols(
    passenger_id = col_character(),
    service_date = col_date(),
    period = col_character(),
    arrival_time = col_datetime(),
    service_start_time = col_datetime(),
    service_end_time = col_datetime(),
    server_id = col_integer(),
    servers_scheduled = col_integer()
  ),
  show_col_types = FALSE
)

schedule <- readr::read_csv(
  file.path(project_root, "data", "synthetic_window_schedule.csv"),
  col_types = cols(
    service_date = col_date(),
    period = col_character(),
    day_type = col_character(),
    window_start = col_datetime(),
    window_end = col_datetime(),
    observation_hours = col_double(),
    servers_scheduled = col_integer()
  ),
  show_col_types = FALSE
)

events <- events %>%
  mutate(
    wait_minutes = as.numeric(difftime(service_start_time, arrival_time, units = "mins")),
    service_hours = as.numeric(difftime(service_end_time, service_start_time, units = "hours")),
    period = factor(period, levels = period_order)
  )
schedule <- schedule %>%
  mutate(period = factor(period, levels = period_order))

if (anyDuplicated(events$passenger_id)) {
  stop("Synthetic passenger identifiers are not unique.", call. = FALSE)
}
if (any(events$wait_minutes < 0) || any(events$service_hours <= 0)) {
  stop("Event timestamps violate queue ordering.", call. = FALSE)
}
if (any(is.na(events$period)) || any(is.na(schedule$period))) {
  stop("An unexpected operating period was found.", call. = FALSE)
}

all_dates <- sort(unique(schedule$service_date))
if (length(all_dates) != 84L) {
  stop("The designed temporal split expects exactly 84 service dates.", call. = FALSE)
}
train_dates <- all_dates[1:56]
holdout_dates <- all_dates[57:84]

train_events <- events %>% filter(service_date %in% train_dates)
holdout_events <- events %>% filter(service_date %in% holdout_dates)
train_schedule <- schedule %>% filter(service_date %in% train_dates)
holdout_schedule <- schedule %>% filter(service_date %in% holdout_dates)

build_daily_statistics <- function(event_data, schedule_data) {
  arrival_counts <- event_data %>%
    count(service_date, period, name = "arrivals")
  service_totals <- event_data %>%
    group_by(service_date, period) %>%
    summarise(
      service_count = n(),
      total_service_hours = sum(service_hours),
      .groups = "drop"
    )

  schedule_data %>%
    select(service_date, period, observation_hours, servers_scheduled) %>%
    left_join(arrival_counts, by = c("service_date", "period")) %>%
    left_join(service_totals, by = c("service_date", "period")) %>%
    mutate(
      arrivals = replace_na(arrivals, 0L),
      service_count = replace_na(service_count, 0L),
      total_service_hours = replace_na(total_service_hours, 0)
    )
}

train_daily <- build_daily_statistics(train_events, train_schedule)
holdout_daily <- build_daily_statistics(holdout_events, holdout_schedule)

period_estimates_base <- train_daily %>%
  group_by(period) %>%
  summarise(
    training_days = n(),
    training_passengers = sum(arrivals),
    exposure_hours = sum(observation_hours),
    lambda_hat = sum(arrivals) / exposure_hours,
    mu_hat = sum(service_count) / sum(total_service_hours),
    servers = first(servers_scheduled),
    servers_consistent = n_distinct(servers_scheduled) == 1,
    .groups = "drop"
  )

if (!all(period_estimates_base$servers_consistent)) {
  stop("Server counts vary within an operating period; revise the model scope.", call. = FALSE)
}

period_metrics <- pmap_dfr(
  period_estimates_base %>% select(lambda_hat, mu_hat, servers),
  function(lambda_hat, mu_hat, servers) {
    mmc_metrics(lambda_hat, mu_hat, servers, target_minutes) %>%
      select(
        utilization,
        stable,
        probability_wait,
        model_service_level = service_level,
        model_mean_wait_minutes = expected_wait_minutes,
        model_mean_system_minutes = expected_system_minutes
      )
  }
)

period_estimates <- bind_cols(
  period_estimates_base %>% select(-servers_consistent),
  period_metrics
)

set.seed(20260829)
bootstrap_draws <- map_dfr(period_order, function(period_name) {
  period_data <- train_daily %>% filter(as.character(period) == period_name)
  servers <- unique(period_data$servers_scheduled)
  if (length(servers) != 1L) {
    stop("Bootstrap requires one staffing level per period.", call. = FALSE)
  }

  map_dfr(seq_len(bootstrap_repetitions), function(draw) {
    sampled <- period_data[sample.int(nrow(period_data), replace = TRUE), ]
    lambda_hat <- sum(sampled$arrivals) / sum(sampled$observation_hours)
    mu_hat <- sum(sampled$service_count) / sum(sampled$total_service_hours)
    metrics <- mmc_metrics(lambda_hat, mu_hat, servers, target_minutes)
    tibble(
      period = period_name,
      draw = draw,
      lambda_hat = lambda_hat,
      mu_hat = mu_hat,
      utilization = metrics$utilization,
      stable = metrics$stable,
      service_level = metrics$service_level,
      expected_wait_minutes = metrics$expected_wait_minutes
    )
  })
})

bootstrap_intervals <- bootstrap_draws %>%
  group_by(period) %>%
  summarise(
    lambda_low = quantile(lambda_hat, 0.025),
    lambda_high = quantile(lambda_hat, 0.975),
    mu_low = quantile(mu_hat, 0.025),
    mu_high = quantile(mu_hat, 0.975),
    service_level_low = quantile(service_level, 0.025, na.rm = TRUE),
    service_level_high = quantile(service_level, 0.975, na.rm = TRUE),
    mean_wait_low = quantile(expected_wait_minutes, 0.025, na.rm = TRUE),
    mean_wait_high = quantile(expected_wait_minutes, 0.975, na.rm = TRUE),
    stable_draw_fraction = mean(stable),
    .groups = "drop"
  ) %>%
  mutate(period = factor(period, levels = period_order))

holdout_summary <- holdout_daily %>%
  group_by(period) %>%
  summarise(
    holdout_days = n(),
    holdout_passengers = sum(arrivals),
    holdout_arrival_rate = sum(arrivals) / sum(observation_hours),
    holdout_service_rate = sum(service_count) / sum(total_service_hours),
    .groups = "drop"
  ) %>%
  left_join(
    holdout_events %>%
      group_by(period) %>%
      summarise(
        observed_service_level = mean(wait_minutes <= target_minutes),
        observed_mean_wait_minutes = mean(wait_minutes),
        observed_median_wait_minutes = median(wait_minutes),
        .groups = "drop"
      ),
    by = "period"
  )

holdout_validation <- period_estimates %>%
  select(
    period,
    lambda_hat,
    mu_hat,
    servers,
    model_service_level,
    model_mean_wait_minutes
  ) %>%
  left_join(bootstrap_intervals, by = "period") %>%
  left_join(holdout_summary, by = "period") %>%
  mutate(
    service_level_error_pp = 100 * (model_service_level - observed_service_level),
    absolute_service_level_error_pp = abs(service_level_error_pp),
    mean_wait_error_minutes = model_mean_wait_minutes - observed_mean_wait_minutes
  )

sensitivity_grid <- tidyr::crossing(
  period = factor(period_order, levels = period_order),
  demand_multiplier = c(0.90, 1.00, 1.10, 1.20),
  service_multiplier = c(0.90, 1.00, 1.10)
) %>%
  left_join(
    period_estimates %>% select(period, lambda_hat, mu_hat, servers),
    by = "period"
  )

sensitivity_metrics <- pmap_dfr(
  sensitivity_grid %>%
    transmute(
      lambda = lambda_hat * demand_multiplier,
      mu = mu_hat * service_multiplier,
      servers = servers
    ),
  function(lambda, mu, servers) {
    mmc_metrics(lambda, mu, servers, target_minutes) %>%
      select(utilization, stable, service_level, expected_wait_minutes)
  }
)

sensitivity <- bind_cols(sensitivity_grid, sensitivity_metrics)

staffing_recommendations <- period_estimates %>%
  transmute(
    period,
    lambda_hat,
    mu_hat,
    current_servers = servers,
    minimum_servers_baseline = map2_int(
      lambda_hat,
      mu_hat,
      ~ minimum_servers(.x, .y, target_minutes, service_level_goal)
    ),
    minimum_servers_stress = map2_int(
      lambda_hat * 1.15,
      mu_hat * 0.95,
      ~ minimum_servers(.x, .y, target_minutes, service_level_goal)
    )
  ) %>%
  mutate(
    baseline_gap = minimum_servers_baseline - current_servers,
    stress_gap = minimum_servers_stress - current_servers
  )

analysis_metadata <- tibble(
  item = c(
    "training_start",
    "training_end",
    "holdout_start",
    "holdout_end",
    "training_days",
    "holdout_days",
    "target_minutes",
    "service_level_goal",
    "bootstrap_repetitions"
  ),
  value = c(
    as.character(min(train_dates)),
    as.character(max(train_dates)),
    as.character(min(holdout_dates)),
    as.character(max(holdout_dates)),
    as.character(length(train_dates)),
    as.character(length(holdout_dates)),
    as.character(target_minutes),
    as.character(service_level_goal),
    as.character(bootstrap_repetitions)
  )
)

readr::write_csv(period_estimates, file.path(project_root, "results", "period_estimates.csv"))
readr::write_csv(bootstrap_intervals, file.path(project_root, "results", "bootstrap_intervals.csv"))
readr::write_csv(holdout_validation, file.path(project_root, "results", "holdout_validation.csv"))
readr::write_csv(sensitivity, file.path(project_root, "results", "sensitivity_analysis.csv"))
readr::write_csv(staffing_recommendations, file.path(project_root, "results", "staffing_recommendations.csv"))
readr::write_csv(analysis_metadata, file.path(project_root, "results", "analysis_metadata.csv"))

portfolio_theme <- theme_minimal(base_size = 11) +
  theme(
    plot.title.position = "plot",
    plot.title = element_text(face = "bold", color = "#17324D"),
    plot.subtitle = element_text(color = "#465866"),
    panel.grid.minor = element_blank(),
    legend.position = "bottom",
    strip.text = element_text(face = "bold")
  )

validation_plot_data <- bind_rows(
  holdout_validation %>%
    transmute(
      period,
      series = "Erlang-C prediction",
      service_level = model_service_level,
      lower = service_level_low,
      upper = service_level_high
    ),
  holdout_validation %>%
    transmute(
      period,
      series = "Temporal holdout",
      service_level = observed_service_level,
      lower = NA_real_,
      upper = NA_real_
    )
)

p_validation <- ggplot(
  validation_plot_data,
  aes(x = period, y = service_level, color = series, shape = series)
) +
  geom_hline(
    yintercept = service_level_goal,
    linetype = "dashed",
    linewidth = 0.5,
    color = "#9C2F2F"
  ) +
  geom_errorbar(
    aes(ymin = lower, ymax = upper),
    width = 0.12,
    linewidth = 0.6,
    na.rm = TRUE,
    position = position_dodge(width = 0.35)
  ) +
  geom_point(size = 3, position = position_dodge(width = 0.35)) +
  scale_color_manual(values = c("Erlang-C prediction" = "#136F8A", "Temporal holdout" = "#E07A3F")) +
  scale_y_continuous(
    limits = c(0, 1),
    labels = function(x) paste0(round(100 * x), "%")
  ) +
  labs(
    title = "Predicted service level compared with the chronological holdout",
    subtitle = "Error bars show 95% training parameter-bootstrap bands; dashed line is the 85% goal",
    x = NULL,
    y = "Passengers waiting 10 minutes or less",
    color = NULL,
    shape = NULL
  ) +
  portfolio_theme

ggsave(
  file.path(project_root, "figures", "holdout_validation.png"),
  p_validation,
  width = 9,
  height = 5.2,
  dpi = 180
)

p_sensitivity <- sensitivity %>%
  mutate(
    demand_label = factor(
      paste0(round(100 * demand_multiplier), "%"),
      levels = c("90%", "100%", "110%", "120%")
    ),
    service_label = factor(
      paste0(round(100 * service_multiplier), "%"),
      levels = c("90%", "100%", "110%")
    )
  ) %>%
  ggplot(aes(x = demand_label, y = service_label, fill = service_level)) +
  geom_tile(color = "white", linewidth = 0.8) +
  geom_text(
    aes(label = if_else(stable, paste0(round(100 * service_level), "%"), "Unstable")),
    size = 3
  ) +
  facet_wrap(~period, ncol = 2) +
  scale_fill_gradient2(
    low = "#C65353",
    mid = "#F3D58A",
    high = "#4C9B72",
    midpoint = service_level_goal,
    limits = c(0, 1),
    na.value = "#D5D8DC",
    labels = function(x) paste0(round(100 * x), "%")
  ) +
  labs(
    title = "Service levels are sensitive near capacity",
    subtitle = "Rows vary service speed; columns vary passenger demand relative to training estimates",
    x = "Demand multiplier",
    y = "Service-rate multiplier",
    fill = "10-minute\nservice level"
  ) +
  portfolio_theme

ggsave(
  file.path(project_root, "figures", "sensitivity_heatmap.png"),
  p_sensitivity,
  width = 9,
  height = 6.8,
  dpi = 180
)

staffing_plot_data <- staffing_recommendations %>%
  select(period, current_servers, minimum_servers_baseline, minimum_servers_stress) %>%
  pivot_longer(-period, names_to = "scenario", values_to = "servers") %>%
  mutate(
    scenario = recode(
      scenario,
      current_servers = "Current schedule",
      minimum_servers_baseline = "Minimum at baseline",
      minimum_servers_stress = "Minimum under stress"
    ),
    scenario = factor(
      scenario,
      levels = c("Current schedule", "Minimum at baseline", "Minimum under stress")
    )
  )

p_staffing <- ggplot(staffing_plot_data, aes(x = period, y = servers, fill = scenario)) +
  geom_col(position = position_dodge(width = 0.78), width = 0.7) +
  geom_text(
    aes(label = servers),
    position = position_dodge(width = 0.78),
    vjust = -0.3,
    size = 3.2
  ) +
  scale_fill_manual(values = c("#657786", "#2A8093", "#E07A3F")) +
  scale_y_continuous(breaks = seq(0, 10, 1), expand = expansion(mult = c(0, 0.08))) +
  labs(
    title = "Stress conditions create a staffing buffer requirement",
    subtitle = "Stress case assumes 15% more demand and 5% slower service",
    x = NULL,
    y = "Parallel screening servers",
    fill = NULL
  ) +
  portfolio_theme

ggsave(
  file.path(project_root, "figures", "staffing_scenarios.png"),
  p_staffing,
  width = 9,
  height = 5.2,
  dpi = 180
)

p_ecdf <- ggplot(
  holdout_events,
  aes(x = pmin(wait_minutes, 30), color = period)
) +
  stat_ecdf(geom = "step", linewidth = 0.9) +
  geom_vline(xintercept = target_minutes, linetype = "dashed", color = "#9C2F2F") +
  coord_cartesian(xlim = c(0, 30), ylim = c(0, 1)) +
  scale_y_continuous(labels = function(x) paste0(round(100 * x), "%")) +
  labs(
    title = "Holdout waiting-time distributions differ by operating period",
    subtitle = "Values above 30 minutes are displayed at 30; dashed line is the 10-minute target",
    x = "Queue wait (minutes)",
    y = "Cumulative share of passengers",
    color = NULL
  ) +
  portfolio_theme

ggsave(
  file.path(project_root, "figures", "holdout_wait_ecdf.png"),
  p_ecdf,
  width = 9,
  height = 5.2,
  dpi = 180
)

message(sprintf(
  "Estimated M/M/c models on %d training days and validated on %d holdout days.",
  length(train_dates),
  length(holdout_dates)
))
