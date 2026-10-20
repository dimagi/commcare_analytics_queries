--BigQuery query name: CommCare Crash & Usage Metrics : Refresh GA Device Day Rollup

DECLARE data_lag_days INT64 DEFAULT 2;
DECLARE refresh_days INT64 DEFAULT 3;
DECLARE initial_backfill_days INT64 DEFAULT 90;
DECLARE target_end DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL data_lag_days DAY);
DECLARE target_start DATE;

-- Redo the most recent few days every run, in case events landed late, and pick up
-- whatever gap a missed run left behind. An empty table backfills the full window.
SET target_start = (
  SELECT IFNULL(
    DATE_SUB(MAX(event_date), INTERVAL refresh_days - 1 DAY),
    DATE_SUB(target_end, INTERVAL initial_backfill_days - 1 DAY)
  )
  FROM `commcare-a57e4.mobile_metrics.ga_device_day`
);

BEGIN TRANSACTION;

DELETE FROM `commcare-a57e4.mobile_metrics.ga_device_day`
WHERE event_date BETWEEN target_start AND target_end;

INSERT INTO `commcare-a57e4.mobile_metrics.ga_device_day`
(event_date, user_pseudo_id, device_id, app_version, is_connect, inserted_at)
SELECT
  event_date,
  user_pseudo_id,
  device_id,
  app_version,
  LOGICAL_OR(is_connect) AS is_connect,
  CURRENT_TIMESTAMP() AS inserted_at
FROM (
  -- _TABLE_SUFFIX prunes the shards with a day of slack either side; the event
  -- timestamp decides the day, so that this lines up with the Crashlytics side.
  SELECT
    DATE(TIMESTAMP_MICROS(event_timestamp)) AS event_date,
    user_pseudo_id,
    CONCAT('commcare_', (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'device_id')) AS device_id,
    IFNULL(app_info.version, 'unknown') AS app_version,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'ccc_enabled') = 'true' AS is_connect
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(target_start, INTERVAL 1 DAY))
                          AND FORMAT_DATE('%Y%m%d', DATE_ADD(target_end, INTERVAL 1 DAY))
    AND app_info.id = 'org.commcare.dalvik'
)
WHERE event_date BETWEEN target_start AND target_end
GROUP BY event_date, user_pseudo_id, device_id, app_version;

COMMIT TRANSACTION;
