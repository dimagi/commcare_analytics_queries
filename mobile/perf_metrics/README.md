# CommCare performance metrics

A daily summary of the Firebase Performance Monitoring export, so the medic can watch app
start, screen rendering, custom traces and network calls from BigQuery instead of the
Firebase alert emails, and so the history outlives the export's 60 day expiry.

## Files

| File | What it is |
|---|---|
| `perf_daily_table.sql` | DDL for `mobile_metrics.perf_daily`. Safe to re-run: `CREATE TABLE IF NOT EXISTS`. |
| `perf_daily_insert.sql` | **the query to schedule.** Refreshes the last few days and fills any gap. Safe to re-run. |

From a shell, pipe a file to bq on stdin, because a file opening with `--` reads as a flag:

```
bq query --use_legacy_sql=false --project_id=commcare-a57e4 < perf_daily_insert.sql
```

## Output

One row per day x app x version x trace.

| Column | Meaning |
|---|---|
| `event_date` | the day the trace ran, from `event_timestamp` |
| `app` | `commcare` (`org.commcare.dalvik`) or `lts` (`org.commcare.lts`) |
| `app_version` | `app_display_version`, or `unknown` |
| `trace_type` | `SCREEN_TRACE`, `DURATION_TRACE` or `NETWORK_REQUEST` |
| `trace_name` | `_st_<Activity>` for screens; `_app_start`, `_app_in_foreground`, `_app_in_background` or a custom trace name (`form_loading_time`, `case_search_time`, `sync_case_list_loading`, `app_sync_duration`, `file_encryption_time`, ...); the URL pattern for network requests |
| `sample_count` | traces or requests |
| `p50_ms`, `p90_ms` | duration percentiles. For network requests, the time to response completed |
| `duration_sketch` | KLL sketch of the duration in microseconds, for percentiles over several days or versions |
| `slow_screen_count`, `slow_screen_share` | screens only: instances with more than half their frames slow |
| `frozen_screen_count`, `frozen_screen_share` | screens only: instances with more than 0.1% of their frames frozen |
| `error_count`, `error_rate` | network only: no response code, or 400 and up |
| `server_error_count` | network only: 500 and up |

The slow and frozen rules are the ones the Firebase console uses for "slow rendering" and
"frozen frames", so the shares are comparable with what its alerts report.

### Percentiles over more than one day

Percentiles cannot be averaged or summed. To get one over a week, or over several
versions, merge the sketches:

```sql
SELECT app_version,
  SUM(sample_count) AS samples,
  KLL_QUANTILES.MERGE_POINT_INT64(duration_sketch, 0.9) / 1000 AS p90_ms
FROM `commcare-a57e4.mobile_metrics.perf_daily`
WHERE app = 'commcare' AND trace_name = '_app_start'
  AND event_date BETWEEN '2026-11-07' AND '2026-11-13'
GROUP BY app_version
```

The counts (`sample_count`, `slow_screen_count`, `frozen_screen_count`, `error_count`,
`server_error_count`) sum across rows; divide the sums for shares over a longer span.

### Network error rate

`error_rate` is mostly 403s, then 406s and 401s: responses HQ sends on purpose, not
failures. On the form submission endpoint (`receiver/secure/*`) it runs near 19% every
day. Watch it for change between versions or weeks, not for its level, and use
`server_error_count` for server trouble.

## How the refresh works

The export is a daily batch that lands about a day and a half late. Its partitions are
by ingestion day, not by the day the trace ran: a partition holds mostly that day's
events, a large share of the next day's (device clocks ahead of UTC), and a tail from the
two or three days before.

So the query:

- ends its window the day before the latest partition, where a day is mostly complete,
  rather than a fixed number of days behind today;
- redoes the last `refresh_days` (3) days it wrote on every run, which picks up the late
  tail and fills any gap a missed run left;
- reads every partition from two days before the window, and lets `event_timestamp`
  decide the day;
- backfills everything the export still holds into an empty table, skipping the first
  day, whose earlier events have already expired.

The delete and the insert share one transaction. A late event that arrives after its day
has left the refresh window is lost, which is well under 1% of a day.

The latest day in the table is always somewhat short until the next run redoes it.

## Cost

The backfill read 43.6 GB for 56 days. A daily run reads about 6 GB, roughly $1 a month.
The table holds about 1,800 rows a day.
