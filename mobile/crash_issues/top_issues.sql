--BigQuery query name: CommCare Crash Issues : Top Issues By Devices Affected

WITH demo_devices AS (
  SELECT device_id
  FROM (
    SELECT
      device_id,
      phone_number,
      ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY created DESC) AS rn
    FROM `commcare-a57e4.analytics_153906101.personalid_config_sessions`
    WHERE device_id IS NOT NULL
  )
  WHERE rn = 1
    AND (
      STARTS_WITH(phone_number, '+7426')
      OR LTRIM(phone_number, '+') IN (
        SELECT phone FROM `commcare-a57e4.analytics_153906101.dimagi_phones`
      )
    )
),

segments AS (
  SELECT
    device_id,
    CASE
      WHEN NOT LOGICAL_OR(is_connect) THEN 'non-connect'
      WHEN device_id IN (SELECT device_id FROM demo_devices) THEN 'connect-demo'
      ELSE 'connect'
    END AS user_segment
  FROM `commcare-a57e4.mobile_metrics.ga_device_day`
  WHERE event_date BETWEEN DATE_SUB(@end_date, INTERVAL @days - 1 DAY) AND @end_date
    AND device_id IS NOT NULL
  GROUP BY device_id
),

active_devices AS (
  SELECT
    COUNT(*) AS all_active,
    COUNTIF(user_segment = 'connect') AS connect_active,
    COUNTIF(user_segment = 'non-connect') AS non_connect_active
  FROM segments
),

crashes AS (
  SELECT
    DATE(c.event_timestamp) AS event_date,
    c.issue_id,
    c.issue_title,
    c.error_type,
    c.installation_uuid,
    (SELECT k.value FROM UNNEST(c.custom_keys) k WHERE k.key = 'device_id') AS device_id,
    IFNULL((SELECT k.value FROM UNNEST(c.custom_keys) k WHERE k.key = 'device_id'), c.installation_uuid) AS device_key,
    (SELECT k.value FROM UNNEST(c.custom_keys) k WHERE k.key = 'domain') AS domain,
    NULLIF(TRIM(CONCAT(IFNULL(c.device.manufacturer, ''), ' ', IFNULL(c.device.model, ''))), '') AS device_model,
    c.operating_system.display_version AS os_version,
    c.application.display_version AS app_version
  FROM `commcare-a57e4.firebase_crashlytics.org_commcare_dalvik_ANDROID` c
  WHERE DATE(c.event_timestamp) BETWEEN DATE_SUB(@end_date, INTERVAL 2 * @days - 1 DAY) AND @end_date
    AND c.error_type IN ('FATAL', 'ANR')
),

dimension_counts AS (
  SELECT
    c.issue_id,
    c.error_type,
    d.dimension,
    d.value,
    ANY_VALUE(c.issue_title) AS issue_title,
    COUNT(DISTINCT c.device_key) AS devices,
    COUNT(*) AS events,
    COUNT(DISTINCT c.installation_uuid) AS installations,
    COUNT(DISTINCT c.event_date) AS days_with_events,
    MAX(c.event_date) AS last_event_date,
    COUNT(DISTINCT c.domain) AS domains
  FROM crashes c
  LEFT JOIN segments s ON s.device_id = c.device_id,
  UNNEST(
    IF(
      c.event_date < DATE_SUB(@end_date, INTERVAL @days - 1 DAY),
      [STRUCT('prior' AS dimension, CAST(NULL AS STRING) AS value)],
      [
        STRUCT('all' AS dimension, CAST(NULL AS STRING) AS value),
        ('segment', IFNULL(s.user_segment, 'non-connect')),
        ('unmatched', IF(s.device_id IS NULL, 'unmatched', NULL)),
        ('domain', c.domain),
        ('device_model', c.device_model),
        ('os_version', c.os_version),
        ('app_version', c.app_version)
      ]
    )
  ) d
  WHERE d.dimension IN ('all', 'prior', 'segment') OR d.value IS NOT NULL
  GROUP BY c.issue_id, c.error_type, d.dimension, d.value
),

per_issue AS (
  SELECT
    issue_id,
    error_type,
    ANY_VALUE(IF(dimension = 'all', issue_title, NULL)) AS issue_title,
    IFNULL(MAX(IF(dimension = 'all', devices, NULL)), 0) AS devices,
    IFNULL(MAX(IF(dimension = 'all', events, NULL)), 0) AS events,
    IFNULL(MAX(IF(dimension = 'all', installations, NULL)), 0) AS installations,
    IFNULL(MAX(IF(dimension = 'segment' AND value = 'connect', devices, NULL)), 0) AS connect_devices,
    IFNULL(MAX(IF(dimension = 'segment' AND value = 'connect-demo', devices, NULL)), 0) AS connect_demo_devices,
    IFNULL(MAX(IF(dimension = 'segment' AND value = 'non-connect', devices, NULL)), 0) AS non_connect_devices,
    IFNULL(MAX(IF(dimension = 'unmatched', devices, NULL)), 0) AS unmatched_devices,
    IFNULL(MAX(IF(dimension = 'segment' AND value = 'connect', events, NULL)), 0) AS connect_events,
    MAX(IF(dimension = 'all', domains, NULL)) AS domains,
    MAX(IF(dimension = 'all', days_with_events, NULL)) AS days_with_events,
    MAX(IF(dimension = 'all', last_event_date, NULL)) AS last_event_date,
    IFNULL(MAX(IF(dimension = 'prior', devices, NULL)), 0) AS prior_devices,
    IFNULL(MAX(IF(dimension = 'prior', events, NULL)), 0) AS prior_events,
    ARRAY_AGG(IF(dimension = 'domain', STRUCT(value, devices), NULL) IGNORE NULLS ORDER BY devices DESC, value LIMIT 1)[SAFE_OFFSET(0)] AS top_domain,
    ARRAY_AGG(IF(dimension = 'device_model', STRUCT(value, devices), NULL) IGNORE NULLS ORDER BY devices DESC, value LIMIT 1)[SAFE_OFFSET(0)] AS top_device_model,
    ARRAY_AGG(IF(dimension = 'os_version', STRUCT(value, devices), NULL) IGNORE NULLS ORDER BY devices DESC, value LIMIT 1)[SAFE_OFFSET(0)] AS top_os_version,
    ARRAY_AGG(IF(dimension = 'app_version', STRUCT(value, devices), NULL) IGNORE NULLS ORDER BY devices DESC, value LIMIT 1)[SAFE_OFFSET(0)] AS top_app_version
  FROM dimension_counts
  GROUP BY issue_id, error_type
  HAVING devices > 0
),

first_seen AS (
  SELECT issue_id, error_type, MIN(DATE(event_timestamp)) AS first_seen_date
  FROM `commcare-a57e4.firebase_crashlytics.org_commcare_dalvik_ANDROID*`
  WHERE _TABLE_SUFFIX = ''
    AND DATE(event_timestamp) <= @end_date
    AND error_type IN ('FATAL', 'ANR')
  GROUP BY issue_id, error_type
),

issues AS (
  SELECT
    p.* EXCEPT (top_domain, top_device_model, top_os_version, top_app_version),
    f.first_seen_date,
    p.top_domain.value AS top_domain,
    p.top_domain.devices AS top_domain_devices,
    p.top_device_model.value AS top_device_model,
    p.top_device_model.devices AS top_device_model_devices,
    p.top_os_version.value AS top_os_version,
    p.top_os_version.devices AS top_os_version_devices,
    p.top_app_version.value AS top_app_version,
    p.top_app_version.devices AS top_app_version_devices,
    ROUND(1000 * p.devices / NULLIF(a.all_active, 0), 3) AS devices_per_1000,
    ROUND(1000 * p.connect_devices / NULLIF(a.connect_active, 0), 3) AS connect_devices_per_1000,
    ROUND(1000 * p.non_connect_devices / NULLIF(a.non_connect_active, 0), 3) AS non_connect_devices_per_1000,
    a.all_active AS active_devices,
    a.connect_active AS connect_active_devices,
    a.non_connect_active AS non_connect_active_devices,
    f.first_seen_date >= DATE_SUB(@end_date, INTERVAL @days - 1 DAY) AS is_new,
    p.devices >= 5 AND p.devices >= 2 * p.prior_devices AS is_rising,
    p.devices >= 5
      AND (IFNULL(p.top_domain.devices, 0) > p.devices / 2
           OR IFNULL(p.top_device_model.devices, 0) > p.devices / 2) AS is_concentrated
  FROM per_issue p
  CROSS JOIN active_devices a
  LEFT JOIN first_seen f USING (issue_id, error_type)
),

ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY error_type ORDER BY devices DESC, events DESC, issue_id) AS all_rank,
    IF(connect_devices > 0,
       ROW_NUMBER() OVER (PARTITION BY error_type ORDER BY connect_devices DESC, connect_events DESC, issue_id),
       NULL) AS connect_rank
  FROM issues
)

SELECT
  r.ranking,
  r.issue_rank,
  ranked.* EXCEPT (all_rank, connect_rank),
  DATE_SUB(@end_date, INTERVAL @days - 1 DAY) AS window_start,
  @end_date AS end_date
FROM ranked,
UNNEST([
  STRUCT('all' AS ranking, all_rank AS issue_rank),
  ('connect', connect_rank)
]) r
WHERE r.issue_rank <= @top_n
ORDER BY ranked.error_type DESC, r.ranking, r.issue_rank;
