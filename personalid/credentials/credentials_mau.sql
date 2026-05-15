--BigQuery query name: Connect Credentials in Work History : MAU
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
    FORMAT_TIMESTAMP('%Y-%m-%d', timestamp_micros(event_timestamp), 'UTC') AS event_date,
    DATE_TRUNC(DATE(TIMESTAMP_MICROS(event_timestamp)), MONTH) AS event_month_date,  -- ✅ normalized month date
    user_pseudo_id
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE PARSE_DATE('%Y%m%d', CAST(_TABLE_SUFFIX AS STRING)) 
        BETWEEN DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL history_months MONTH), MONTH)   -- last 3 months
            AND LAST_DAY(CURRENT_DATE(), MONTH)
    AND event_name LIKE '%screen_view%'
    AND (SELECT ep_inner_1.value.string_value 
         FROM UNNEST(event_params) AS ep_inner_1 
         WHERE ep_inner_1.key = 'firebase_screen_class') = 'PersonalIdWorkHistoryActivity'
    AND (SELECT up_inner.value.string_value 
         FROM UNNEST(user_properties) AS up_inner 
         WHERE up_inner.key = 'cchq_domain') NOT LIKE '%qa%commcarehq.org'
    AND (SELECT up_inner.value.string_value 
         FROM UNNEST(user_properties) AS up_inner 
         WHERE up_inner.key = 'cchq_domain') NOT LIKE '%test%commcarehq.org'
    AND (SELECT up_inner.value.string_value
          FROM UNNEST(user_properties) as up_inner
          WHERE up_inner.key='server')  not like 'staging.commcarehq.org'
    -- Restrict to the production 'commcare' flavor; excludes cccStaging, lts,
    -- and standalone builds (which share the same Firebase project / applicationId).
    AND (SELECT up_inner.value.string_value
         FROM UNNEST(user_properties) AS up_inner
         WHERE up_inner.key = 'app_flavor') = 'commcare'
    AND user_pseudo_id NOT IN (SELECT user_pseudo_id FROM dimagi_users)
)

-- 📆 Monthly Active Users (MAU) for charting
SELECT
  event_month_date AS month,                  -- ✅ single date column for chart axis
  COUNT(DISTINCT user_pseudo_id) AS mau
FROM base_events
GROUP BY event_month_date
ORDER BY month;