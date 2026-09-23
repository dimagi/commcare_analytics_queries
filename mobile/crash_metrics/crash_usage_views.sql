--BigQuery query name: CommCare Crash & Usage Metrics : Helper Views
--
-- One view per app x error type. Each row is one run_date, pivoted so that a
-- segment/window combination is a column. Rolled-up versions only
-- (app_version = 'all'); the per-version rows stay in the table.

CREATE OR REPLACE VIEW `commcare-a57e4.mobile_metrics.view_commcare_fatal_daily`
OPTIONS(description = "Daily crash-free percentages for CommCare, rolled up across app versions. One row per run_date; each column is a user segment at a 30 or 90 day window.")
AS
SELECT
  run_date,
  ANY_VALUE(window_end) AS window_end,
  MAX(IF(window_days = 30 AND user_segment = 'all-by-device', free_users_pct, NULL)) AS all_by_device_30d,
  MAX(IF(window_days = 30 AND user_segment = 'all-by-installation', free_users_pct, NULL)) AS all_by_installation_30d,
  MAX(IF(window_days = 30 AND user_segment = 'connect', free_users_pct, NULL)) AS connect_30d,
  MAX(IF(window_days = 30 AND user_segment = 'connect-demo', free_users_pct, NULL)) AS connect_demo_30d,
  MAX(IF(window_days = 30 AND user_segment = 'non-connect', free_users_pct, NULL)) AS non_connect_30d,
  MAX(IF(window_days = 90 AND user_segment = 'all-by-device', free_users_pct, NULL)) AS all_by_device_90d,
  MAX(IF(window_days = 90 AND user_segment = 'all-by-installation', free_users_pct, NULL)) AS all_by_installation_90d,
  MAX(IF(window_days = 90 AND user_segment = 'connect', free_users_pct, NULL)) AS connect_90d,
  MAX(IF(window_days = 90 AND user_segment = 'connect-demo', free_users_pct, NULL)) AS connect_demo_90d,
  MAX(IF(window_days = 90 AND user_segment = 'non-connect', free_users_pct, NULL)) AS non_connect_90d
FROM `commcare-a57e4.mobile_metrics.crash_usage_history`
WHERE app = 'commcare' AND error_type = 'FATAL' AND app_version = 'all'
GROUP BY run_date;

CREATE OR REPLACE VIEW `commcare-a57e4.mobile_metrics.view_lts_fatal_daily`
OPTIONS(description = "Daily crash counts for CommCare LTS, rolled up across app versions. Counts rather than percentages: org.commcare.lts has effectively no GA4 stream, so there is no user denominator and free_users_pct is always NULL for it.")
AS
SELECT
  run_date,
  ANY_VALUE(window_end) AS window_end,
  MAX(IF(window_days = 30, total_events, NULL)) AS events_30d,
  MAX(IF(window_days = 30, affected_users, NULL)) AS affected_users_30d,
  MAX(IF(window_days = 90, total_events, NULL)) AS events_90d,
  MAX(IF(window_days = 90, affected_users, NULL)) AS affected_users_90d
FROM `commcare-a57e4.mobile_metrics.crash_usage_history`
WHERE app = 'lts' AND error_type = 'FATAL' AND app_version = 'all'
GROUP BY run_date;

CREATE OR REPLACE VIEW `commcare-a57e4.mobile_metrics.view_commcare_anr_daily`
OPTIONS(description = "Daily ANR-free percentages for CommCare, rolled up across app versions. One row per run_date; each column is a user segment at a 30 or 90 day window.")
AS
SELECT
  run_date,
  ANY_VALUE(window_end) AS window_end,
  MAX(IF(window_days = 30 AND user_segment = 'all-by-device', free_users_pct, NULL)) AS all_by_device_30d,
  MAX(IF(window_days = 30 AND user_segment = 'all-by-installation', free_users_pct, NULL)) AS all_by_installation_30d,
  MAX(IF(window_days = 30 AND user_segment = 'connect', free_users_pct, NULL)) AS connect_30d,
  MAX(IF(window_days = 30 AND user_segment = 'connect-demo', free_users_pct, NULL)) AS connect_demo_30d,
  MAX(IF(window_days = 30 AND user_segment = 'non-connect', free_users_pct, NULL)) AS non_connect_30d,
  MAX(IF(window_days = 90 AND user_segment = 'all-by-device', free_users_pct, NULL)) AS all_by_device_90d,
  MAX(IF(window_days = 90 AND user_segment = 'all-by-installation', free_users_pct, NULL)) AS all_by_installation_90d,
  MAX(IF(window_days = 90 AND user_segment = 'connect', free_users_pct, NULL)) AS connect_90d,
  MAX(IF(window_days = 90 AND user_segment = 'connect-demo', free_users_pct, NULL)) AS connect_demo_90d,
  MAX(IF(window_days = 90 AND user_segment = 'non-connect', free_users_pct, NULL)) AS non_connect_90d
FROM `commcare-a57e4.mobile_metrics.crash_usage_history`
WHERE app = 'commcare' AND error_type = 'ANR' AND app_version = 'all'
GROUP BY run_date;

CREATE OR REPLACE VIEW `commcare-a57e4.mobile_metrics.view_lts_anr_daily`
OPTIONS(description = "Daily ANR counts for CommCare LTS, rolled up across app versions. Counts rather than percentages: org.commcare.lts has effectively no GA4 stream, so there is no user denominator and free_users_pct is always NULL for it.")
AS
SELECT
  run_date,
  ANY_VALUE(window_end) AS window_end,
  MAX(IF(window_days = 30, total_events, NULL)) AS events_30d,
  MAX(IF(window_days = 30, affected_users, NULL)) AS affected_users_30d,
  MAX(IF(window_days = 90, total_events, NULL)) AS events_90d,
  MAX(IF(window_days = 90, affected_users, NULL)) AS affected_users_90d
FROM `commcare-a57e4.mobile_metrics.crash_usage_history`
WHERE app = 'lts' AND error_type = 'ANR' AND app_version = 'all'
GROUP BY run_date;

CREATE OR REPLACE VIEW `commcare-a57e4.mobile_metrics.view_commcare_non_fatal_daily`
OPTIONS(description = "Daily non-fatal figures for CommCare, rolled up across app versions. NOTE: the percentages here sit near 29 and barely move, because most users log an exception in any window. Read total_events / affected_users from the base table instead; see README.")
AS
SELECT
  run_date,
  ANY_VALUE(window_end) AS window_end,
  MAX(IF(window_days = 30 AND user_segment = 'all-by-device', free_users_pct, NULL)) AS all_by_device_30d,
  MAX(IF(window_days = 30 AND user_segment = 'all-by-installation', free_users_pct, NULL)) AS all_by_installation_30d,
  MAX(IF(window_days = 30 AND user_segment = 'connect', free_users_pct, NULL)) AS connect_30d,
  MAX(IF(window_days = 30 AND user_segment = 'connect-demo', free_users_pct, NULL)) AS connect_demo_30d,
  MAX(IF(window_days = 30 AND user_segment = 'non-connect', free_users_pct, NULL)) AS non_connect_30d,
  MAX(IF(window_days = 90 AND user_segment = 'all-by-device', free_users_pct, NULL)) AS all_by_device_90d,
  MAX(IF(window_days = 90 AND user_segment = 'all-by-installation', free_users_pct, NULL)) AS all_by_installation_90d,
  MAX(IF(window_days = 90 AND user_segment = 'connect', free_users_pct, NULL)) AS connect_90d,
  MAX(IF(window_days = 90 AND user_segment = 'connect-demo', free_users_pct, NULL)) AS connect_demo_90d,
  MAX(IF(window_days = 90 AND user_segment = 'non-connect', free_users_pct, NULL)) AS non_connect_90d
FROM `commcare-a57e4.mobile_metrics.crash_usage_history`
WHERE app = 'commcare' AND error_type = 'NON_FATAL' AND app_version = 'all'
GROUP BY run_date;

CREATE OR REPLACE VIEW `commcare-a57e4.mobile_metrics.view_lts_non_fatal_daily`
OPTIONS(description = "Daily logged-exception counts for CommCare LTS, rolled up across app versions. Counts rather than percentages: org.commcare.lts has effectively no GA4 stream, so there is no user denominator and free_users_pct is always NULL for it.")
AS
SELECT
  run_date,
  ANY_VALUE(window_end) AS window_end,
  MAX(IF(window_days = 30, total_events, NULL)) AS events_30d,
  MAX(IF(window_days = 30, affected_users, NULL)) AS affected_users_30d,
  MAX(IF(window_days = 90, total_events, NULL)) AS events_90d,
  MAX(IF(window_days = 90, affected_users, NULL)) AS affected_users_90d
FROM `commcare-a57e4.mobile_metrics.crash_usage_history`
WHERE app = 'lts' AND error_type = 'NON_FATAL' AND app_version = 'all'
GROUP BY run_date;

CREATE OR REPLACE VIEW `commcare-a57e4.mobile_metrics.view_commcare_version_lifecycle`
OPTIONS(description = "One row per CommCare app version (the rolled-up 'all' row excluded), giving the span over which that version was seen carrying users. Usage is read from user_segment = 'all-by-device' at window_days = 30, which is the most responsive signal - a 90 day window keeps a version looking alive for three months after its last use. Days are run_date, so they lag the underlying data by data_lag_days. Only versions that produced at least one crash, ANR or logged exception appear at all, since the crash side drives which rows exist.")
AS
WITH daily AS (
  -- total_users does not vary by error_type for a given version, segment and
  -- window, so collapsing them here is lossless.
  SELECT
    app_version,
    run_date,
    MAX(total_users) AS total_users
  FROM `commcare-a57e4.mobile_metrics.crash_usage_history`
  WHERE app = 'commcare'
    AND app_version != 'all'
    AND user_segment = 'all-by-device'
    AND window_days = 30
    AND total_users > 0
  GROUP BY app_version, run_date
)
SELECT
  app_version,
  MIN(run_date) AS first_day,
  MAX(run_date) AS last_day,
  ARRAY_AGG(run_date ORDER BY total_users DESC, run_date ASC LIMIT 1)[OFFSET(0)] AS peak_day,
  MAX(total_users) AS peak_total_users,
  COUNT(DISTINCT run_date) AS days_observed
FROM daily
GROUP BY app_version;
