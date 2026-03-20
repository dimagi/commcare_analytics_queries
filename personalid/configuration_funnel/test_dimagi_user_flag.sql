-- Test query: Check the two joins that compose is_dimagi_user
-- Shows each analytics user from the last week with flags for each join step
SELECT
  user_pseudo_id,
  device_id_value,
  CONCAT('commcare_', device_id_value) AS prefixed_device_id,
  s.device_id AS config_session_device_id,
  s.phone_number AS config_session_phone,
  d.phone AS dimagi_phone,
  IF(s.device_id IS NOT NULL, 1, 0) AS device_match,
  IF(d.phone IS NOT NULL, 1, 0) AS phone_match
FROM (
  SELECT DISTINCT
    user_pseudo_id,
    (SELECT value.string_value FROM UNNEST(user_properties) WHERE key = 'device_id') AS device_id_value
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY))
                            AND FORMAT_DATE('%Y%m%d', CURRENT_DATE())
) AS users
LEFT JOIN `commcare-a57e4.analytics_153906101.personalid_config_sessions` s
  ON s.device_id = CONCAT('commcare_', users.device_id_value)
LEFT JOIN `commcare-a57e4.analytics_153906101.dimagi_phones` d
  ON d.phone = LTRIM(s.phone_number, '+')
ORDER BY phone_match DESC, device_match DESC, user_pseudo_id
