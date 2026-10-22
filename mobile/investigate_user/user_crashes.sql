--BigQuery query name: Investigate User : Crashlytics Issues On A User's Devices

WITH devices AS (
  SELECT DISTINCT CONCAT('commcare_', REGEXP_REPLACE(d, r'^commcare_', '')) AS device_id
  FROM UNNEST(@device_ids) d
),

crashes AS (
  SELECT
    DATE(c.event_timestamp) AS event_date,
    c.issue_id,
    c.issue_title,
    c.error_type,
    c.application.display_version AS app_version,
    d.device_id,
    c.user.id = @user_cid AS user_id_is_user,
    c.user.id IS NOT NULL AND c.user.id != @user_cid AS user_id_is_other
  FROM `commcare-a57e4.firebase_crashlytics.org_commcare_dalvik_ANDROID` c
  JOIN devices d
    ON d.device_id = (SELECT k.value FROM UNNEST(c.custom_keys) k WHERE k.key = 'device_id')
  WHERE DATE(c.event_timestamp) BETWEEN @start_date AND @end_date
)

SELECT
  issue_id,
  ANY_VALUE(issue_title) AS issue_title,
  error_type,
  COUNT(*) AS events,
  COUNT(DISTINCT device_id) AS devices,
  COUNT(DISTINCT event_date) AS days_with_events,
  MIN(event_date) AS first_event_date,
  MAX(event_date) AS last_event_date,
  ARRAY_AGG(DISTINCT IFNULL(app_version, 'unknown') ORDER BY IFNULL(app_version, 'unknown')) AS app_versions,
  COUNTIF(user_id_is_user) AS events_user_id_is_user,
  COUNTIF(user_id_is_other) AS events_user_id_is_other,
  @start_date AS start_date,
  @end_date AS end_date
FROM crashes
GROUP BY issue_id, error_type
ORDER BY events DESC, issue_id;
