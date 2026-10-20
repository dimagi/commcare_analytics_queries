--BigQuery query name: CommCare Crash & Usage Metrics : Create GA Device Day Rollup

CREATE TABLE IF NOT EXISTS `commcare-a57e4.mobile_metrics.ga_device_day`
(
  event_date     DATE      NOT NULL OPTIONS(description = "The day the activity happened, from the GA4 event timestamp"),
  user_pseudo_id STRING    OPTIONS(description = "GA4 app instance id; the denominator for all-by-installation"),
  device_id      STRING    OPTIONS(description = "CommCare device_id in the commcare_<uuid> form the Crashlytics custom key uses. NULL when the app instance did not report one"),
  app_version    STRING    NOT NULL OPTIONS(description = "app_info.version, e.g. 2.63.5, or 'unknown'"),
  is_connect     BOOL      OPTIONS(description = "Whether ccc_enabled was set on any event for this row's grain that day"),
  inserted_at    TIMESTAMP OPTIONS(description = "When the row was written")
)
PARTITION BY event_date
CLUSTER BY device_id, app_version
OPTIONS(
  description = "Daily rollup of the GA4 export for org.commcare.dalvik, one row per day x app instance x device x version. Exists so the metrics queries do not rescan 90 days of GA4 user_properties on every run, and so usage history outlives the 180 day GA4 export. Written by ga_device_day_insert.sql; see mobile/crash_metrics/README.md in commcare-analytics-queries."
);
