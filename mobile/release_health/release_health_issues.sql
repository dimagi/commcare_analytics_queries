--BigQuery query name: CommCare Release Health : Issues On The Release

DECLARE release_version STRING DEFAULT '2.65.0';
DECLARE baseline_version STRING DEFAULT '2.64.1';
-- The day the store rollout started. Beta testers report the same version name
-- earlier, so release days before this are left out.
DECLARE release_start DATE DEFAULT DATE '2026-10-20';
DECLARE data_lag_days INT64 DEFAULT 2;
DECLARE end_date DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL data_lag_days DAY);

SET end_date = LEAST(end_date, (SELECT MAX(event_date) FROM `commcare-a57e4.mobile_metrics.ga_device_day`));

ASSERT end_date >= release_start
  AS 'No complete day of data since release_start yet - the exports lag by data_lag_days';

-- Reads the whole export (about 90 days) so that "never seen on another version"
-- means what it says, as far back as Crashlytics keeps anything.
WITH events AS (
  SELECT
    issue_id,
    issue_title,
    issue_subtitle,
    error_type,
    event_timestamp,
    DATE(event_timestamp) AS event_date,
    application.display_version AS app_version,
    IFNULL((SELECT k.value FROM UNNEST(custom_keys) k WHERE k.key = 'device_id'), installation_uuid) AS device_key
  FROM `commcare-a57e4.firebase_crashlytics.org_commcare_dalvik_ANDROID`
  WHERE DATE(event_timestamp) <= end_date
),

-- Junk spellings such as CommCare2.65.0 are the release, not another version.
-- Release events before release_start are beta testers, kept apart for the same reason.
per_issue AS (
  SELECT
    issue_id,
    ANY_VALUE(issue_title) AS issue_title,
    ANY_VALUE(issue_subtitle) AS issue_subtitle,
    ANY_VALUE(error_type) AS error_type,
    COUNTIF(app_version = release_version AND event_date >= release_start) AS release_events,
    COUNT(DISTINCT IF(app_version = release_version AND event_date >= release_start, device_key, NULL)) AS release_devices,
    COUNTIF(app_version = baseline_version AND event_date >= release_start) AS baseline_events,
    COUNT(DISTINCT IF(app_version = baseline_version AND event_date >= release_start, device_key, NULL)) AS baseline_devices,
    COUNTIF(ENDS_WITH(app_version, release_version) AND event_date < release_start) AS prerelease_events,
    COUNTIF(NOT ENDS_WITH(IFNULL(app_version, ''), release_version)) AS other_version_events,
    MIN(event_date) AS first_event_date,
    ARRAY_AGG(app_version ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_version
  FROM events
  GROUP BY issue_id
)

SELECT
  *,
  release_start,
  end_date
FROM per_issue
WHERE release_events > 0
ORDER BY release_devices DESC, release_events DESC;
