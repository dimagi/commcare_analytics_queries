--BigQuery query name: Connect Credentials in Work History
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
)

SELECT
  event_timestamp,
  FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', timestamp_micros(event_timestamp), 'UTC') AS event_datetime,
  FORMAT_TIMESTAMP('%Y-%m-%d', timestamp_micros(event_timestamp), 'UTC') AS event_date,
  event_name,
  (SELECT ep_inner_1.value.string_value 
   FROM UNNEST(event_params) AS ep_inner_1 
   WHERE ep_inner_1.key = 'firebase_screen_class') AS screen_name,
  (SELECT up_inner.value.string_value 
   FROM UNNEST(user_properties) AS up_inner 
   WHERE up_inner.key = 'ccc_enabled') AS ccc_enabled,
  (SELECT up_inner.value.string_value 
   FROM UNNEST(user_properties) AS up_inner 
   WHERE up_inner.key = 'user_cid') AS connect_id,
  (SELECT up_inner.value.string_value 
   FROM UNNEST(user_properties) AS up_inner 
   WHERE up_inner.key = 'cchq_domain') AS cchq_domain,
  (SELECT up_inner.value.string_value 
   FROM UNNEST(user_properties) AS up_inner 
   WHERE up_inner.key = 'user_id') AS cc_user_id,
  user_id, user_pseudo_id,
  device.category, device.mobile_brand_name, device.mobile_model_name, device.mobile_marketing_name, device.mobile_os_hardware_model,
  device.operating_system_version, device.language, device.time_zone_offset_seconds,
  geo.city, geo.continent, geo.region, geo.sub_continent,
  app_info.version
FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
WHERE PARSE_DATE('%Y%m%d', CAST(_TABLE_SUFFIX AS STRING)) 
      BETWEEN DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL history_months MONTH), MONTH) 
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
  AND user_pseudo_id NOT IN (SELECT user_pseudo_id FROM dimagi_users);
