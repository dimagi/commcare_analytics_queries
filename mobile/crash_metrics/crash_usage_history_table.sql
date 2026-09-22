--BigQuery query name: CommCare Crash & Usage Metrics : Create History Table

CREATE TABLE IF NOT EXISTS `commcare-a57e4.mobile_metrics.crash_usage_history`
(
  run_date       DATE     NOT NULL OPTIONS(description = "Date the populating query ran"),
  app            STRING   NOT NULL OPTIONS(description = "commcare (org.commcare.dalvik) or lts (org.commcare.lts)"),
  user_segment   STRING   NOT NULL OPTIONS(description = "all-by-device, all-by-installation, connect, connect_demo or non_connect. all-by-device and the three breakdown segments count users by the device_id custom key and reconcile exactly; all-by-installation counts Crashlytics installation_uuid over GA4 user_pseudo_id and is the console-comparable figure, and the only one available for lts"),
  window_days    INT64    NOT NULL OPTIONS(description = "Length of the lookback window, 30 or 90"),
  error_type     STRING   NOT NULL OPTIONS(description = "FATAL (a crash) or ANR"),
  window_start   DATE     NOT NULL OPTIONS(description = "First day of the window, inclusive"),
  window_end     DATE     NOT NULL OPTIONS(description = "Last day of the window, inclusive; held back from today by data_lag_days"),
  total_events   INT64    OPTIONS(description = "Total crashes or ANRs in the window"),
  affected_users INT64    OPTIONS(description = "Unique crashing or ANR-ing users in the window"),
  total_users    INT64    OPTIONS(description = "Unique active users in the window; NULL for lts"),
  unmatched_affected_users INT64 OPTIONS(description = "Of affected_users, how many came from devices with no GA4 match. These are counted as non_connect but are absent from total_users, so they bias free_users_pct down. NULL for all-by-installation"),
  free_users_pct FLOAT64  OPTIONS(description = "100 * (1 - affected_users / total_users)"),
  days_covered   INT64    OPTIONS(description = "Days of Crashlytics history actually present; below window_days means the export does not reach back far enough yet"),
  inserted_at    TIMESTAMP OPTIONS(description = "When the row was written")
)
PARTITION BY run_date
CLUSTER BY app, error_type
OPTIONS(
  description = "One row per app x segment x window x event type per run. Written by crash_usage_history_insert.sql; see mobile/crash_metrics/README.md in commcare-analytics-queries."
);
