# Change log from the earlier coursework concept

This repository is a clean-room portfolio rewrite. The original R Markdown files and BASA data were not copied or modified.

## Data governance

- Replaced instructor/course data with an explicit synthetic event generator.
- Removed real or course-specific airport labels, passenger records, names, and student identifiers.
- Added a data dictionary, provenance note, fixed seed, and clear CC0 designation for generated CSVs.
- Kept the original assignment and teammates' files outside this repository.

## Queueing model

- Replaced the effective M/M/1 approximation with an M/M/c Erlang-C model for parallel screening servers.
- Estimated arrival rate from passenger counts divided by scheduled exposure hours.
- Estimated per-server service rate from independent service-start and service-end timestamps.
- Stopped using observed waiting time to back-solve service capacity, avoiding circular validation.
- Added explicit stability checks for `rho = lambda / (c * mu)` and no finite steady-state metric when `rho >= 1`.
- Evaluated the Erlang-C normalizing sum on the log scale for numerical stability.
- Added the probability of waiting, target service level, expected queue wait, and expected total system time.

## Validation and uncertainty

- Reserved the first 56 dates for model estimation and the final 28 dates for chronological holdout validation.
- Used waiting timestamps only after fitting to compare predicted and observed service levels.
- Added 500 nonparametric bootstrap samples of whole service dates.
- Reported the peak-period validation gaps instead of hiding them; point errors are larger near capacity but holdout values remain inside the bootstrap ranges.
- Added unit-style tests for the M/M/1 special case, monotonicity, zero arrivals, unstable systems, and minimum-server search.

## Decision support

- Added an 85%-within-10-minutes service-level target.
- Added baseline minimum-server calculations.
- Added a documented stress case with 15% higher demand and 5% slower service.
- Added a demand/service sensitivity grid that labels unstable conditions.
- Framed staffing outputs as scenarios rather than causal prescriptions.

## Portfolio quality

- Split reusable functions, data generation, analysis, report source, tests, figures, and results into a conventional repository structure.
- Added one-command regeneration through `Rscript scripts/run_all.R`.
- Added a self-contained HTML report, four figures, CSV outputs, session information, and a project README.
- Documented model assumptions, external-validity limits, synthetic scope, AI assistance, and the need for a personal contribution statement.


