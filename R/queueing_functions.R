# Core M/M/c queueing functions used throughout the portfolio analysis.
#
# Rates are expressed per hour. Waiting-time targets are expressed in minutes.

assert_positive_scalar <- function(x, name, allow_zero = FALSE) {
  valid <- is.numeric(x) && length(x) == 1L && is.finite(x)
  valid <- valid && if (allow_zero) x >= 0 else x > 0
  if (!valid) {
    comparator <- if (allow_zero) "non-negative" else "positive"
    stop(sprintf("`%s` must be a finite %s numeric scalar.", name, comparator), call. = FALSE)
  }
}

assert_server_count <- function(servers) {
  assert_positive_scalar(servers, "servers")
  if (servers != as.integer(servers)) {
    stop("`servers` must be a positive integer.", call. = FALSE)
  }
}

log_sum_exp <- function(x) {
  anchor <- max(x)
  anchor + log(sum(exp(x - anchor)))
}

# Probability that an arrival must wait in a stable M/M/c system (Erlang C).
erlang_c_probability <- function(lambda, mu, servers) {
  assert_positive_scalar(lambda, "lambda", allow_zero = TRUE)
  assert_positive_scalar(mu, "mu")
  assert_server_count(servers)

  servers <- as.integer(servers)
  if (lambda == 0) {
    return(0)
  }

  offered_load <- lambda / mu
  utilization <- offered_load / servers
  if (utilization >= 1) {
    return(NA_real_)
  }

  log_regular_terms <- vapply(
    0:(servers - 1L),
    function(k) k * log(offered_load) - lgamma(k + 1),
    numeric(1)
  )
  log_wait_term <- servers * log(offered_load) -
    lgamma(servers + 1) - log1p(-utilization)

  exp(log_wait_term - log_sum_exp(c(log_regular_terms, log_wait_term)))
}

# Return the main steady-state M/M/c quantities for one operating condition.
mmc_metrics <- function(lambda, mu, servers, target_minutes = 10) {
  assert_positive_scalar(lambda, "lambda", allow_zero = TRUE)
  assert_positive_scalar(mu, "mu")
  assert_server_count(servers)
  assert_positive_scalar(target_minutes, "target_minutes", allow_zero = TRUE)

  servers <- as.integer(servers)
  utilization <- lambda / (servers * mu)
  stable <- utilization < 1

  if (!stable) {
    return(data.frame(
      lambda = lambda,
      mu = mu,
      servers = servers,
      utilization = utilization,
      stable = FALSE,
      probability_wait = NA_real_,
      service_level = NA_real_,
      expected_wait_minutes = Inf,
      expected_system_minutes = Inf
    ))
  }

  probability_wait <- erlang_c_probability(lambda, mu, servers)
  spare_rate <- servers * mu - lambda
  service_level <- 1 - probability_wait * exp(-spare_rate * target_minutes / 60)
  expected_wait_minutes <- if (lambda == 0) 0 else 60 * probability_wait / spare_rate

  data.frame(
    lambda = lambda,
    mu = mu,
    servers = servers,
    utilization = utilization,
    stable = TRUE,
    probability_wait = probability_wait,
    service_level = service_level,
    expected_wait_minutes = expected_wait_minutes,
    expected_system_minutes = expected_wait_minutes + 60 / mu
  )
}

# Smallest server count that satisfies both stability and the service-level goal.
minimum_servers <- function(lambda, mu, target_minutes = 10,
                            service_level_goal = 0.85, max_servers = 50L) {
  assert_positive_scalar(lambda, "lambda", allow_zero = TRUE)
  assert_positive_scalar(mu, "mu")
  assert_positive_scalar(target_minutes, "target_minutes", allow_zero = TRUE)
  assert_positive_scalar(service_level_goal, "service_level_goal")
  if (service_level_goal > 1) {
    stop("`service_level_goal` cannot exceed 1.", call. = FALSE)
  }
  assert_server_count(max_servers)

  for (servers in seq_len(as.integer(max_servers))) {
    metrics <- mmc_metrics(lambda, mu, servers, target_minutes)
    if (metrics$stable && metrics$service_level >= service_level_goal) {
      return(servers)
    }
  }

  NA_integer_
}

# Simulate a constant-rate M/M/c window. A warm-up interval is generated but
# excluded from the returned event data so the measured interval starts closer
# to steady state.
simulate_mmc_window <- function(service_date, period, start_hour, lambda, mu,
                                servers, observation_hours = 2,
                                warmup_hours = 1, timezone = "UTC") {
  assert_positive_scalar(start_hour, "start_hour", allow_zero = TRUE)
  assert_positive_scalar(lambda, "lambda")
  assert_positive_scalar(mu, "mu")
  assert_server_count(servers)
  assert_positive_scalar(observation_hours, "observation_hours")
  assert_positive_scalar(warmup_hours, "warmup_hours", allow_zero = TRUE)

  service_date <- as.Date(service_date)
  window_start <- as.POSIXct(service_date, tz = timezone) + start_hour * 3600
  simulation_start <- window_start - warmup_hours * 3600
  window_end <- window_start + observation_hours * 3600

  arrival_seconds <- numeric(0)
  next_arrival <- as.numeric(simulation_start)
  while (TRUE) {
    next_arrival <- next_arrival + stats::rexp(1, rate = lambda / 3600)
    if (next_arrival >= as.numeric(window_end)) {
      break
    }
    arrival_seconds <- c(arrival_seconds, next_arrival)
  }

  available_at <- rep(as.numeric(simulation_start), as.integer(servers))
  service_start <- service_end <- numeric(length(arrival_seconds))
  server_id <- integer(length(arrival_seconds))

  for (i in seq_along(arrival_seconds)) {
    selected_server <- which.min(available_at)
    service_start[i] <- max(arrival_seconds[i], available_at[selected_server])
    # CSV timestamps are stored to the nearest second. The one-second floor
    # prevents a very short exponential draw from collapsing to zero duration
    # after serialization; it is negligible relative to the four-minute mean.
    service_duration <- max(stats::rexp(1, rate = mu / 3600), 1)
    service_end[i] <- service_start[i] + service_duration
    available_at[selected_server] <- service_end[i]
    server_id[i] <- selected_server
  }

  keep <- arrival_seconds >= as.numeric(window_start)
  arrival_seconds <- arrival_seconds[keep]
  service_start <- service_start[keep]
  service_end <- service_end[keep]
  server_id <- server_id[keep]

  data.frame(
    service_date = service_date,
    period = period,
    arrival_time = as.POSIXct(arrival_seconds, origin = "1970-01-01", tz = timezone),
    service_start_time = as.POSIXct(service_start, origin = "1970-01-01", tz = timezone),
    service_end_time = as.POSIXct(service_end, origin = "1970-01-01", tz = timezone),
    server_id = server_id,
    servers_scheduled = as.integer(servers),
    stringsAsFactors = FALSE
  )
}
