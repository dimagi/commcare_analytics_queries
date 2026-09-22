--BigQuery query name: CommCare Crash & Usage Metrics : Alter History Table (2026-09-22)
--
-- Brings the table created on 2026-09-21 in line with the folded segments.
-- One-off; crash_usage_history_table.sql already reflects the end state.

ALTER TABLE `commcare-a57e4.mobile_metrics.crash_usage_history`
  ADD COLUMN IF NOT EXISTS unmatched_affected_users INT64
  OPTIONS(description = "Of affected_users, how many came from devices with no GA4 match. These are counted as non-connect but are absent from total_users, so they bias free_users_pct down. NULL for all-by-installation");

ALTER TABLE `commcare-a57e4.mobile_metrics.crash_usage_history`
  ALTER COLUMN user_segment SET OPTIONS(description = "all-by-device, all-by-installation, connect, connect-demo or non-connect. all-by-device and the three breakdown segments count users by the device_id custom key and reconcile exactly; all-by-installation counts Crashlytics installation_uuid over GA4 user_pseudo_id and is the console-comparable figure, and the only one available for lts");

ALTER TABLE `commcare-a57e4.mobile_metrics.crash_usage_history`
  ALTER COLUMN total_users SET OPTIONS(description = "Unique active users in the window; NULL for lts");

ALTER TABLE `commcare-a57e4.mobile_metrics.crash_usage_history`
  ALTER COLUMN unmatched_affected_users SET OPTIONS(description = "Of affected_users, how many came from devices with no GA4 match. These are counted as non-connect but are absent from total_users, so they bias free_users_pct down. NULL for all-by-installation");

ALTER TABLE `commcare-a57e4.mobile_metrics.crash_usage_history`
  DROP COLUMN IF EXISTS id_basis;

ALTER TABLE `commcare-a57e4.mobile_metrics.crash_usage_history`
  ADD COLUMN IF NOT EXISTS app_version STRING
  OPTIONS(description = "The app version the events occurred on, e.g. 2.63.5, from Crashlytics application.display_version and GA4 app_info.version. 'all' is the rolled-up row across every version. total_events sums exactly from the per-version rows to the 'all' row; affected_users and total_users do NOT, because a user who upgrades mid-window is counted under every version they ran");

ALTER TABLE `commcare-a57e4.mobile_metrics.crash_usage_history`
  ALTER COLUMN app_version SET OPTIONS(description = "The app version the events occurred on, e.g. 2.63.5, from Crashlytics application.display_version and GA4 app_info.version. 'all' is the rolled-up row across every version. total_events sums exactly from the per-version rows to the 'all' row; affected_users and total_users do NOT, because a user who upgrades mid-window is counted under every version they ran");

-- Note: because unmatched_affected_users was added by ALTER it sits last in the live
-- table, while crash_usage_history_table.sql lists it next to total_users. Cosmetic
-- only - the insert names its columns.
