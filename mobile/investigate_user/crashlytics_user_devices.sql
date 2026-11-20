--BigQuery query name: Investigate User : Devices Crashing Under A Crashlytics User Id

SELECT
  (SELECT k.value FROM UNNEST(c.custom_keys) k WHERE k.key = 'device_id') AS device_id,
  COUNT(*) AS events,
  MIN(DATE(c.event_timestamp)) AS first_event_date,
  MAX(DATE(c.event_timestamp)) AS last_event_date
FROM `commcare-a57e4.firebase_crashlytics.org_commcare_dalvik_ANDROID` c
WHERE c.user.id = @user_cid
  AND DATE(c.event_timestamp) BETWEEN @start_date AND @end_date
GROUP BY device_id
ORDER BY last_event_date DESC;
