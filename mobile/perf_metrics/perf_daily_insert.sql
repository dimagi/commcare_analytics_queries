--BigQuery query name: CommCare Performance Metrics : Refresh Perf Daily

DECLARE refresh_days INT64 DEFAULT 3;
DECLARE latest_partition DATE;
DECLARE earliest_partition DATE;
DECLARE target_start DATE;
DECLARE target_end DATE;

-- The export is a daily batch that lands about a day and a half late, and each
-- partition holds the events ingested that day, not the events that ran that day.
-- A day is mostly complete once the next day's partition is in, so the window ends
-- the day before the latest partition rather than a fixed lag behind today.
SET (latest_partition, earliest_partition) = (
  SELECT AS STRUCT
    MAX(PARSE_DATE('%Y%m%d', partition_id)),
    MIN(PARSE_DATE('%Y%m%d', partition_id))
  FROM `commcare-a57e4.firebase_performance.INFORMATION_SCHEMA.PARTITIONS`
  WHERE table_name = 'org_commcare_dalvik_ANDROID'
    AND partition_id NOT IN ('__NULL__', '__UNPARTITIONED__')
    AND total_rows > 0
);
SET target_end = DATE_SUB(latest_partition, INTERVAL 1 DAY);

-- Redo the most recent few days every run, for events that land late, and pick up
-- whatever gap a missed run left behind. An empty table backfills everything the
-- export still holds, skipping the first day, whose earlier events have expired.
SET target_start = (
  SELECT IFNULL(
    DATE_SUB(MAX(event_date), INTERVAL refresh_days - 1 DAY),
    DATE_ADD(earliest_partition, INTERVAL 1 DAY)
  )
  FROM `commcare-a57e4.mobile_metrics.perf_daily`
);

BEGIN TRANSACTION;

DELETE FROM `commcare-a57e4.mobile_metrics.perf_daily`
WHERE event_date BETWEEN target_start AND target_end;

INSERT INTO `commcare-a57e4.mobile_metrics.perf_daily`
(event_date, app, app_version, trace_type, trace_name, sample_count, p50_ms, p90_ms,
 duration_sketch, slow_screen_count, frozen_screen_count, slow_screen_share,
 frozen_screen_share, error_count, error_rate, server_error_count, inserted_at)
WITH events AS (
  -- A day's events are spread over the partitions around it, so read from two days
  -- before the window to the latest partition and let event_timestamp decide the day.
  SELECT 'commcare' AS app, *
  FROM `commcare-a57e4.firebase_performance.org_commcare_dalvik_ANDROID`
  WHERE _PARTITIONTIME >= TIMESTAMP(DATE_SUB(target_start, INTERVAL 2 DAY))
  UNION ALL
  SELECT 'lts' AS app, *
  FROM `commcare-a57e4.firebase_performance.org_commcare_lts_ANDROID`
  WHERE _PARTITIONTIME >= TIMESTAMP(DATE_SUB(target_start, INTERVAL 2 DAY))
),
samples AS (
  SELECT
    DATE(event_timestamp) AS event_date,
    app,
    IFNULL(app_display_version, 'unknown') AS app_version,
    event_type AS trace_type,
    event_name AS trace_name,
    IF(event_type = 'NETWORK_REQUEST', network_info.response_completed_time_us, trace_info.duration_us) AS duration_us,
    trace_info.screen_info.slow_frame_ratio AS slow_frame_ratio,
    trace_info.screen_info.frozen_frame_ratio AS frozen_frame_ratio,
    network_info.response_code AS response_code
  FROM events
  WHERE event_type IN ('SCREEN_TRACE', 'DURATION_TRACE', 'NETWORK_REQUEST')
    AND event_name IS NOT NULL
),
daily AS (
  SELECT
    event_date,
    app,
    app_version,
    trace_type,
    trace_name,
    COUNT(*) AS sample_count,
    KLL_QUANTILES.INIT_INT64(duration_us) AS duration_sketch,
    IF(trace_type = 'SCREEN_TRACE', COUNTIF(slow_frame_ratio > 0.5), NULL) AS slow_screen_count,
    IF(trace_type = 'SCREEN_TRACE', COUNTIF(frozen_frame_ratio > 0.001), NULL) AS frozen_screen_count,
    IF(trace_type = 'NETWORK_REQUEST', COUNTIF(response_code IS NULL OR response_code >= 400), NULL) AS error_count,
    IF(trace_type = 'NETWORK_REQUEST', COUNTIF(response_code >= 500), NULL) AS server_error_count
  FROM samples
  WHERE event_date BETWEEN target_start AND target_end
  GROUP BY event_date, app, app_version, trace_type, trace_name
)
SELECT
  event_date,
  app,
  app_version,
  trace_type,
  trace_name,
  sample_count,
  KLL_QUANTILES.EXTRACT_POINT_INT64(duration_sketch, 0.5) / 1000 AS p50_ms,
  KLL_QUANTILES.EXTRACT_POINT_INT64(duration_sketch, 0.9) / 1000 AS p90_ms,
  duration_sketch,
  slow_screen_count,
  frozen_screen_count,
  SAFE_DIVIDE(slow_screen_count, sample_count) AS slow_screen_share,
  SAFE_DIVIDE(frozen_screen_count, sample_count) AS frozen_screen_share,
  error_count,
  SAFE_DIVIDE(error_count, sample_count) AS error_rate,
  server_error_count,
  CURRENT_TIMESTAMP() AS inserted_at
FROM daily;

COMMIT TRANSACTION;
