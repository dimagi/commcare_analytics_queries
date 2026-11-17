--BigQuery query name: CommCare Performance Metrics : Create Perf Daily Table

CREATE TABLE IF NOT EXISTS `commcare-a57e4.mobile_metrics.perf_daily`
(
  event_date            DATE      NOT NULL OPTIONS(description = "The day the trace ran, from event_timestamp (device clock), not the export partition"),
  app                   STRING    NOT NULL OPTIONS(description = "commcare (org.commcare.dalvik) or lts (org.commcare.lts)"),
  app_version           STRING    NOT NULL OPTIONS(description = "app_display_version, e.g. 2.65.0, or 'unknown'"),
  trace_type            STRING    NOT NULL OPTIONS(description = "SCREEN_TRACE, DURATION_TRACE (custom traces and _app_start, _app_in_foreground, _app_in_background) or NETWORK_REQUEST"),
  trace_name            STRING    NOT NULL OPTIONS(description = "event_name: _st_<Activity> for screens, the trace name, or the URL pattern for network requests"),
  sample_count          INT64     NOT NULL OPTIONS(description = "Number of traces or requests"),
  p50_ms                FLOAT64   OPTIONS(description = "Median duration in ms. For NETWORK_REQUEST, the time to response completed"),
  p90_ms                FLOAT64   OPTIONS(description = "90th percentile duration in ms. For NETWORK_REQUEST, the time to response completed"),
  duration_sketch       BYTES     OPTIONS(description = "KLL sketch of the duration in microseconds. Merge across days or versions with KLL_QUANTILES.MERGE_POINT_INT64; percentiles cannot be averaged"),
  slow_screen_count     INT64     OPTIONS(description = "SCREEN_TRACE only: screen instances with slow_frame_ratio over 0.5, Firebase's slow rendering rule"),
  frozen_screen_count   INT64     OPTIONS(description = "SCREEN_TRACE only: screen instances with frozen_frame_ratio over 0.001, Firebase's frozen frames rule"),
  slow_screen_share     FLOAT64   OPTIONS(description = "SCREEN_TRACE only: slow_screen_count / sample_count"),
  frozen_screen_share   FLOAT64   OPTIONS(description = "SCREEN_TRACE only: frozen_screen_count / sample_count"),
  error_count           INT64     OPTIONS(description = "NETWORK_REQUEST only: requests with no response code or one of 400 and up"),
  error_rate            FLOAT64   OPTIONS(description = "NETWORK_REQUEST only: error_count / sample_count. Mostly 403s from the server, so watch it for change, not level"),
  server_error_count    INT64     OPTIONS(description = "NETWORK_REQUEST only: requests with a response code of 500 and up"),
  inserted_at           TIMESTAMP OPTIONS(description = "When the row was written")
)
PARTITION BY event_date
CLUSTER BY app, trace_type, trace_name, app_version
OPTIONS(
  description = "Daily summary of the Firebase Performance Monitoring export, one row per day x app x version x trace. Keeps performance history past the export's 60 day expiry and feeds the medic's performance checks. Written by perf_daily_insert.sql; see mobile/perf_metrics/README.md in commcare-analytics-queries."
);
