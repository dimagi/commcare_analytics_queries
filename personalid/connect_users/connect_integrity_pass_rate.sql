--BigQuery query name: Connect Users Integrity Pass Rate

-- Would Connect devices pass the Play Integrity check if it were enforced for everyone?
-- Today start_device_configuration lets invited users through whatever the verdict, so
-- the configuration funnel never sees their failures. The heartbeat integrity sample does:
-- the app logs personalid_integrity_reported (trigger 'Heartbeat') with the server's verdict
-- ('passed' / 'failed') in result_code, or the Play Integrity error code when the device
-- could not get a token at all. 'SendError', null and 'NoCodeFromServer' (the server already
-- has a verdict for that request, kept only in connect-id's DeviceIntegritySample)
-- say nothing about the device and are left out.
-- Each device counts once, by its latest conclusive sample in the window.

DECLARE window_days INT64 DEFAULT 90;

WITH events AS (
  SELECT
    event_name,
    event_timestamp,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'device_id') AS device_id,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'ccc_enabled') = 'true' AS is_connect,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'is_personal_id_demo_user') = 'true' AS is_demo,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'trigger') AS trigger,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'result_code') AS result_code
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL window_days DAY))
                          AND FORMAT_DATE('%Y%m%d', CURRENT_DATE())
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'app_flavor') = 'commcare'
),
connect_devices AS (
  SELECT device_id
  FROM events
  WHERE device_id IS NOT NULL
  GROUP BY device_id
  HAVING LOGICAL_OR(is_connect) AND NOT LOGICAL_OR(IFNULL(is_demo, FALSE))
),
latest_sample AS (
  SELECT
    device_id,
    ARRAY_AGG(result_code ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS result_code
  FROM events
  WHERE event_name = 'personalid_integrity_reported'
    AND trigger = 'Heartbeat'
    AND result_code IS NOT NULL
    AND result_code NOT IN ('null', 'SendError', 'NoCodeFromServer')
    AND device_id IN (SELECT device_id FROM connect_devices)
  GROUP BY device_id
)
SELECT
  (SELECT COUNT(*) FROM connect_devices) AS connect_devices,
  COUNT(*) AS devices_with_sample,
  COUNTIF(result_code = 'passed') AS passed,
  COUNTIF(result_code = 'failed') AS failed,
  COUNTIF(result_code NOT IN ('passed', 'failed')) AS no_token,
  ROUND(100 * COUNTIF(result_code = 'passed') / COUNT(*), 2) AS pct_passed,
  ROUND(100 * COUNTIF(result_code = 'passed') / COUNTIF(result_code IN ('passed', 'failed')), 2) AS pct_passed_of_verdicts
FROM latest_sample
