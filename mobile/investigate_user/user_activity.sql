--BigQuery query name: Investigate User : Activity Of A PersonalID User

WITH events AS (
  SELECT
    PARSE_DATE('%Y%m%d', _TABLE_SUFFIX) AS export_date,
    CONCAT('commcare_', (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'device_id')) AS device_id,
    IFNULL(app_info.version, 'unknown') AS app_version,
    event_name,
    (SELECT COALESCE(p.value.int_value, SAFE_CAST(p.value.string_value AS INT64)) FROM UNNEST(event_params) p WHERE p.key = 'success') AS success,
    (SELECT COALESCE(p.value.int_value, SAFE_CAST(p.value.string_value AS INT64)) FROM UNNEST(event_params) p WHERE p.key = 'value') AS int_value,
    (SELECT COALESCE(p.value.int_value, SAFE_CAST(p.value.string_value AS INT64)) FROM UNNEST(event_params) p WHERE p.key = 'ccc_api_success') AS api_success,
    (SELECT p.value.string_value FROM UNNEST(event_params) p WHERE p.key = 'reason') AS reason,
    (SELECT p.value.string_value FROM UNNEST(event_params) p WHERE p.key = 'result') AS result,
    (SELECT p.value.string_value FROM UNNEST(event_params) p WHERE p.key = 'item_id') AS item_id,
    (SELECT p.value.string_value FROM UNNEST(event_params) p WHERE p.key = 'event_type') AS event_type,
    (SELECT p.value.string_value FROM UNNEST(event_params) p WHERE p.key = 'outcome') AS outcome
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', @start_date) AND FORMAT_DATE('%Y%m%d', @end_date)
    AND (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_cid') = @user_cid
),

classified AS (
  SELECT export_date, device_id, app_version, c.category, c.is_attempt, c.is_failure
  FROM events,
  UNNEST(
    ARRAY_CONCAT(
      [STRUCT('all_events' AS category, CAST(NULL AS BOOL) AS is_attempt, CAST(NULL AS BOOL) AS is_failure)],
      CASE event_name
        WHEN 'session_start' THEN [STRUCT('session_start' AS category, CAST(NULL AS BOOL) AS is_attempt, CAST(NULL AS BOOL) AS is_failure)]
        WHEN 'screen_view' THEN [STRUCT('screen_view' AS category, CAST(NULL AS BOOL) AS is_attempt, CAST(NULL AS BOOL) AS is_failure)]
        WHEN 'first_open' THEN [STRUCT('first_open' AS category, CAST(NULL AS BOOL) AS is_attempt, CAST(NULL AS BOOL) AS is_failure)]
        WHEN 'app_update' THEN [STRUCT('app_update' AS category, CAST(NULL AS BOOL) AS is_attempt, CAST(NULL AS BOOL) AS is_failure)]
        WHEN 'app_exception' THEN [STRUCT('app_exception' AS category, CAST(NULL AS BOOL) AS is_attempt, TRUE AS is_failure)]
        WHEN 'sync_attempt' THEN [
          STRUCT('sync' AS category, TRUE AS is_attempt, success = 0 AS is_failure),
          STRUCT('sync_non_network', TRUE,
                 success = 0
                 AND IFNULL(reason, '') NOT IN
                     ('no_connection', 'unreachable_host', 'connection_timeout', 'captive_portal', 'cancelled'))
        ]
        WHEN 'form_upload_attempt' THEN [
          STRUCT('form_upload' AS category, TRUE AS is_attempt, result != 'FULL_SUCCESS' AS is_failure),
          STRUCT('form_upload_non_network', TRUE, result NOT IN ('FULL_SUCCESS', 'TRANSPORT_FAILURE', 'CAPTIVE_PORTAL'))
        ]
        WHEN 'form_quarantine_event' THEN [
          STRUCT('form_quarantine' AS category, CAST(NULL AS BOOL) AS is_attempt, IFNULL(item_id, '') != 'manual-quarantine' AS is_failure)
        ]
        WHEN 'common_commcare_event' THEN [
          STRUCT(
            CASE item_id
              WHEN 'corrupt_app_state' THEN 'corrupt_app_state'
              WHEN 'stage_update_failure' THEN 'update_stage_failure'
              WHEN 'update_reset' THEN 'update_reset'
            END AS category,
            CAST(NULL AS BOOL) AS is_attempt,
            TRUE AS is_failure)
        ]
        WHEN 'in_app_update_event' THEN [STRUCT('in_app_update' AS category, TRUE AS is_attempt, int_value = 0 AS is_failure)]
        WHEN 'personal_id_configuration_failure' THEN [
          STRUCT('personalid_config_failure' AS category, CAST(NULL AS BOOL) AS is_attempt, TRUE AS is_failure)
        ]
        WHEN 'otp_requested' THEN [
          STRUCT(
            CASE
              WHEN event_type IN ('request', 'request_email') THEN 'otp_request'
              WHEN event_type IN ('verify', 'verify_email') THEN 'otp_verify'
            END AS category,
            TRUE AS is_attempt,
            outcome = 'failure' AS is_failure)
        ]
        WHEN 'personalid_account_recovered' THEN [STRUCT('personalid_recovery' AS category, TRUE AS is_attempt, int_value = 0 AS is_failure)]
        WHEN 'ccc_api_jobs' THEN [STRUCT('connect_api_jobs' AS category, TRUE AS is_attempt, api_success = 0 AS is_failure)]
        WHEN 'ccc_api_start_learning' THEN [STRUCT('connect_api_start_learning' AS category, TRUE AS is_attempt, api_success = 0 AS is_failure)]
        WHEN 'ccc_api_claim_job' THEN [STRUCT('connect_api_claim_job' AS category, TRUE AS is_attempt, api_success = 0 AS is_failure)]
        WHEN 'ccc_api_payment_confirmation' THEN [STRUCT('connect_api_payment_confirmation' AS category, TRUE AS is_attempt, api_success = 0 AS is_failure)]
        WHEN 'ccc_api_learn_progress' THEN [STRUCT('connect_api_learn_progress' AS category, CAST(NULL AS BOOL) AS is_attempt, api_success = 0 AS is_failure)]
        WHEN 'ccc_api_delivery_progress' THEN [STRUCT('connect_api_delivery_progress' AS category, CAST(NULL AS BOOL) AS is_attempt, api_success = 0 AS is_failure)]
        ELSE []
      END
    )
  ) c
  WHERE c.category IS NOT NULL
)

SELECT
  export_date,
  device_id,
  app_version,
  category,
  COUNT(*) AS events,
  IF(LOGICAL_OR(is_attempt), COUNTIF(is_attempt), NULL) AS attempts,
  IF(LOGICAL_OR(is_failure IS NOT NULL), COUNTIF(is_failure), NULL) AS failures,
  @start_date AS start_date,
  @end_date AS end_date
FROM classified
GROUP BY export_date, device_id, app_version, category
ORDER BY export_date, device_id, app_version, category;
