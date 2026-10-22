--BigQuery query name: PersonalID OTP: Failures By Method And Reason

-- Breaks down the otp_requested events of one app version by day, event type, method,
-- outcome and reason. A Firebase phone request that fails with a non-recoverable error
-- makes the app switch to PersonalID SMS and request again straight away, so one user
-- action logs a Firebase failure and then a PersonalID outcome. is_fallback_handoff
-- marks those Firebase failures: leave them out to count each request once, by the
-- outcome the user actually saw.
--
-- Reads the raw GA4 export, about 4 GB a day. Keep the window to four days or so per
-- run to stay under a 20 GB cap.

DECLARE app_version STRING DEFAULT '2.64.1';
DECLARE start_date DATE DEFAULT DATE '2026-10-13';
DECLARE end_date DATE DEFAULT DATE '2026-10-16';
-- The PersonalID request follows the Firebase failure within a second or two. Larger
-- gaps are a user pressing resend.
DECLARE handoff_seconds INT64 DEFAULT 120;

WITH otp AS (
  SELECT
    PARSE_DATE('%Y%m%d', _TABLE_SUFFIX) AS day,
    user_pseudo_id,
    event_timestamp,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'event_type') AS event_type,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'method') AS method,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'outcome') AS outcome,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'reason') AS reason,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'workflow') AS workflow
  FROM `commcare-a57e4.analytics_153906101.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', start_date) AND FORMAT_DATE('%Y%m%d', end_date)
    AND app_info.version = app_version
    AND event_name = 'otp_requested'
),

sequenced AS (
  SELECT
    *,
    LEAD(event_type) OVER w AS next_event_type,
    LEAD(method) OVER w AS next_method,
    LEAD(event_timestamp) OVER w AS next_timestamp
  FROM otp
  WINDOW w AS (PARTITION BY user_pseudo_id ORDER BY event_timestamp)
)

SELECT
  day,
  event_type,
  method,
  outcome,
  reason,
  workflow,
  IFNULL(
    event_type = 'request' AND method = 'firebase' AND outcome = 'failure'
    AND next_event_type = 'request' AND next_method = 'personal_id'
    AND next_timestamp - event_timestamp < handoff_seconds * 1000000,
    FALSE) AS is_fallback_handoff,
  COUNT(*) AS events,
  COUNT(DISTINCT user_pseudo_id) AS instances
FROM sequenced
GROUP BY day, event_type, method, outcome, reason, workflow, is_fallback_handoff
ORDER BY day, event_type, method, outcome, events DESC;
