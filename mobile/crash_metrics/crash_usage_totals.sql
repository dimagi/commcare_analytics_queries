--BigQuery query name: CommCare Crash & Usage Metrics : Totals Across Versions

-- The pre-version view: one row per app x segment x window x event type.
--
-- This filters to the rolled-up rows rather than summing the per-version ones.
-- Summing would be wrong for the user columns: a user who upgrades mid-window ran
-- more than one version and is counted under each, which overstates
-- affected_users and total_users by roughly 25% (crashes) to 44% (ANRs) over a 90
-- day window. total_events would sum correctly, the user columns would not.

DECLARE target_run_date DATE DEFAULT NULL;

SELECT
  run_date,
  app,
  user_segment,
  window_days,
  error_type,
  window_start,
  window_end,
  total_events,
  affected_users,
  total_users,
  unmatched_affected_users,
  free_users_pct,
  days_covered
FROM `commcare-a57e4.mobile_metrics.crash_usage_history`
WHERE app_version = 'all'
  AND run_date = IFNULL(
        target_run_date,
        (SELECT MAX(run_date) FROM `commcare-a57e4.mobile_metrics.crash_usage_history`)
      )
ORDER BY app, window_days, error_type, user_segment;
