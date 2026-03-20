--BigQuery query name: Reliable and Persistent Push Notifications and History List : Notification Clicks

WITH base_events AS (
  SELECT
    DATE_TRUNC(DATE(TIMESTAMP_MICROS(event_timestamp)), MONTH) AS event_month,   -- ✅ normalized month
    (SELECT ep_inner_1.value.string_value 
     FROM UNNEST(event_params) AS ep_inner_1 
     WHERE ep_inner_1.key = 'action') AS action
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE PARSE_DATE('%Y%m%d', CAST(_TABLE_SUFFIX AS STRING)) 
        BETWEEN DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 3 MONTH), MONTH) 
            AND LAST_DAY(CURRENT_DATE(), MONTH)
    AND event_name LIKE '%ccc_notification_type%'
    AND (SELECT ep_inner_1.value.string_value 
         FROM UNNEST(event_params) AS ep_inner_1 
         WHERE ep_inner_1.key = 'event_type') = 'click_notification'
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
)

-- 📊 Pivoted Monthly Action Counts
SELECT
  event_month,
  COUNTIF(action = 'ccc_message') AS ccc_message_count,
  COUNTIF(action = 'ccc_payment') AS ccc_payment_count,
  COUNTIF(action = 'ccc_payment_info_confirmation') AS ccc_payment_info_confirmation_count,
  COUNTIF(action = 'ccc_opportunity_summary_page') AS ccc_opportunity_summary_page_count,
  COUNTIF(action = 'ccc_learn_progress') AS ccc_learn_progress_count,
  COUNTIF(action = 'ccc_delivery_progress') AS ccc_delivery_progress_count,
  COUNTIF(action = '') AS empty_action_count
FROM base_events
GROUP BY event_month
ORDER BY event_month;