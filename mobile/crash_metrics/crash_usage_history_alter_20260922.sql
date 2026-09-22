--BigQuery query name: CommCare Crash & Usage Metrics : Alter History Table (2026-09-22)
--
-- Brings the table created on 2026-09-21 in line with the folded segments.
-- One-off; crash_usage_history_table.sql already reflects the end state.

ALTER TABLE `commcare-a57e4.mobile_metrics.crash_usage_history`
  ADD COLUMN IF NOT EXISTS unmatched_affected_users INT64
  OPTIONS(description = "Of affected_users, how many came from devices with no GA4 match. These are counted as non_connect but are absent from total_users, so they bias free_users_pct down. NULL on the installation basis");

ALTER TABLE `commcare-a57e4.mobile_metrics.crash_usage_history`
  ALTER COLUMN user_segment SET OPTIONS(description = "all, connect, connect_demo or non_connect. A device counts as connect if ccc_enabled was ever set during the window; connect_demo if its latest personalid_config_sessions phone number starts +7426 or appears in dimagi_phones; devices with no GA4 match count as non_connect");

ALTER TABLE `commcare-a57e4.mobile_metrics.crash_usage_history`
  ALTER COLUMN total_users SET OPTIONS(description = "Unique active users in the window; NULL for lts");
