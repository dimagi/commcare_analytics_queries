--BigQuery query name: CommCare Crash & Usage Metrics : Monthly Insert

DECLARE data_lag_days INT64 DEFAULT 2;
DECLARE window_end DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL data_lag_days DAY);
DECLARE max_window_days INT64 DEFAULT 90;
DECLARE earliest_date DATE DEFAULT DATE_SUB(window_end, INTERVAL max_window_days - 1 DAY);

BEGIN TRANSACTION;

DELETE FROM `commcare-a57e4.mobile_metrics.crash_usage_history`
WHERE run_date = CURRENT_DATE();

INSERT INTO `commcare-a57e4.mobile_metrics.crash_usage_history`
(
  run_date, app, id_basis, user_segment, window_days, error_type,
  window_start, window_end, total_events, affected_users, total_users,
  free_users_pct, days_covered, inserted_at
)
WITH windows AS (
  SELECT 30 AS window_days UNION ALL SELECT 90
),

crash_events AS (
  SELECT
    'commcare' AS app,
    error_type,
    DATE(event_timestamp) AS event_date,
    installation_uuid,
    (SELECT k.value FROM UNNEST(custom_keys) k WHERE k.key = 'device_id') AS device_id
  FROM `commcare-a57e4.firebase_crashlytics.org_commcare_dalvik_ANDROID`
  WHERE DATE(event_timestamp) BETWEEN earliest_date AND window_end
    AND error_type IN ('FATAL', 'ANR')

  UNION ALL

  SELECT
    'lts' AS app,
    error_type,
    DATE(event_timestamp) AS event_date,
    installation_uuid,
    (SELECT k.value FROM UNNEST(custom_keys) k WHERE k.key = 'device_id') AS device_id
  FROM `commcare-a57e4.firebase_crashlytics.org_commcare_lts_ANDROID`
  WHERE DATE(event_timestamp) BETWEEN earliest_date AND window_end
    AND error_type IN ('FATAL', 'ANR')
),

-- _TABLE_SUFFIX prunes shards; the event timestamp decides the day, so that this
-- lines up with DATE(event_timestamp) on the Crashlytics side.
ga_events AS (
  SELECT
    DATE(TIMESTAMP_MICROS(event_timestamp)) AS event_date,
    user_pseudo_id,
    CONCAT('commcare_', (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'device_id')) AS device_id,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'ccc_enabled') = 'true' AS is_connect
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(earliest_date, INTERVAL 1 DAY))
                          AND FORMAT_DATE('%Y%m%d', DATE_ADD(window_end, INTERVAL 1 DAY))
    AND app_info.id = 'org.commcare.dalvik'
),

ga_instance_days AS (
  SELECT DISTINCT event_date, user_pseudo_id
  FROM ga_events
  WHERE event_date BETWEEN earliest_date AND window_end
),

ga_device_days AS (
  SELECT
    event_date,
    device_id,
    LOGICAL_OR(is_connect) AS any_connect,
    LOGICAL_AND(is_connect) AS all_connect
  FROM ga_events
  WHERE event_date BETWEEN earliest_date AND window_end
    AND device_id IS NOT NULL
  GROUP BY event_date, device_id
),

-- Devices that ran Connect for only part of the window behave much more like
-- non-Connect ones, so they get their own segment rather than diluting either side.
device_segments AS (
  SELECT
    w.window_days,
    d.device_id,
    CASE
      WHEN LOGICAL_AND(d.all_connect) THEN 'connect'
      WHEN LOGICAL_OR(d.any_connect) THEN 'mixed'
      ELSE 'non_connect'
    END AS user_segment
  FROM ga_device_days d
  CROSS JOIN windows w
  WHERE d.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
  GROUP BY w.window_days, d.device_id
),

crash_by_segment AS (
  SELECT
    e.app,
    w.window_days,
    e.error_type,
    IFNULL(s.user_segment, 'unknown') AS user_segment,
    COUNT(*) AS total_events,
    COUNT(DISTINCT IFNULL(e.device_id, e.installation_uuid)) AS affected_users,
    MIN(e.event_date) AS first_event_date
  FROM crash_events e
  CROSS JOIN windows w
  LEFT JOIN device_segments s
    ON s.window_days = w.window_days AND s.device_id = e.device_id
  WHERE e.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
  GROUP BY e.app, w.window_days, e.error_type, user_segment
),

crash_device_all AS (
  SELECT
    e.app,
    w.window_days,
    e.error_type,
    'all' AS user_segment,
    COUNT(*) AS total_events,
    COUNT(DISTINCT IFNULL(e.device_id, e.installation_uuid)) AS affected_users,
    MIN(e.event_date) AS first_event_date
  FROM crash_events e
  CROSS JOIN windows w
  WHERE e.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
  GROUP BY e.app, w.window_days, e.error_type
),

crash_installation_all AS (
  SELECT
    e.app,
    w.window_days,
    e.error_type,
    COUNT(*) AS total_events,
    COUNT(DISTINCT e.installation_uuid) AS affected_users,
    MIN(e.event_date) AS first_event_date
  FROM crash_events e
  CROSS JOIN windows w
  WHERE e.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
  GROUP BY e.app, w.window_days, e.error_type
),

device_totals AS (
  SELECT window_days, user_segment, COUNT(DISTINCT device_id) AS total_users
  FROM device_segments
  GROUP BY window_days, user_segment

  UNION ALL

  SELECT window_days, 'all' AS user_segment, COUNT(DISTINCT device_id) AS total_users
  FROM device_segments
  GROUP BY window_days
),

instance_totals AS (
  SELECT w.window_days, COUNT(DISTINCT i.user_pseudo_id) AS total_users
  FROM ga_instance_days i
  CROSS JOIN windows w
  WHERE i.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
  GROUP BY w.window_days
),

combined AS (
  SELECT 'device' AS id_basis, c.*, t.total_users
  FROM (SELECT * FROM crash_by_segment UNION ALL SELECT * FROM crash_device_all) c
  LEFT JOIN device_totals t
    ON t.window_days = c.window_days AND t.user_segment = c.user_segment
  WHERE c.app = 'commcare'

  UNION ALL

  SELECT 'installation' AS id_basis, c.app, c.window_days, c.error_type, 'all' AS user_segment,
         c.total_events, c.affected_users, c.first_event_date, t.total_users
  FROM crash_installation_all c
  LEFT JOIN instance_totals t
    ON t.window_days = c.window_days AND c.app = 'commcare'
)

SELECT
  CURRENT_DATE() AS run_date,
  app,
  id_basis,
  user_segment,
  window_days,
  error_type,
  DATE_SUB(window_end, INTERVAL window_days - 1 DAY) AS window_start,
  window_end AS window_end,
  total_events,
  affected_users,
  total_users,
  ROUND(100 * (1 - SAFE_DIVIDE(affected_users, total_users)), 2) AS free_users_pct,
  DATE_DIFF(window_end, first_event_date, DAY) + 1 AS days_covered,
  CURRENT_TIMESTAMP() AS inserted_at
FROM combined;

COMMIT TRANSACTION;
