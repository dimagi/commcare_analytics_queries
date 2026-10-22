--BigQuery query name: Investigate User : PersonalID Users On A Device

WITH events AS (
  SELECT
    PARSE_DATE('%Y%m%d', _TABLE_SUFFIX) AS export_date,
    user_pseudo_id,
    app_info.id AS app_id,
    app_info.version AS app_version,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_cid') AS user_cid,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'ccc_enabled') AS ccc_enabled,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'is_personal_id_demo_user') AS is_demo_user
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', @start_date) AND FORMAT_DATE('%Y%m%d', @end_date)
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'device_id')
        = RIGHT(REGEXP_REPLACE(@device_id, r'^commcare_', ''), 36)
)

SELECT
  user_cid,
  user_cid IS NULL AS is_logged_out_activity,
  MIN(export_date) AS first_seen_date,
  MAX(export_date) AS last_seen_date,
  COUNT(DISTINCT export_date) AS active_days,
  COUNT(*) AS events,
  COUNT(DISTINCT user_pseudo_id) AS app_instances,
  ARRAY_AGG(DISTINCT app_id IGNORE NULLS ORDER BY app_id) AS app_ids,
  ARRAY_AGG(DISTINCT app_version IGNORE NULLS ORDER BY app_version) AS app_versions,
  LOGICAL_OR(ccc_enabled = 'true') AS any_ccc_enabled,
  LOGICAL_OR(is_demo_user = 'true') AS any_demo_user,
  COUNT(DISTINCT user_cid) OVER () AS users_on_device,
  @start_date AS start_date,
  @end_date AS end_date
FROM events
GROUP BY user_cid
ORDER BY last_seen_date DESC, events DESC;
