--BigQuery query name: CommCare Release Health : Same Devices Before And After

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

-- Same demo, segment and device-day rules as release_health_daily.sql.
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

device_days AS (
  SELECT
    event_date,
    device_key,
    app_version,
    SUM(crash_events) AS crash_events,
    SUM(anr_events) AS anr_events,
    SUM(nonfatal_events) AS nonfatal_events
  FROM (
    SELECT DISTINCT event_date, device_id AS device_key, app_version,
           0 AS crash_events, 0 AS anr_events, 0 AS nonfatal_events
    FROM ga
    WHERE app_version IN (release_version, baseline_version)

    UNION ALL

    SELECT event_date, device_key, app_version, crash_events, anr_events, nonfatal_events
    FROM crash_device_days
  )
  GROUP BY event_date, device_key, app_version
),

first_release AS (
  SELECT device_key, MIN(event_date) AS first_release_day
  FROM device_days
  WHERE app_version = release_version
    AND event_date >= release_start
  GROUP BY device_key
),

-- Upgraded devices: baseline days before their own upgrade, then release days.
-- Stayed devices are the control for whatever else changed over the same weeks:
-- baseline days before the release started, then baseline days after it.
-- Devices that went back to the baseline after upgrading lose those days.
labelled AS (
  SELECT
    d.*,
    IF(f.device_key IS NULL, 'stayed', 'upgraded') AS cohort,
    CASE
      WHEN f.device_key IS NOT NULL AND d.app_version = baseline_version AND d.event_date < f.first_release_day THEN 'before'
      WHEN f.device_key IS NOT NULL AND d.app_version = release_version AND d.event_date >= release_start THEN 'after'
      WHEN f.device_key IS NULL AND d.app_version = baseline_version AND d.event_date < release_start THEN 'before'
      WHEN f.device_key IS NULL AND d.app_version = baseline_version THEN 'after'
    END AS period
  FROM device_days d
  LEFT JOIN first_release f USING (device_key)
),

-- Only devices seen in both periods, so each cohort is compared with itself.
paired AS (
  SELECT *
  FROM labelled
  WHERE period IS NOT NULL
  QUALIFY COUNT(DISTINCT period) OVER (PARTITION BY device_key) = 2
)

SELECT
  p.cohort,
  p.period,
  IFNULL(s.user_segment, 'unmatched') AS user_segment,
  COUNT(DISTINCT p.device_key) AS devices,
  COUNT(*) AS device_days,
  COUNTIF(p.crash_events > 0) AS crash_device_days,
  SUM(p.crash_events) AS crash_events,
  COUNTIF(p.anr_events > 0) AS anr_device_days,
  SUM(p.anr_events) AS anr_events,
  COUNTIF(p.nonfatal_events > 0) AS nonfatal_device_days,
  SUM(p.nonfatal_events) AS nonfatal_events,
  release_start,
  end_date
FROM paired p
LEFT JOIN segments s USING (device_key)
GROUP BY p.cohort, p.period, user_segment
ORDER BY p.cohort DESC, p.period, user_segment;
