--BigQuery query name: CommCare Release Health : Daily By Version

DECLARE release_version STRING DEFAULT '2.65.0';
DECLARE baseline_version STRING DEFAULT '2.64.1';
-- The day the store rollout started. Beta testers report the same version name
-- earlier, so release days before this are left out.
DECLARE release_start DATE DEFAULT DATE '2026-10-20';
DECLARE data_lag_days INT64 DEFAULT 2;
DECLARE pre_release_days INT64 DEFAULT 14;
DECLARE end_date DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL data_lag_days DAY);
DECLARE start_date DATE;

-- Never read past the rollup, or the latest days would have crashes but no users.
SET end_date = LEAST(end_date, (SELECT MAX(event_date) FROM `commcare-a57e4.mobile_metrics.ga_device_day`));

ASSERT end_date >= release_start
  AS 'No complete day of data since release_start yet - the exports lag by data_lag_days';

SET start_date = DATE_SUB(release_start, INTERVAL pre_release_days DAY);

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

-- Segment is decided across every version the device ran in the window, so an
-- upgrade cannot move a device between segments.
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

-- A crash without a device_id key falls back to its installation, which then
-- counts as a device of its own with no GA4 match.
crash_device_days AS (
  SELECT
    DATE(event_timestamp) AS event_date,
    IFNULL((SELECT k.value FROM UNNEST(custom_keys) k WHERE k.key = 'device_id'), installation_uuid) AS device_key,
    application.display_version AS app_version,
    COUNTIF(error_type = 'FATAL') AS crash_events,
    COUNTIF(error_type = 'ANR') AS anr_events,
    COUNTIF(error_type = 'NON_FATAL') AS nonfatal_events
  FROM `commcare-a57e4.firebase_crashlytics.org_commcare_dalvik_ANDROID`
  WHERE DATE(event_timestamp) BETWEEN start_date AND end_date
    AND application.display_version IN (release_version, baseline_version)
  GROUP BY event_date, device_key, app_version
),

-- A device was active on a day if GA4 saw it or it sent a crash report. Taking
-- the union keeps devices that crash before GA4 uploads anything, which is the
-- failure a broken release is most likely to cause.
device_days AS (
  SELECT
    event_date,
    device_key,
    app_version,
    LOGICAL_OR(in_ga) AS in_ga,
    SUM(crash_events) AS crash_events,
    SUM(anr_events) AS anr_events,
    SUM(nonfatal_events) AS nonfatal_events
  FROM (
    SELECT DISTINCT event_date, device_id AS device_key, app_version, TRUE AS in_ga,
           0 AS crash_events, 0 AS anr_events, 0 AS nonfatal_events
    FROM ga
    WHERE app_version IN (release_version, baseline_version)

    UNION ALL

    SELECT event_date, device_key, app_version, FALSE AS in_ga,
           crash_events, anr_events, nonfatal_events
    FROM crash_device_days
  )
  GROUP BY event_date, device_key, app_version
)

SELECT
  d.event_date,
  IF(d.app_version = release_version, 'release', 'baseline') AS version_role,
  d.app_version,
  IFNULL(s.user_segment, 'unmatched') AS user_segment,
  COUNT(*) AS device_days,
  COUNTIF(NOT d.in_ga) AS crash_only_device_days,
  COUNTIF(d.crash_events > 0) AS crash_device_days,
  SUM(d.crash_events) AS crash_events,
  COUNTIF(d.anr_events > 0) AS anr_device_days,
  SUM(d.anr_events) AS anr_events,
  COUNTIF(d.nonfatal_events > 0) AS nonfatal_device_days,
  SUM(d.nonfatal_events) AS nonfatal_events,
  release_start,
  end_date
FROM device_days d
LEFT JOIN segments s USING (device_key)
GROUP BY d.event_date, version_role, d.app_version, user_segment
ORDER BY d.event_date, version_role, user_segment;
