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
    installation_uuid
  FROM `commcare-a57e4.firebase_crashlytics.org_commcare_dalvik_ANDROID`
  WHERE DATE(event_timestamp) BETWEEN earliest_date AND window_end
    AND error_type IN ('FATAL', 'ANR')

  UNION ALL

  SELECT
    'lts' AS app,
    error_type,
    DATE(event_timestamp) AS event_date,
    installation_uuid
  FROM `commcare-a57e4.firebase_crashlytics.org_commcare_lts_ANDROID`
  WHERE DATE(event_timestamp) BETWEEN earliest_date AND window_end
    AND error_type IN ('FATAL', 'ANR')
),

crash_totals AS (
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

-- _TABLE_SUFFIX prunes shards; the event timestamp decides the day, so that this
-- lines up with DATE(event_timestamp) on the Crashlytics side.
active_user_days AS (
  SELECT DISTINCT
    DATE(TIMESTAMP_MICROS(event_timestamp)) AS event_date,
    user_pseudo_id
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(earliest_date, INTERVAL 1 DAY))
                          AND FORMAT_DATE('%Y%m%d', DATE_ADD(window_end, INTERVAL 1 DAY))
    AND app_info.id = 'org.commcare.dalvik'
),

active_users AS (
  SELECT
    'commcare' AS app,
    w.window_days,
    COUNT(DISTINCT a.user_pseudo_id) AS total_users
  FROM active_user_days a
  CROSS JOIN windows w
  WHERE a.event_date BETWEEN DATE_SUB(window_end, INTERVAL w.window_days - 1 DAY) AND window_end
  GROUP BY w.window_days
)

SELECT
  CURRENT_DATE() AS run_date,
  c.app,
  c.window_days,
  c.error_type,
  DATE_SUB(window_end, INTERVAL c.window_days - 1 DAY) AS window_start,
  window_end AS window_end,
  c.total_events,
  c.affected_users,
  u.total_users,
  ROUND(100 * (1 - SAFE_DIVIDE(c.affected_users, u.total_users)), 2) AS free_users_pct,
  DATE_DIFF(window_end, c.first_event_date, DAY) + 1 AS days_covered
FROM crash_totals c
LEFT JOIN active_users u
  ON u.app = c.app AND u.window_days = c.window_days
ORDER BY c.app, c.window_days, c.error_type;
