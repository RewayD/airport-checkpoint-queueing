# Synthetic data documentation

Both CSV files in this directory are generated from a fixed random seed by [`../scripts/01_generate_synthetic_data.R`](../scripts/01_generate_synthetic_data.R). They are fictional and contain no real airport, passenger, employee, course, or student information.

## `synthetic_checkpoint_events.csv`

One row represents one synthetic passenger arrival during a measured two-hour operating window.

| Field | Meaning |
|---|---|
| `passenger_id` | Deterministic synthetic identifier; not linked to a person |
| `service_date` | Fictional operating date |
| `period` | Morning peak, midday, afternoon peak, or evening |
| `arrival_time` | Time the passenger enters the queue, in UTC |
| `service_start_time` | Time screening begins, in UTC |
| `service_end_time` | Time screening ends, in UTC |
| `server_id` | Synthetic parallel-server number within the window |
| `servers_scheduled` | Number of servers available in that operating period |

Queue wait and service duration are intentionally not stored as inputs. The analysis derives them from separate timestamps.

## `synthetic_window_schedule.csv`

One row represents one measured operating window. It records the date, period, day type, opening and closing timestamps, exposure hours, and scheduled server count. It does not reveal precomputed arrival or service-rate estimates.

## Generator design

The generator simulates a first-come, first-served M/M/c queue with constant rates inside each operating period. It simulates a two-hour warm-up interval and discards those arrivals before saving the measured two-hour window. The latent parameter values remain visible in source control so the dataset is fully reproducible, but the analysis estimates them from released event timestamps.

The generator's one-second minimum service duration prevents sub-second exponential draws from becoming zero after CSV timestamps are serialized to seconds. This floor is negligible compared with the four-minute mean service time.

## Reuse

The generated CSV files are dedicated to the public domain under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). Regenerate them rather than editing them manually.
