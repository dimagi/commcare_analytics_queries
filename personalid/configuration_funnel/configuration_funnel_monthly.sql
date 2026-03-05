--Approach: Flag desired points, then combine for each user, then combine flag combinations and count users
--Session-based, and grouped by simplified outcome state

--Outermost query is to combine outcomes and count users/sessions
WITH summarized_data AS (
SELECT
  outcome,
  SUM(users) AS users,
  SUM(sessions) AS sessions,
  MIN(min_date) as min_date,
  MAX(max_date) as max_date
FROM (
  --This query is the session-based funnel, identifying pathways for each usage session
  SELECT
    final_state,
    MIN(min_date) as min_date,
    MAX(max_date) as max_date,
    CASE
      WHEN final_state = "Created" THEN "Created"
      WHEN final_state = "Locked" THEN "Locked"
      WHEN final_state = "Locked (new)" THEN "Locked (new)"
      WHEN final_state = "Recovered" THEN "Recovered"
      WHEN photo_page = 1 THEN "Photo"
      WHEN backup_code_page = 1 THEN "Backup Code"
      WHEN name_page = 1 THEN "Name"
      WHEN otp_page = 1 THEN "OTP"
      WHEN biometric_page = 1 AND (
        biometric_enrollment_failed = 1
        OR min_biometric_hardware_absent = 1
        OR min_biometric_hardware_unavailable = 1
        OR min_biometric_needs_update = 1
      ) THEN "Biometric Error"
      WHEN biometric_page = 1 THEN "Biometric"
      WHEN phone_page = 1 AND (
        start_configuration_integrity_device_failure = 1
        OR play_services_2  = 1
        OR play_services_9 = 1
      ) THEN "Phone Error"
      WHEN phone_page = 1 THEN "Phone"
    ELSE "" END AS outcome,

    CASE WHEN
      start_configuration_integrity_device_failure > 0
      OR play_services_2 > 0
      OR play_services_9 > 0
      OR biometric_enrollment_failed > 0
      OR min_biometric_hardware_absent > 0
      OR min_biometric_hardware_unavailable > 0
      OR min_biometric_needs_update > 0
    THEN 1 ELSE 0 END AS had_errors,
    
    COUNT(DISTINCT(user_pseudo_id)) AS users,
    COUNT(ga_session_id) AS sessions,
    phone_page,
    start_configuration_integrity_device_failure,
    play_services_2,
    play_services_9,
    biometric_page,
    biometric_enrollment_failed,
    min_biometric_hardware_absent,
    min_biometric_hardware_unavailable,
    min_biometric_needs_update,
    otp_page,
    start_configuration_locked_account_failure,
    name_page,
    backup_code_page,
    incorrect_backup_codes,
    recovered,
    photo_page,
    created,
    CASE WHEN COUNT(user_pseudo_id) = 1 THEN MAX(last_created) ELSE NULL END as last_created,
    CASE WHEN COUNT(user_pseudo_id) = 1 THEN MAX(last_recovered) ELSE NULL END as last_recovered,
    CASE WHEN COUNT(user_pseudo_id) = 1 THEN MAX(last_lockout) ELSE NULL END as last_lockout,
    CASE WHEN COUNT(user_pseudo_id) = 1 THEN MAX(last_wrong_backup_code) ELSE NULL END as last_wrong_backup_code
  FROM
  (
    --Results here are a list of sessions (for a user, older vs recent)
    SELECT
      user_pseudo_id,
      ga_session_id,
      MIN(event_datetime) as min_date,
      MAX(event_datetime) as max_date,
      MAX(phone_page) AS phone_page,
      MAX(start_configuration_integrity_device_failure) AS start_configuration_integrity_device_failure,
      MAX(play_services_2) AS play_services_2,
      MAX(play_services_9) AS play_services_9,
      MAX(biometric_page) AS biometric_page,
      MAX(biometric_enrollment_failed) AS biometric_enrollment_failed,
      MAX(min_biometric_hardware_absent) AS min_biometric_hardware_absent,
      MAX(min_biometric_hardware_unavailable) AS min_biometric_hardware_unavailable,
      MAX(min_biometric_needs_update) AS min_biometric_needs_update,
      MAX(otp_page) AS otp_page,
      MAX(name_page) AS name_page,
      MAX(backup_code_page) AS backup_code_page,
      MAX(start_configuration_locked_account_failure) AS start_configuration_locked_account_failure,
      MAX(lockout_date) AS last_lockout,
      MAX(recovered) AS recovered,
      SUM(incorrect_backup_code) AS incorrect_backup_codes,
      MAX(recovered_date) AS last_recovered,
      MAX(photo_page) AS photo_page,
      MAX(created) AS created,
      MAX(created_date) AS last_created,
      MAX(wrong_backup_code_date) AS last_wrong_backup_code,
      CASE
          WHEN SUM(incorrect_backup_code) > 2 AND (
            (MAX(recovered_date) IS NOT NULL AND MAX(wrong_backup_code_date) > MAX(recovered_date))
            OR (MAX(recovered_date) IS NULL AND MAX(wrong_backup_code_date) > MAX(created_date))
          ) THEN "Locked (new)"
          WHEN MAX(lockout_date) IS NOT NULL AND (
            (MAX(recovered_date) IS NOT NULL AND MAX(lockout_date) > MAX(recovered_date))
            OR (MAX(recovered_date) IS NULL AND MAX(lockout_date) > MAX(created_date))
          ) THEN "Locked"
          WHEN MAX(recovered_date) IS NOT NULL THEN "Recovered"
          WHEN MAX(created_date) IS NOT NULL THEN "Created"
          WHEN MAX(lockout_date) IS NOT NULL THEN "Locked"
          WHEN SUM(incorrect_backup_code) > 2 THEN "Locked (new)"
          ELSE "Not configured" --distinguish errors vs aborted
        END AS final_state
    FROM (
      --Filter by desired event
      SELECT
        user_pseudo_id,
        ga_session_id,
        event_datetime,
        CASE WHEN screen_name="PersonalIdPhoneFragment" THEN 1 ELSE 0 END AS phone_page,
        CASE WHEN outcome = "start_configuration_integrity_device_failure" THEN 1 ELSE 0 END AS start_configuration_integrity_device_failure,
        CASE WHEN outcome = "play_services_2" THEN 1 ELSE 0 END AS play_services_2,
        CASE WHEN outcome = "play_services_9" THEN 1 ELSE 0 END AS play_services_9,
        CASE WHEN screen_name="PersonalIdBiometricConfigFragment" THEN 1 ELSE 0 END AS biometric_page,
        CASE WHEN outcome = "biometric_enrollment_failed" THEN 1 ELSE 0 END AS biometric_enrollment_failed,
        CASE WHEN outcome = "min_biometric_hardware_absent" THEN 1 ELSE 0 END AS min_biometric_hardware_absent,
        CASE WHEN outcome = "min_biometric_hardware_unavailable" THEN 1 ELSE 0 END AS min_biometric_hardware_unavailable,
        CASE WHEN outcome = "min_biometric_needs_update" THEN 1 ELSE 0 END AS min_biometric_needs_update,
        CASE WHEN screen_name="PersonalIdPhoneVerificationFragment" THEN 1 ELSE 0 END AS otp_page,
        CASE WHEN screen_name="PersonalIdNameFragment" THEN 1 ELSE 0 END AS name_page,
        CASE WHEN screen_name="PersonalIdBackupCodeFragment" THEN 1 ELSE 0 END AS backup_code_page,
        CASE WHEN outcome = "start_configuration_locked_account_failure" THEN 1 ELSE 0 END AS start_configuration_locked_account_failure,
        CASE WHEN outcome = "start_configuration_locked_account_failure" THEN event_datetime ELSE NULL END AS lockout_date,
        CASE WHEN outcome="recovered" AND success=1 THEN 1 ELSE 0 END AS recovered,
        CASE WHEN outcome="recovered" AND success=1 THEN event_datetime ELSE NULL END AS recovered_date,
        CASE WHEN outcome="recovered" AND success=0 THEN 1 ELSE 0 END AS incorrect_backup_code,
        CASE WHEN outcome="recovered" AND success=0 THEN event_datetime ELSE NULL END AS wrong_backup_code_date,
        CASE WHEN screen_name="PersonalIdPhotoCaptureFragment" THEN 1 ELSE 0 END AS photo_page,
        CASE WHEN outcome="created" THEN 1 ELSE 0 END AS created,
        CASE WHEN outcome="created" THEN event_datetime ELSE NULL END AS created_date      
      FROM (
        --Extract fields over the two time windows
        SELECT
          event_name,
          user_pseudo_id,
          MAX(IF(ep1.key = 'ga_session_id', ep1.value.int_value, NULL)) AS ga_session_id,
          MAX(IF(ep1.key = 'ga_session_number', ep1.value.int_value, NULL)) AS ga_session_number,
          MAX(IF(ep1.key = 'value', ep1.value.int_value, NULL)) AS success,
          FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', timestamp_micros(event_timestamp), 'UTC') as event_datetime,
          
          --Blank out the screen_name for errors (the failure_reason is all we want then)
          CASE WHEN event_name = "personal_id_configuration_failure" OR event_name="personalid_account_created" OR event_name="personalid_account_recovered"
            THEN "" ELSE COALESCE (SUBSTR(MAX(IF(ep1.key = 'firebase_screen_class', ep1.value.string_value, "")), 35), "")
          END AS screen_name,
          
          CASE
            WHEN event_name="personalid_account_created" THEN "created"
            WHEN event_name="personalid_account_recovered" THEN "recovered"
            ELSE MAX(IF(ep1.key='reason', ep1.value.string_value, ""))
          END as outcome,
          
          is_demo_user
        FROM (
          SELECT
            t.user_pseudo_id,
            t.event_name,
            t.event_timestamp,
            ep1,

            -- If a user has ever been flagged as a demo user, we want to keep that flag across all events
            MAX(IF(up.key = 'is_personal_id_demo_user' AND up.value.string_value = 'true', 1, 0)) OVER (PARTITION BY user_pseudo_id) AS is_demo_user

          FROM `commcare-a57e4.analytics_153906101.events_intraday_*` as t
          LEFT JOIN UNNEST(t.user_properties) AS up
          LEFT JOIN UNNEST(t.event_params) as ep1
          WHERE
            _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH))
                              AND FORMAT_DATE('%Y%m%d', DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 DAY))

          --  _TABLE_SUFFIX BETWEEN '20250601' AND '20250630'
          --   (_TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH))
          --                     AND FORMAT_DATE('%Y%m%d', CURRENT_DATE()))
          --  OR
          --   (_TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY)) --60
          --                     AND FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL 31 DAY))) --31
        )
        GROUP BY user_pseudo_id, event_name, event_timestamp, is_demo_user
      )
      WHERE
        ((event_name = "screen_view" AND CONTAINS_SUBSTR(screen_name, "PersonalId") AND NOT CONTAINS_SUBSTR(screen_name, "Activity"))
        OR event_name="personal_id_configuration_failure"
        OR event_name="personalid_account_created"
        OR event_name="personalid_account_recovered")

        -- Exlude any user that has ever been flagged as a demo user
        AND is_demo_user = 0
    ) 
    GROUP BY user_pseudo_id, ga_session_id
  )
  GROUP BY
    phone_page,
    start_configuration_integrity_device_failure,
    play_services_2,
    play_services_9,
    biometric_page,
    biometric_enrollment_failed,
    min_biometric_hardware_absent,
    min_biometric_hardware_unavailable,
    min_biometric_needs_update,
    otp_page,
    name_page,
    backup_code_page,
    start_configuration_locked_account_failure,
    incorrect_backup_codes,
    recovered,
    photo_page,
    created,
    final_state
  ORDER BY 
    final_state,
    phone_page,
    biometric_page,
    otp_page,
    name_page,
    backup_code_page,
    photo_page,
    recovered,
    incorrect_backup_codes,
    created,
    start_configuration_integrity_device_failure,
    play_services_2,
    play_services_9,
    biometric_enrollment_failed,
    min_biometric_hardware_absent,
    min_biometric_hardware_unavailable,
    min_biometric_needs_update,
    start_configuration_locked_account_failure,
    final_state
)
GROUP BY outcome
ORDER BY outcome
)

SELECT
  MIN(min_date) AS min_date,
  MAX(max_date) AS max_date,
  MAX(CASE WHEN outcome = 'Phone' THEN users END) AS phone,
  MAX(CASE WHEN outcome = 'Biometric' THEN users END) AS biometric,
  MAX(CASE WHEN outcome = 'OTP' THEN users END) AS otp,
  MAX(CASE WHEN outcome = 'Name' THEN users END) AS name,
  MAX(CASE WHEN outcome = 'Backup Code' THEN users END) AS backup_code,
  MAX(CASE WHEN outcome = 'Photo' THEN users END) AS photo,
  MAX(CASE WHEN outcome = 'Phone Error' THEN users END) AS phone_error,
  MAX(CASE WHEN outcome = 'Biometric Error' THEN users END) AS biometric_error,
  MAX(CASE WHEN outcome = 'Locked' THEN users END) AS locked,
  MAX(CASE WHEN outcome = 'Locked (new)' THEN users END) AS locked_new,
  MAX(CASE WHEN outcome = 'Recovered' THEN users END) AS recovered,
  MAX(CASE WHEN outcome = 'Created' THEN users END) AS created
FROM summarized_data