--BigQuery query name: CommCare Crash & Usage Metrics : Weekly Snapshot

DECLARE data_lag_days INT64 DEFAULT 2;
DECLARE window_end DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL data_lag_days DAY);
DECLARE max_window_days INT64 DEFAULT 90;
DECLARE earliest_date DATE DEFAULT DATE_SUB(window_end, INTERVAL max_window_days - 1 DAY);

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

-- Latest config session per device decides demo status. dimagi_phones holds a
-- few repeated numbers, so this is a semi-join to avoid fanning out.
demo_devices AS (
  SELECT device_id
  FROM (
    SELECT
      device_id,
      phone_number,
      ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY created DESC) AS rn
    FROM `commcare-a57e4.analytics_153906101.personalid_config_sessions`
    WHERE device_id IS NOT NULL
  )
  WHERE rn = 1
    AND (
      STARTS_WITH(phone_number, '+7426')
      OR LTRIM(phone_number, '+') IN (
        SELECT phone FROM `commcare-a57e4.analytics_153906101.dimagi_phones`
      )
    )
),

ga_device_days AS (
  SELECT
    event_date,
    device_id,
    LOGICAL_OR(is_connect) AS is_connect
  FROM ga_events
  WHERE event_date BETWEEN earliest_date AND window_end
    AND device_id IS NOT NULL
  GROUP BY event_date, device_id
),

-- ccc_enabled turns on when the user configures their Connect account and stays
-- on, so a device that ever reports it was a Connect user for the whole window.
device_segments AS (
  SELECT
    w.window_days,
    d.device_id,
    CASE
      WHEN NOT LOGICAL_OR(d.is_connect) THEN 'non_connect'
      WHEN d.device_id IN (SELECT device_id FROM demo_devices) THEN 'connect_demo'
      ELSE 'connect'
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
    IFNULL(s.user_segment, 'non_connect') AS user_segment,
    COUNT(*) AS total_events,
    COUNT(DISTINCT IFNULL(e.device_id, e.installation_uuid)) AS affected_users,
    COUNT(DISTINCT IF(s.user_segment IS NULL, IFNULL(e.device_id, e.installation_uuid), NULL)) AS unmatched_affected_users,
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
    COUNT(DISTINCT IF(s.user_segment IS NULL, IFNULL(e.device_id, e.installation_uuid), NULL)) AS unmatched_affected_users,
    MIN(e.event_date) AS first_event_date
  FROM crash_events e
  CROSS JOIN windows w
  LEFT JOIN device_segments s
    ON s.window_days = w.window_days AND s.device_id = e.device_id
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
         c.total_events, c.affected_users, CAST(NULL AS INT64) AS unmatched_affected_users,
         c.first_event_date, t.total_users
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
  unmatched_affected_users,
  ROUND(100 * (1 - SAFE_DIVIDE(affected_users, total_users)), 2) AS free_users_pct,
  DATE_DIFF(window_end, first_event_date, DAY) + 1 AS days_covered
FROM combined
ORDER BY app, id_basis, window_days, error_type, user_segment;
