# CommCare crash & usage metrics

Numbers behind the crash-free and ANR-free user metrics that are currently kept by
hand in the **CommCare Mobile Metrics** spreadsheet (scraped from the Firebase
Crashlytics console).

`crash_usage_metrics.sql` is the measurement-only version: it emits the numbers so
they can be compared against the console, but writes nothing. Once the numbers look
right it becomes the `SELECT` feeding an `INSERT` into the history table described
below.

## Output

One row per app x window x event type, 8 rows per run.

| Column | Meaning |
|---|---|
| `run_date` | date the query ran |
| `app` | `commcare` (`org.commcare.dalvik`) or `lts` (`org.commcare.lts`) |
| `window_days` | 30 or 90 |
| `error_type` | `FATAL` (a crash) or `ANR` |
| `window_start` / `window_end` | inclusive window bounds |
| `total_events` | total crashes / ANRs |
| `affected_users` | unique crashing / ANR-ing users |
| `total_users` | unique active users over the window |
| `free_users_pct` | `100 * (1 - affected_users / total_users)` |
| `days_covered` | days of Crashlytics history actually present in the window |

`data_lag_days` (default 2) holds the window back from today. The Crashlytics export
lands a day or two late, and including a partial day badly understates the counts.

## Sources

| Metric | Table |
|---|---|
| crashes, ANRs, affected users | `firebase_crashlytics.org_commcare_dalvik_ANDROID`, `..._lts_ANDROID` |
| active users | `analytics_153906101.events_intraday_*` |

`error_type` separates the two event kinds. `FATAL` is what the console calls a crash;
`NON_FATAL` (logged exceptions, ~5M rows and by far the largest slice) is excluded.

Only `events_intraday_*` exists in `analytics_153906101` — this property has the
streaming export but not the daily batch one, which is why every query in this repo
reads the intraday shards.

## Caveats

**The percentage will not match the Firebase console exactly.** `affected_users` counts
Crashlytics installations (`installation_uuid`, 64 hex chars); `total_users` counts GA4
app instances (`user_pseudo_id`, 32 hex chars). The two ID spaces do not overlap at all,
so this is a ratio of two independently-derived device counts rather than a subset of a
whole. It tracks the console closely enough to trend against, but expect a standing
offset. Crashlytics does not expose its own crash-free-users figure through any API,
which is the whole reason the spreadsheet is filled by scraping.

A `device_id` custom key (`commcare_<uuid>`) is present on ~99.7% of Crashlytics events
and joins to the GA4 `device_id` user property as
`CONCAT('commcare_', <ga4 value>)`. That gives a single ID space for both sides, but
only ~87% of crashing devices match a GA4 device, so it trades one bias for another. It
is left unused for now; worth revisiting if the console comparison comes out poorly.

**LTS has no `total_users`.** `org.commcare.lts` has effectively no GA4 stream (6 users
over 30 days, against real Crashlytics traffic), so `total_users` and `free_users_pct`
are NULL for it. Its crash and ANR counts are sound. Getting a crash-free percentage for
LTS needs Analytics enabled in that build.

**The 90 day window is not yet full.** The Crashlytics export retains ~90 days, and
`FATAL`/`ANR` rows only begin 2026-07-02. Until ~2026-10-01 the 90 day rows are short on
events and read high on `free_users_pct` — watch `days_covered`. This is also the
argument for the history table: the export rolls off, an intermediate table does not.

**No Dimagi or staging exclusions.** Unlike the PersonalID queries, numerator and
denominator are left unfiltered so both sides count the same population. `cccStaging`
shares the `org.commcare.dalvik` applicationId but is negligible (~14 users/day).

## Cost

~65 GB per run, almost all of it the 90 day GA4 scan. Roughly $0.33 at on-demand
pricing; fine weekly, not something to run in a loop.

## Proposed history table

```
commcare-a57e4.mobile_metrics.crash_usage_history
```

Same columns as the query output, partitioned by `run_date` and clustered by
`app, error_type`. Long format rather than one wide row per run (as the spreadsheet
does) so new windows or event types are extra rows, not schema changes.

The insert step should be guarded so that a re-run on the same day replaces rather than
duplicates that day's rows — either `DELETE` the `run_date` first, or use `MERGE` on
`(run_date, app, window_days, error_type)`.
