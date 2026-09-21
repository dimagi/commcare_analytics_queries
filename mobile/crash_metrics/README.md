# CommCare crash & usage metrics

Numbers behind the crash-free and ANR-free user metrics that are currently kept by
hand in the **CommCare Mobile Metrics** spreadsheet (scraped from the Firebase
Crashlytics console), broken down by Connect and non-Connect users.

`crash_usage_metrics.sql` is the measurement-only version: it emits the numbers so
they can be compared against the console, but writes nothing. Once the numbers look
right it becomes the `SELECT` feeding an `INSERT` into the history table described
below.

## Output

One row per app x id basis x segment x window x event type.

| Column | Meaning |
|---|---|
| `run_date` | date the query ran |
| `app` | `commcare` (`org.commcare.dalvik`) or `lts` (`org.commcare.lts`) |
| `id_basis` | how users are counted, `device` or `installation` (see below) |
| `user_segment` | `all`, `connect`, `mixed`, `non_connect`, `unknown` |
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

### The two id bases

`installation` rows reproduce the original console-comparable measure: Crashlytics
`installation_uuid` over GA4 `user_pseudo_id`. They cannot be segmented, and they are
the only rows available for LTS.

`device` rows use the `device_id` custom key for both numerator and denominator. This
is the basis that supports the Connect breakdown, and it is internally consistent -
the segments sum exactly to `all` on events, affected users and total users. It counts
fewer users than the installation basis (159k vs 194k over 30 days, since not every app
instance reports a `device_id`), so its percentages sit a little lower.

### Segments

Assigned per device per window from the GA4 `ccc_enabled` user property:

- `connect` - Connect enabled on every event in the window
- `mixed` - Connect enabled for part of the window only
- `non_connect` - never enabled
- `unknown` - crash events whose `device_id` did not match any GA4 device, so they
  cannot be placed. Numerator only, no denominator.

`mixed` exists because switchers behave much more like non-Connect users than Connect
ones (94.7% vs 76.8% ANR-free over 30 days). Folding them into `connect`, as an "ever
enabled" rule would, measurably dilutes the signal.

## Sources

| Metric | Table |
|---|---|
| crashes, ANRs, affected users | `firebase_crashlytics.org_commcare_dalvik_ANDROID`, `..._lts_ANDROID` |
| active users, Connect status | `analytics_153906101.events_intraday_*` |

`error_type` separates the two event kinds. `FATAL` is what the console calls a crash;
`NON_FATAL` (logged exceptions, ~5M rows and by far the largest slice) is excluded.

Only `events_intraday_*` exists in `analytics_153906101` - this property has the
streaming export but not the daily batch one, which is why every query in this repo
reads the intraday shards.

Crashlytics carries no Connect marker of its own, so the segment has to come from GA4
and be joined across on `device_id`. The Crashlytics custom key holds
`commcare_<uuid>`; the GA4 user property holds the bare uuid, hence the `CONCAT` in the
join, matching the existing PersonalID queries.

## Caveats

**The `unknown` bucket is the main source of doubt in the breakdown.** About 10% of
crashing devices and 11% of ANR-ing devices do not match any GA4 device, so they sit
outside both segments. They are shown rather than dropped, but if they skew toward one
segment the split moves. This is the number to watch if the breakdown ever looks wrong.

**`ccc_enabled` is read as "this device is running Connect".** It is the only Connect
signal on the user properties (alongside `ccc_job_id`, which is far sparser). Worth a
sanity check from someone who knows how the property is set in the app.

**Connect is a small base.** ~2,200 always-Connect devices over 30 days against ~155k
non-Connect, so Connect percentages move on much smaller counts and will be noisier
month to month.

**The `installation` percentage will not match the Firebase console exactly.**
`affected_users` counts Crashlytics installations (`installation_uuid`, 64 hex chars);
`total_users` counts GA4 app instances (`user_pseudo_id`, 32 hex chars). The two ID
spaces do not overlap at all, so this is a ratio of two independently-derived device
counts rather than a subset of a whole. Crashlytics does not expose its own
crash-free-users figure through any API, which is the whole reason the spreadsheet is
filled by scraping.

**LTS has no `total_users`.** `org.commcare.lts` has effectively no GA4 stream (6 users
over 30 days, against real Crashlytics traffic), so `total_users`, `free_users_pct` and
the Connect breakdown are all unavailable for it. Its crash and ANR counts are sound.
Getting anything more for LTS needs Analytics enabled in that build.

**The 90 day window is not yet full.** The Crashlytics export retains ~90 days, and
`FATAL`/`ANR` rows only begin 2026-07-02. Until ~2026-10-01 the 90 day rows are short on
events and read high on `free_users_pct` - watch `days_covered`. This is also the
argument for the history table: the export rolls off, an intermediate table does not.

**No Dimagi or staging exclusions.** Unlike the PersonalID queries, numerator and
denominator are left unfiltered so both sides count the same population. `cccStaging`
shares the `org.commcare.dalvik` applicationId but is negligible (~14 users/day).

## Cost

~430 GB per run, nearly all of it reading GA4 `user_properties` over 90 days for the
`device_id` and `ccc_enabled` lookups. Roughly $2.15 at on-demand pricing. Fine monthly;
worth knowing before putting it on a faster schedule. Dropping the Connect breakdown
would take it back to ~65 GB.

## Proposed history table

```
commcare-a57e4.mobile_metrics.crash_usage_history
```

Same columns as the query output, partitioned by `run_date` and clustered by
`app, error_type`. Long format rather than one wide row per run (as the spreadsheet
does) so new segments or windows are extra rows, not schema changes.

The insert step should be guarded so that a re-run on the same day replaces rather than
duplicates that day's rows - either `DELETE` the `run_date` first, or use `MERGE` on
`(run_date, app, id_basis, user_segment, window_days, error_type)`.
