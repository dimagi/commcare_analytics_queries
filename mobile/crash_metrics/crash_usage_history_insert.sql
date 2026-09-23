--BigQuery query name: CommCare Crash & Usage Metrics : Monthly Insert

DECLARE data_lag_days INT64 DEFAULT 2;
DECLARE window_end DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL data_lag_days DAY);
DECLARE max_window_days INT64 DEFAULT 90;
DECLARE earliest_date DATE DEFAULT DATE_SUB(window_end, INTERVAL max_window_days - 1 DAY);

-- Fail loudly rather than writing history off a stale rollup.
ASSERT (
  SELECT MAX(event_date) FROM `commcare-a57e4.mobile_metrics.ga_device_day`
) >= window_end AS 'ga_device_day rollup is behind window_end; run ga_device_day_insert.sql first';

BEGIN TRANSACTION;

DELETE FROM `commcare-a57e4.mobile_metrics.crash_usage_history`
WHERE run_date = CURRENT_DATE();

INSERT INTO `commcare-a57e4.mobile_metrics.crash_usage_history`
(
  run_date, app, app_version, user_segment, window_days, error_type,
  window_start, window_end, total_events, affected_users, total_users,
  unmatched_affected_users, free_users_pct, days_covered, inserted_at
)
WITH windows AS (
  SELECT 30 AS window_days UNION ALL SELECT 90
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

crash_events AS (
  SELECT
    'commcare' AS app,
    error_type,
    DATE(event_timestamp) AS event_date,
    installation_uuid,
    (SELECT k.value FROM UNNEST(custom_keys) k WHERE k.key = 'device_id') AS device_id,
    IFNULL(application.display_version, 'unknown') AS app_version
  FROM `commcare-a57e4.firebase_crashlytics.org_commcare_dalvik_ANDROID`
  WHERE DATE(event_timestamp) BETWEEN earliest_date AND window_end
    AND error_type IN ('FATAL', 'ANR', 'NON_FATAL')

  UNION ALL

  SELECT
    'lts' AS app,
    error_type,
    DATE(event_timestamp) AS event_date,
    installation_uuid,
    (SELECT k.value FROM UNNEST(custom_keys) k WHERE k.key = 'device_id') AS device_id,
    IFNULL(application.display_version, 'unknown') AS app_version
  FROM `commcare-a57e4.firebase_crashlytics.org_commcare_lts_ANDROID`
  WHERE DATE(event_timestamp) BETWEEN earliest_date AND window_end
    AND error_type IN ('FATAL', 'ANR', 'NON_FATAL')
),

-- Reads the daily rollup rather than the GA4 export, which is what keeps this
-- query off a 90 day scan of user_properties. Run ga_device_day_insert.sql first.
ga_events AS (
  SELECT event_date, user_pseudo_id, device_id, is_connect, app_version
  FROM `commcare-a57e4.mobile_metrics.ga_device_day`
  WHERE event_date BETWEEN earliest_date AND window_end
),

-- Segment is a property of the device across the whole window, so it is worked
-- out without reference to version.
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
      WHEN NOT LOGICAL_OR(d.is_connect) THEN 'non-connect'
      WHEN d.device_id IN (SELECT device_id FROM demo_devices) THEN 'connect-demo'
      ELSE 'connect'
    END AS user_segment
  FROM ga_device_days d
  CROSS JOIN windows w
  WHERE d.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
  GROUP BY w.window_days, d.device_id
),

ga_device_version_days AS (
  SELECT DISTINCT event_date, device_id, app_version
  FROM ga_events
  WHERE event_date BETWEEN earliest_date AND window_end
    AND device_id IS NOT NULL
),

ga_instance_version_days AS (
  SELECT DISTINCT event_date, user_pseudo_id, app_version
  FROM ga_events
  WHERE event_date BETWEEN earliest_date AND window_end
),

-- Unnesting ['all', <version>] puts every row in both its own version bucket and
-- the rolled-up one, so the two levels cannot disagree.
crash_by_segment AS (
  SELECT
    e.app,
    w.window_days,
    e.error_type,
    vk AS app_version,
    IFNULL(s.user_segment, 'non-connect') AS user_segment,
    COUNT(*) AS total_events,
    COUNT(DISTINCT IFNULL(e.device_id, e.installation_uuid)) AS affected_users,
    COUNT(DISTINCT IF(s.user_segment IS NULL, IFNULL(e.device_id, e.installation_uuid), NULL)) AS unmatched_affected_users,
    MIN(e.event_date) AS first_event_date
  FROM crash_events e
  CROSS JOIN windows w
  CROSS JOIN UNNEST(['all', e.app_version]) AS vk
  LEFT JOIN device_segments s
    ON s.window_days = w.window_days AND s.device_id = e.device_id
  WHERE e.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
    AND e.app = 'commcare'
  GROUP BY e.app, w.window_days, e.error_type, vk, user_segment
),

crash_device_all AS (
  SELECT
    e.app,
    w.window_days,
    e.error_type,
    vk AS app_version,
    'all-by-device' AS user_segment,
    COUNT(*) AS total_events,
    COUNT(DISTINCT IFNULL(e.device_id, e.installation_uuid)) AS affected_users,
    COUNT(DISTINCT IF(s.user_segment IS NULL, IFNULL(e.device_id, e.installation_uuid), NULL)) AS unmatched_affected_users,
    MIN(e.event_date) AS first_event_date
  FROM crash_events e
  CROSS JOIN windows w
  CROSS JOIN UNNEST(['all', e.app_version]) AS vk
  LEFT JOIN device_segments s
    ON s.window_days = w.window_days AND s.device_id = e.device_id
  WHERE e.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
    AND e.app = 'commcare'
  GROUP BY e.app, w.window_days, e.error_type, vk
),

crash_installation_all AS (
  SELECT
    e.app,
    w.window_days,
    e.error_type,
    vk AS app_version,
    COUNT(*) AS total_events,
    COUNT(DISTINCT e.installation_uuid) AS affected_users,
    MIN(e.event_date) AS first_event_date
  FROM crash_events e
  CROSS JOIN windows w
  CROSS JOIN UNNEST(['all', e.app_version]) AS vk
  WHERE e.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
  GROUP BY e.app, w.window_days, e.error_type, vk
),

device_totals AS (
  SELECT w.window_days, vk AS app_version, s.user_segment, COUNT(DISTINCT d.device_id) AS total_users
  FROM ga_device_version_days d
  CROSS JOIN windows w
  CROSS JOIN UNNEST(['all', d.app_version]) AS vk
  JOIN device_segments s
    ON s.window_days = w.window_days AND s.device_id = d.device_id
  WHERE d.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
  GROUP BY w.window_days, vk, s.user_segment

  UNION ALL

  SELECT w.window_days, vk AS app_version, 'all-by-device' AS user_segment, COUNT(DISTINCT d.device_id) AS total_users
  FROM ga_device_version_days d
  CROSS JOIN windows w
  CROSS JOIN UNNEST(['all', d.app_version]) AS vk
  WHERE d.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
  GROUP BY w.window_days, vk
),

instance_totals AS (
  SELECT w.window_days, vk AS app_version, COUNT(DISTINCT i.user_pseudo_id) AS total_users
  FROM ga_instance_version_days i
  CROSS JOIN windows w
  CROSS JOIN UNNEST(['all', i.app_version]) AS vk
  WHERE i.event_date >= DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY)
  GROUP BY w.window_days, vk
),

combined AS (
  SELECT c.*, t.total_users
  FROM (SELECT * FROM crash_by_segment UNION ALL SELECT * FROM crash_device_all) c
  LEFT JOIN device_totals t
    ON t.window_days = c.window_days
   AND t.app_version = c.app_version
   AND t.user_segment = c.user_segment

  UNION ALL

  SELECT c.app, c.window_days, c.error_type, c.app_version, 'all-by-installation' AS user_segment,
         c.total_events, c.affected_users, CAST(NULL AS INT64) AS unmatched_affected_users,
         c.first_event_date, t.total_users
  FROM crash_installation_all c
  LEFT JOIN instance_totals t
    ON t.window_days = c.window_days AND t.app_version = c.app_version AND c.app = 'commcare'
)

SELECT
  CURRENT_DATE() AS run_date,
  app,
  app_version,
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
  DATE_DIFF(window_end, first_event_date, DAY) + 1 AS days_covered,
  CURRENT_TIMESTAMP() AS inserted_at
FROM combined;

COMMIT TRANSACTION;
