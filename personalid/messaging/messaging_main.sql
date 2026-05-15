--BigQuery query name: Messaging Functionality : Total Messages, Users, Average messages per user
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
overall_users AS (
  SELECT
    FORMAT_TIMESTAMP('%Y-%m', TIMESTAMP_MICROS(event_timestamp), 'UTC') AS event_month,
    COUNT(DISTINCT connect_id) AS overall_distinct_connect_users
  FROM (
    SELECT
      event_name,
      event_timestamp,
      (SELECT up_inner.value.string_value
       FROM UNNEST(user_properties) AS up_inner
       WHERE up_inner.key = 'user_cid') AS connect_id
    FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
    WHERE PARSE_DATE('%Y%m%d', CAST(_TABLE_SUFFIX AS STRING))
          BETWEEN DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL history_months MONTH), MONTH)
              AND LAST_DAY(CURRENT_DATE(), MONTH)
      AND event_name IN ('ccc_api_jobs','ccc_api_delivery_progress','ccc_api_learn_progress')
      AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'cchq_domain') NOT LIKE '%qa%commcarehq.org'
      AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'cchq_domain') NOT LIKE '%test%commcarehq.org'
      AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'server') NOT LIKE 'staging.commcarehq.org'
      -- Restrict to the production 'commcare' flavor; excludes cccStaging, lts,
      -- and standalone builds (which share the same Firebase project / applicationId).
      AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'app_flavor') = 'commcare'
      AND user_pseudo_id NOT IN (SELECT user_pseudo_id FROM dimagi_users)
  )
  GROUP BY event_month
),
messaging_users AS (
  SELECT
    FORMAT_TIMESTAMP('%Y-%m', TIMESTAMP_MICROS(event_timestamp), 'UTC') AS event_month,
    COUNT(DISTINCT user_id) AS messaging_distinct_users,
    COUNT(*) AS total_messages,
    ROUND(SAFE_DIVIDE(COUNT(*), COUNT(DISTINCT user_id)), 2) AS avg_messages_per_user
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE PARSE_DATE('%Y%m%d', CAST(_TABLE_SUFFIX AS STRING))
          BETWEEN DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL history_months MONTH), MONTH)
              AND LAST_DAY(CURRENT_DATE(), MONTH)
    AND event_name = 'personal_id_message_sent'
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'cchq_domain') NOT LIKE '%qa%commcarehq.org'
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'cchq_domain') NOT LIKE '%test%commcarehq.org'
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'server') NOT LIKE 'staging.commcarehq.org'
    -- Restrict to the production 'commcare' flavor; excludes cccStaging, lts,
    -- and standalone builds (which share the same Firebase project / applicationId).
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'app_flavor') = 'commcare'
    AND user_pseudo_id NOT IN (SELECT user_pseudo_id FROM dimagi_users)
  GROUP BY event_month
),
notification_actions AS (
  SELECT
    FORMAT_TIMESTAMP('%Y-%m', TIMESTAMP_MICROS(event_timestamp), 'UTC') AS event_month,
    COUNT(*) AS total_notifications,
    COUNTIF(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'action') = 'ccc_message'
    ) AS ccc_message_count,
    ROUND(
      SAFE_DIVIDE(
        COUNTIF((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'action') = 'ccc_message'),
        COUNT(*)
      ) * 100, 
      2
    ) AS ccc_message_percentage
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE PARSE_DATE('%Y%m%d', CAST(_TABLE_SUFFIX AS STRING))
          BETWEEN DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL history_months MONTH), MONTH)
              AND LAST_DAY(CURRENT_DATE(), MONTH)
    AND event_name LIKE '%ccc_notification_type%'
    AND (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'event_type') = 'click_notification'
    AND (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'firebase_screen_class') = 'PushNotificationActivity'
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'cchq_domain') NOT LIKE '%qa%commcarehq.org'
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'cchq_domain') NOT LIKE '%test%commcarehq.org'
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'server') NOT LIKE 'staging.commcarehq.org'
    -- Restrict to the production 'commcare' flavor; excludes cccStaging, lts,
    -- and standalone builds (which share the same Firebase project / applicationId).
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'app_flavor') = 'commcare'
    AND user_pseudo_id NOT IN (SELECT user_pseudo_id FROM dimagi_users)
  GROUP BY event_month
)
SELECT
  o.event_month,
  o.overall_distinct_connect_users,
  m.messaging_distinct_users,
  m.total_messages,
  m.avg_messages_per_user,
  n.ccc_message_count,
  n.total_notifications,
  n.ccc_message_percentage
FROM overall_users o
LEFT JOIN messaging_users m
  ON o.event_month = m.event_month
LEFT JOIN notification_actions n
  ON o.event_month = n.event_month
ORDER BY o.event_month;