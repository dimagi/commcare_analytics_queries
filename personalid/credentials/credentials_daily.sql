--BigQuery query name: Connect Credentials in Work History : Daily Stats

WITH base_events AS (
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
    user_id, user_pseudo_id
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE PARSE_DATE('%Y%m%d', CAST(_TABLE_SUFFIX AS STRING)) 
        BETWEEN DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 3 MONTH), MONTH) 
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
)


SELECT
  event_date,
  COUNT(*) AS daily_screen_views,                                -- Daily Screen Views
  COUNT(DISTINCT user_pseudo_id) AS daily_unique_users,          -- Daily Unique Users
  COUNT(*) / COUNT(DISTINCT user_pseudo_id) AS daily_avg_views_per_user -- Daily Screen Engagement
FROM base_events
GROUP BY event_date
ORDER BY event_date;

