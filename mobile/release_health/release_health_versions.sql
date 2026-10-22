--BigQuery query name: CommCare Release Health : Versions In Use

DECLARE release_version STRING DEFAULT '2.65.0';
DECLARE baseline_version STRING DEFAULT '2.64.1';
-- The day the store rollout started. Beta testers report the same version name
-- earlier, so release days before this are left out.
DECLARE release_start DATE DEFAULT DATE '2026-10-20';
DECLARE data_lag_days INT64 DEFAULT 2;
DECLARE pre_release_days INT64 DEFAULT 14;
-- The "week" rows count distinct devices over this many days ending at end_date.
DECLARE week_days INT64 DEFAULT 7;
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

-- Active the same way as the daily query: GA4 saw the device or it sent any
-- Crashlytics report, on every version rather than two.
device_days AS (
  SELECT DISTINCT event_date, device_key, app_version
  FROM (
    SELECT event_date, device_id AS device_key, app_version
    FROM ga

    UNION ALL

    SELECT
      DATE(event_timestamp) AS event_date,
      IFNULL((SELECT k.value FROM UNNEST(custom_keys) k WHERE k.key = 'device_id'), installation_uuid) AS device_key,
      application.display_version AS app_version
    FROM `commcare-a57e4.firebase_crashlytics.org_commcare_dalvik_ANDROID`
    WHERE DATE(event_timestamp) BETWEEN start_date AND end_date
  )
  WHERE app_version IS NOT NULL
    AND NOT (app_version = release_version AND event_date < release_start)
),

labelled AS (
  SELECT
    d.event_date,
    d.device_key,
    d.app_version,
    IFNULL(s.user_segment, 'unmatched') AS user_segment
  FROM device_days d
  LEFT JOIN segments s USING (device_key)
)

-- A NULL app_version row counts each device once across every version, since a
-- device that upgraded mid-window appears under both of its versions.
SELECT
  'day' AS grain,
  event_date,
  app_version,
  user_segment,
  COUNT(DISTINCT device_key) AS devices,
  release_start,
  end_date
FROM labelled
GROUP BY GROUPING SETS ((event_date, app_version, user_segment), (event_date, user_segment))

UNION ALL

SELECT
  'week' AS grain,
  CAST(NULL AS DATE) AS event_date,
  app_version,
  user_segment,
  COUNT(DISTINCT device_key) AS devices,
  release_start,
  end_date
FROM labelled
WHERE event_date > DATE_SUB(end_date, INTERVAL week_days DAY)
GROUP BY GROUPING SETS ((app_version, user_segment), (user_segment))

ORDER BY grain, event_date, app_version, user_segment;
