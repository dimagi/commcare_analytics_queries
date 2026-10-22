--BigQuery query name: Investigate User : Devices Of A PersonalID User

WITH events AS (
  SELECT
    PARSE_DATE('%Y%m%d', _TABLE_SUFFIX) AS export_date,
    user_pseudo_id,
    app_info.id AS app_id,
    app_info.version AS app_version,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'device_id') AS ga_device_id,
    (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_cid') AS user_cid
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', @start_date) AND FORMAT_DATE('%Y%m%d', @end_date)
),

tagged AS (
  SELECT
    *,
    IFNULL(user_cid = @user_cid, FALSE) AS is_user
  FROM events
  WHERE ga_device_id IS NOT NULL
),

per_device AS (
  SELECT
    ga_device_id,
    LOGICAL_OR(is_user) AS used_by_user,
    MIN(IF(is_user, export_date, NULL)) AS first_seen_date,
    MAX(IF(is_user, export_date, NULL)) AS last_seen_date,
    COUNT(DISTINCT IF(is_user, export_date, NULL)) AS active_days,
    COUNTIF(is_user) AS events,
    COUNT(DISTINCT IF(is_user, user_pseudo_id, NULL)) AS app_instances,
    ARRAY_AGG(DISTINCT IF(is_user, app_id, NULL) IGNORE NULLS ORDER BY IF(is_user, app_id, NULL)) AS app_ids,
    ARRAY_AGG(DISTINCT IF(is_user, app_version, NULL) IGNORE NULLS ORDER BY IF(is_user, app_version, NULL)) AS app_versions,
    COUNT(DISTINCT IF(NOT is_user, user_cid, NULL)) AS other_users_on_device,
    COUNTIF(user_cid IS NULL) AS logged_out_events,
    MAX(export_date) AS device_last_seen_date
  FROM tagged
  GROUP BY ga_device_id
)

SELECT
  CONCAT('commcare_', ga_device_id) AS device_id,
  first_seen_date,
  last_seen_date,
  active_days,
  events,
  app_instances,
  app_ids,
  app_versions,
  other_users_on_device,
  other_users_on_device > 0 AS is_shared_device,
  logged_out_events,
  device_last_seen_date > last_seen_date AS used_after_user_left,
  @start_date AS start_date,
  @end_date AS end_date
FROM per_device
WHERE used_by_user
ORDER BY last_seen_date DESC, events DESC;
