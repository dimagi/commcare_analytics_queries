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

CREATE OR REPLACE VIEW `commcare-a57e4.mobile_metrics.view_commcare_version_summary`
OPTIONS(description = "One row per CommCare app version summarising its health at the latest run_date, from user_segment = 'all-by-device' at window_days = 30. Carries size (users_30d, pct_of_fleet), health (crash_free_pct, anr_free_pct), the same health as a delta against a user-weighted mean across versions (_vs_typical_pp), and rates that are comparable across versions of different sizes. Non-fatals are given as events per affected user rather than a percentage, which for them is near-flat. Versions with no matching GA4 users show NULL rates.")
AS
WITH latest AS (
  SELECT MAX(run_date) AS run_date
  FROM `commcare-a57e4.mobile_metrics.crash_usage_history`
  WHERE app = 'commcare'
),
snap AS (
  SELECT h.*
  FROM `commcare-a57e4.mobile_metrics.crash_usage_history` h
  JOIN latest l USING (run_date)
  WHERE h.app = 'commcare'
    AND h.user_segment = 'all-by-device'
    AND h.window_days = 30
),
-- The 'all' row is the deduplicated fleet. Used for share of fleet only: it is not a
-- fair health baseline, because it counts a user once while the per-version rows count
-- them under each version they ran, which makes almost every version look better than it.
fleet AS (
  SELECT MAX(total_users) AS users
  FROM snap
  WHERE app_version = 'all'
),
per_version AS (
  SELECT
    app_version,
    MAX(total_users) AS users_30d,
    MAX(days_covered) AS days_covered,
    MAX(IF(error_type = 'FATAL', total_events, NULL)) AS crashes_30d,
    MAX(IF(error_type = 'FATAL', affected_users, NULL)) AS crash_users_30d,
    MAX(IF(error_type = 'FATAL', free_users_pct, NULL)) AS crash_free_pct,
    MAX(IF(error_type = 'ANR', total_events, NULL)) AS anrs_30d,
    MAX(IF(error_type = 'ANR', free_users_pct, NULL)) AS anr_free_pct,
    MAX(IF(error_type = 'NON_FATAL', total_events, NULL)) AS nonfatals_30d,
    MAX(IF(error_type = 'NON_FATAL', affected_users, NULL)) AS nonfatal_users_30d
  FROM snap
  WHERE app_version != 'all'
  GROUP BY app_version
),

-- User-weighted mean across versions: like for like with the per-version figures, so a
-- delta against it centres on zero and says "better or worse than a typical version".
baseline AS (
  SELECT
    SAFE_DIVIDE(SUM(crash_free_pct * users_30d), SUM(users_30d)) AS crash_free_pct,
    SAFE_DIVIDE(SUM(anr_free_pct * users_30d), SUM(users_30d)) AS anr_free_pct
  FROM per_version
  WHERE users_30d > 0
)

SELECT
  (SELECT run_date FROM latest) AS run_date,
  v.app_version,
  v.users_30d,
  ROUND(100 * SAFE_DIVIDE(v.users_30d, f.users), 1) AS pct_of_fleet,
  v.crash_free_pct,
  ROUND(v.crash_free_pct - b.crash_free_pct, 2) AS crash_free_vs_typical_pp,
  v.anr_free_pct,
  ROUND(v.anr_free_pct - b.anr_free_pct, 2) AS anr_free_vs_typical_pp,
  ROUND(1000 * SAFE_DIVIDE(v.crashes_30d, v.users_30d), 1) AS crashes_per_1k_users,
  ROUND(1000 * SAFE_DIVIDE(v.anrs_30d, v.users_30d), 1) AS anrs_per_1k_users,
  ROUND(SAFE_DIVIDE(v.nonfatals_30d, v.nonfatal_users_30d), 1) AS nonfatals_per_affected_user,
  v.crashes_30d,
  v.anrs_30d,
  v.days_covered
FROM per_version v
CROSS JOIN fleet f
CROSS JOIN baseline b;
