args <- commandArgs(trailingOnly = FALSE)
script_arg <- grep("^--file=", args, value = TRUE)
script_path <- normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)

source(file.path(project_root, "R", "queueing_functions.R"))

# Erlang C reduces to rho for an M/M/1 queue.
lambda <- 4
mu <- 5
metrics_mmc1 <- mmc_metrics(lambda, mu, servers = 1, target_minutes = 10)
stopifnot(abs(metrics_mmc1$probability_wait - lambda / mu) < 1e-12)
expected_wq_minutes <- 60 * (lambda / mu) / (mu - lambda)
stopifnot(abs(metrics_mmc1$expected_wait_minutes - expected_wq_minutes) < 1e-12)

# More servers should improve service level under the same demand and service rate.
service_levels <- vapply(
  4:7,
  function(c) mmc_metrics(48, 15, c, target_minutes = 10)$service_level,
  numeric(1)
)
stopifnot(all(diff(service_levels) > 0))

# More demand should reduce service level when staffing is fixed.
demand_levels <- vapply(
  c(40, 50, 60),
  function(rate) mmc_metrics(rate, 15, 5, target_minutes = 10)$service_level,
  numeric(1)
)
stopifnot(all(diff(demand_levels) < 0))

# Unstable systems should not report a finite steady-state wait distribution.
unstable <- mmc_metrics(80, 15, 5, target_minutes = 10)
stopifnot(!unstable$stable, is.na(unstable$service_level), is.infinite(unstable$expected_wait_minutes))

# Zero arrivals should imply no queueing delay.
empty <- mmc_metrics(0, 15, 2, target_minutes = 10)
stopifnot(empty$service_level == 1, empty$expected_wait_minutes == 0)

# The staffing search must return a solution that reaches the requested goal.
required <- minimum_servers(70, 15, target_minutes = 10, service_level_goal = 0.85)
stopifnot(!is.na(required))
stopifnot(mmc_metrics(70, 15, required, 10)$service_level >= 0.85)
if (required > 1) {
  prior <- mmc_metrics(70, 15, required - 1, 10)
  stopifnot(!prior$stable || prior$service_level < 0.85)
}

message("All queueing-function tests passed.")
