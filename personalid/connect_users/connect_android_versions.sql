--BigQuery query name: Connect Users by Android Version

-- Connect devices active in the window, by the Android version each was last seen on.
-- PersonalID needs Android 9 (API 28) or later (PersonalIdDeviceCompatibility), so
-- below_android_9 marks the devices that are on Connect despite that.

DECLARE window_days INT64 DEFAULT 30;

WITH events AS (
  SELECT
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'device_id') AS device_id,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'ccc_enabled') = 'true' AS is_connect,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'is_personal_id_demo_user') = 'true' AS is_demo,
    device.operating_system_version AS os_version,
    event_timestamp
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL window_days DAY))
                          AND FORMAT_DATE('%Y%m%d', CURRENT_DATE())
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'app_flavor') = 'commcare'
),
connect_devices AS (
  SELECT
    device_id,
    ARRAY_AGG(os_version IGNORE NULLS ORDER BY event_timestamp DESC LIMIT 1)[SAFE_OFFSET(0)] AS os_version
  FROM events
  WHERE device_id IS NOT NULL
  GROUP BY device_id
  HAVING LOGICAL_OR(is_connect) AND NOT LOGICAL_OR(IFNULL(is_demo, FALSE))
)
SELECT
  IFNULL(os_version, 'unknown') AS android_version,
  SAFE_CAST(REGEXP_EXTRACT(os_version, r'(\d+)') AS INT64) < 9 AS below_android_9,
  COUNT(*) AS devices,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_connect_devices
FROM connect_devices
GROUP BY android_version, below_android_9
ORDER BY SAFE_CAST(REGEXP_EXTRACT(android_version, r'(\d+)') AS INT64), android_version
