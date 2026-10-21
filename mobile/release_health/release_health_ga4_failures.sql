--BigQuery query name: CommCare Release Health : GA4 Failures By Version

DECLARE release_version STRING DEFAULT '2.65.0';
DECLARE baseline_version STRING DEFAULT '2.64.1';
-- The day the store rollout started. Beta testers report the same version name
-- earlier, so release days before this are left out.
DECLARE release_start DATE DEFAULT DATE '2026-10-20';
DECLARE data_lag_days INT64 DEFAULT 2;
DECLARE pre_release_days INT64 DEFAULT 14;
DECLARE end_date DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL data_lag_days DAY);
DECLARE start_date DATE;

SET end_date = LEAST(end_date, (SELECT MAX(event_date) FROM `commcare-a57e4.mobile_metrics.ga_device_day`));

ASSERT end_date >= release_start
  AS 'No complete day of data since release_start yet - the exports lag by data_lag_days';

SET start_date = DATE_SUB(release_start, INTERVAL pre_release_days DAY);

-- Bundle.putLong lands in int_value. The string fallback costs nothing extra, as
-- str_param reads that column anyway; double_value is left unread, which saves scan.
CREATE TEMP FUNCTION int_param(params ANY TYPE, name STRING) AS ((
  SELECT COALESCE(p.value.int_value, SAFE_CAST(p.value.string_value AS INT64))
  FROM UNNEST(params) p
  WHERE p.key = name
));

CREATE TEMP FUNCTION str_param(params ANY TYPE, name STRING) AS ((
  SELECT p.value.string_value FROM UNNEST(params) p WHERE p.key = name
));

-- Same demo, segment and day rules as release_health_daily.sql.
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

ga AS (
  SELECT event_date, device_id, app_version, is_connect
  FROM `commcare-a57e4.mobile_metrics.ga_device_day`
  WHERE event_date BETWEEN start_date AND end_date
    AND device_id IS NOT NULL
),

segments AS (
  SELECT
    device_id AS device_key,
    CASE
      WHEN NOT LOGICAL_OR(is_connect) THEN 'non-connect'
      WHEN device_id IN (SELECT device_id FROM demo_devices) THEN 'connect-demo'
      ELSE 'connect'
    END AS user_segment
  FROM ga
  GROUP BY device_id
),

-- Only GA4 can send these events, so the denominator is the device-days GA4 saw,
-- not the GA4-or-Crashlytics union the daily query uses. Days before release_start
-- are not read: the report compares the two versions from that day on, and every
-- day of GA4 events costs several GB.
device_days AS (
  SELECT DISTINCT event_date, device_id AS device_key, app_version
  FROM ga
  WHERE app_version IN (release_version, baseline_version)
    AND event_date >= release_start
),

-- The rollup already maps each app instance to its device_id, and only holds
-- org.commcare.dalvik, so the events never read user_properties or app_info.id,
-- the two most expensive columns.
instance_devices AS (
  SELECT event_date, user_pseudo_id, app_version, MIN(device_id) AS device_key
  FROM `commcare-a57e4.mobile_metrics.ga_device_day`
  WHERE event_date BETWEEN release_start AND end_date
    AND device_id IS NOT NULL
    AND app_version IN (release_version, baseline_version)
  GROUP BY event_date, user_pseudo_id, app_version
),

-- _TABLE_SUFFIX alone prunes the shards, with a day of slack either side. The day
-- comes from the event timestamp, as in ga_device_day_insert.sql, so every event
-- falls on a device-day the rollup holds.
events AS (
  SELECT
    event_date,
    i.device_key,
    app_version,
    e.event_name,
    e.event_params
  FROM (
    SELECT
      DATE(TIMESTAMP_MICROS(event_timestamp)) AS event_date,
      user_pseudo_id,
      app_info.version AS app_version,
      event_name,
      event_params
    FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
    WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(release_start, INTERVAL 1 DAY))
                            AND FORMAT_DATE('%Y%m%d', DATE_ADD(end_date, INTERVAL 1 DAY))
      AND app_info.version IN (release_version, baseline_version)
      AND event_name IN (
        'sync_attempt', 'form_upload_attempt', 'form_quarantine_event', 'common_commcare_event',
        'in_app_update_event', 'personal_id_configuration_failure', 'otp_requested',
        'personalid_account_recovered', 'ccc_api_jobs', 'ccc_api_start_learning',
        'ccc_api_claim_job', 'ccc_api_payment_confirmation', 'ccc_api_learn_progress',
        'ccc_api_delivery_progress'
      )
  ) e
  JOIN instance_devices i USING (event_date, user_pseudo_id, app_version)
),

-- One row per event and category it counts towards. is_attempt is NULL for
-- categories with no attempt count: those events are only ever failures, or the
-- app logs success too unevenly for successes to mean anything.
classified AS (
  SELECT event_date, device_key, app_version, category, is_attempt, is_failure
  FROM events,
  UNNEST(
    CASE event_name
      WHEN 'sync_attempt' THEN [
        STRUCT('sync' AS category, TRUE AS is_attempt, int_param(event_params, 'success') = 0 AS is_failure),
        STRUCT('sync_non_network', TRUE,
               int_param(event_params, 'success') = 0
               AND IFNULL(str_param(event_params, 'reason'), '') NOT IN
                   ('no_connection', 'unreachable_host', 'connection_timeout', 'captive_portal', 'cancelled'))
      ]
      WHEN 'form_upload_attempt' THEN [
        STRUCT('form_upload' AS category, TRUE AS is_attempt, str_param(event_params, 'result') != 'FULL_SUCCESS' AS is_failure),
        STRUCT('form_upload_non_network', TRUE,
               str_param(event_params, 'result') NOT IN ('FULL_SUCCESS', 'TRANSPORT_FAILURE', 'CAPTIVE_PORTAL'))
      ]
      -- A user quarantining a form by hand is not a failure.
      WHEN 'form_quarantine_event' THEN [
        STRUCT('form_quarantine' AS category, CAST(NULL AS BOOL) AS is_attempt,
               IFNULL(str_param(event_params, 'item_id'), '') != 'manual-quarantine' AS is_failure)
      ]
      WHEN 'common_commcare_event' THEN [
        STRUCT(
          CASE str_param(event_params, 'item_id')
            WHEN 'corrupt_app_state' THEN 'corrupt_app_state'
            WHEN 'stage_update_failure' THEN 'update_stage_failure'
            WHEN 'update_reset' THEN 'update_reset'
          END AS category,
          CAST(NULL AS BOOL) AS is_attempt,
          TRUE AS is_failure)
      ]
      WHEN 'in_app_update_event' THEN [
        STRUCT('in_app_update' AS category, TRUE AS is_attempt, int_param(event_params, 'value') = 0 AS is_failure)
      ]
      WHEN 'personal_id_configuration_failure' THEN [
        STRUCT('personalid_config_failure' AS category, CAST(NULL AS BOOL) AS is_attempt, TRUE AS is_failure)
      ]
      WHEN 'otp_requested' THEN [
        STRUCT(
          CASE
            WHEN str_param(event_params, 'event_type') IN ('request', 'request_email') THEN 'otp_request'
            WHEN str_param(event_params, 'event_type') IN ('verify', 'verify_email') THEN 'otp_verify'
          END AS category,
          TRUE AS is_attempt,
          str_param(event_params, 'outcome') = 'failure' AS is_failure)
      ]
      WHEN 'personalid_account_recovered' THEN [
        STRUCT('personalid_recovery' AS category, TRUE AS is_attempt, int_param(event_params, 'value') = 0 AS is_failure)
      ]
      WHEN 'ccc_api_jobs' THEN [
        STRUCT('connect_api_jobs' AS category, TRUE AS is_attempt, int_param(event_params, 'ccc_api_success') = 0 AS is_failure)
      ]
      WHEN 'ccc_api_start_learning' THEN [
        STRUCT('connect_api_start_learning' AS category, TRUE AS is_attempt, int_param(event_params, 'ccc_api_success') = 0 AS is_failure)
      ]
      WHEN 'ccc_api_claim_job' THEN [
        STRUCT('connect_api_claim_job' AS category, TRUE AS is_attempt, int_param(event_params, 'ccc_api_success') = 0 AS is_failure)
      ]
      WHEN 'ccc_api_payment_confirmation' THEN [
        STRUCT('connect_api_payment_confirmation' AS category, TRUE AS is_attempt, int_param(event_params, 'ccc_api_success') = 0 AS is_failure)
      ]
      -- Success is logged only when the assessment is passed, or once per delivery
      -- milestone, so only the failures count.
      WHEN 'ccc_api_learn_progress' THEN [
        STRUCT('connect_api_learn_progress' AS category, CAST(NULL AS BOOL) AS is_attempt, int_param(event_params, 'ccc_api_success') = 0 AS is_failure)
      ]
      WHEN 'ccc_api_delivery_progress' THEN [
        STRUCT('connect_api_delivery_progress' AS category, CAST(NULL AS BOOL) AS is_attempt, int_param(event_params, 'ccc_api_success') = 0 AS is_failure)
      ]
    END
  )
  WHERE category IS NOT NULL
),

categories AS (
  SELECT category, has_attempts
  FROM UNNEST([
    STRUCT('sync' AS category, TRUE AS has_attempts),
    ('sync_non_network', TRUE),
    ('form_upload', TRUE),
    ('form_upload_non_network', TRUE),
    ('form_quarantine', FALSE),
    ('corrupt_app_state', FALSE),
    ('update_stage_failure', FALSE),
    ('update_reset', FALSE),
    ('in_app_update', TRUE),
    ('personalid_config_failure', FALSE),
    ('otp_request', TRUE),
    ('otp_verify', TRUE),
    ('personalid_recovery', TRUE),
    ('connect_api_jobs', TRUE),
    ('connect_api_start_learning', TRUE),
    ('connect_api_claim_job', TRUE),
    ('connect_api_payment_confirmation', TRUE),
    ('connect_api_learn_progress', FALSE),
    ('connect_api_delivery_progress', FALSE)
  ])
),

event_counts AS (
  SELECT
    event_date,
    device_key,
    app_version,
    category,
    COUNTIF(is_attempt) AS attempts,
    COUNTIF(is_failure) AS failures
  FROM classified
  GROUP BY event_date, device_key, app_version, category
),

-- Every device-day appears under every category, so a category with no events
-- still reports its device-days and a zero.
per_device_day AS (
  SELECT
    d.event_date,
    d.device_key,
    d.app_version,
    c.category,
    c.has_attempts,
    IFNULL(e.attempts, 0) AS attempts,
    IFNULL(e.failures, 0) AS failures
  FROM device_days d
  CROSS JOIN categories c
  LEFT JOIN event_counts e
    ON e.event_date = d.event_date
   AND e.device_key = d.device_key
   AND e.app_version = d.app_version
   AND e.category = c.category
)

SELECT
  p.event_date,
  IF(p.app_version = release_version, 'release', 'baseline') AS version_role,
  p.app_version,
  IFNULL(s.user_segment, 'unmatched') AS user_segment,
  p.category,
  COUNT(*) AS device_days,
  IF(ANY_VALUE(p.has_attempts), COUNTIF(p.attempts > 0), NULL) AS attempt_device_days,
  IF(ANY_VALUE(p.has_attempts), SUM(p.attempts), NULL) AS attempts,
  COUNTIF(p.failures > 0) AS failure_device_days,
  SUM(p.failures) AS failures,
  release_start,
  end_date
FROM per_device_day p
LEFT JOIN segments s USING (device_key)
GROUP BY p.event_date, version_role, p.app_version, user_segment, p.category
ORDER BY p.event_date, version_role, user_segment, p.category;
