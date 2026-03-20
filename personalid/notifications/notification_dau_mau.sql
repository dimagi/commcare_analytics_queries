--BigQuery query name: Reliable and Persistent Push Notifications and History List : DAu and MAU
DECLARE history_months INT64 DEFAULT 3;

WITH dimagi_users AS (
  SELECT DISTINCT user_pseudo_id
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*` t
  INNER JOIN (
    SELECT DISTINCT s.device_id
    FROM `commcare-a57e4.analytics_153906101.personalid_config_sessions` s
    INNER JOIN `commcare-a57e4.analytics_153906101.dimagi_phones` d ON LTRIM(s.phone_number, '+') = d.phone
  ) AS dimagi_devices
    ON dimagi_devices.device_id = CONCAT('commcare_', (SELECT value.string_value FROM UNNEST(t.user_properties) WHERE key = 'device_id'))
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL history_months MONTH), MONTH))
                          AND FORMAT_DATE('%Y%m%d', CURRENT_DATE())
),
base_events AS (
  SELECT
    DATE(TIMESTAMP_MICROS(event_timestamp)) AS event_date,                          -- daily granularity
    DATE_TRUNC(DATE(TIMESTAMP_MICROS(event_timestamp)), MONTH) AS event_month,      -- monthly granularity
    user_pseudo_id,
    user_id
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE PARSE_DATE('%Y%m%d', CAST(_TABLE_SUFFIX AS STRING)) 
        BETWEEN DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL history_months MONTH), MONTH) 
            AND LAST_DAY(CURRENT_DATE(), MONTH)
    AND event_name LIKE '%screen_view%'
    AND (SELECT ep_inner_1.value.string_value 
         FROM UNNEST(event_params) AS ep_inner_1 
         WHERE ep_inner_1.key = 'firebase_screen_class') = 'PushNotificationActivity'
    AND (SELECT up_inner.value.string_value 
         FROM UNNEST(user_properties) AS up_inner 
         WHERE up_inner.key = 'cchq_domain') NOT LIKE '%qa%commcarehq.org'
    AND (SELECT up_inner.value.string_value 
         FROM UNNEST(user_properties) AS up_inner 
         WHERE up_inner.key = 'cchq_domain') NOT LIKE '%test%commcarehq.org'
    AND (SELECT up_inner.value.string_value
         FROM UNNEST(user_properties) as up_inner
         WHERE up_inner.key='server')  not like 'staging.commcarehq.org'
    AND user_pseudo_id NOT IN (SELECT user_pseudo_id FROM dimagi_users)
),

-- 📅 Daily Active Users (DAU)
daily_active_users AS (
  SELECT
    event_date,
    COUNT(DISTINCT user_pseudo_id) AS dau,
    COUNT(DISTINCT user_id) AS dau_named
  FROM base_events
  GROUP BY event_date
),

-- 📆 Monthly Active Users (MAU)
monthly_active_users AS (
  SELECT
    event_month,
    COUNT(DISTINCT user_pseudo_id) AS mau,
    COUNT(DISTINCT user_id) AS mau_named
  FROM base_events
  GROUP BY event_month
)

-- ✅ Consolidated Output
SELECT 
  event_date AS period,
  'DAU' AS metric_type,
  dau AS distinct_users,
  dau_named AS distinct_named_users
FROM daily_active_users

UNION ALL

SELECT 
  event_month AS period,
  'MAU' AS metric_type,
  mau AS distinct_users,
  mau_named AS distinct_named_users
FROM monthly_active_users

ORDER BY period, metric_type;