# CommCare crash & usage metrics

Numbers behind the crash-free and ANR-free user metrics that are currently kept by
hand in the **CommCare Mobile Metrics** spreadsheet (scraped from the Firebase
Crashlytics console), broken down by Connect and non-Connect users.

## Files

| File | What it is |
|---|---|
| `crash_usage_metrics.sql` | measurement only - emits the numbers, writes nothing. Use it to eyeball a window or compare against the console. |
| `crash_usage_totals.sql` | helper: the pre-version view, one row per app x segment x window x event type. |
| `ga_device_day_table.sql` | DDL for the GA4 daily rollup. Safe to re-run. |
| `ga_device_day_insert.sql` | refreshes the rollup. **Must run before the metrics insert.** |
| `crash_usage_history_table.sql` | DDL for the history table. Safe to re-run: `CREATE TABLE IF NOT EXISTS`. |
| `crash_usage_history_insert.sql` | the metrics insert on its own. Source for the scheduled file; also fine to run by hand. |
| `crash_usage_scheduled.sql` | **the one query to schedule.** Rollup refresh then metrics insert, generated. |

### Generated files

Each file has to stand alone as a BigQuery saved query, so the shared bodies are copied
rather than referenced. There is a chain, and only the first link is hand-edited:

```
crash_usage_metrics.sql  ->  crash_usage_history_insert.sql  ->  crash_usage_scheduled.sql
ga_device_day_insert.sql ---------------------------------------^
```

- `crash_usage_history_insert.sql` is the measurement query with the ORDER BY dropped,
  `inserted_at` added, and the whole thing wrapped in the ASSERT, DELETE and INSERT.
- `crash_usage_scheduled.sql` is `ga_device_day_insert.sql` followed by
  `crash_usage_history_insert.sql`, with their DECLARE blocks merged and de-duplicated
  so both halves share one `data_lag_days` and their windows cannot drift apart.

**Edit `crash_usage_metrics.sql` or `ga_device_day_insert.sql`, then regenerate the
other two.** Editing a generated file directly will be silently undone by the next
regeneration.

## Output

One row per app x id basis x segment x window x event type.

| Column | Meaning |
|---|---|
| `run_date` | date the query ran |
| `app` | `commcare` (`org.commcare.dalvik`) or `lts` (`org.commcare.lts`) |
| `user_segment` | `all-by-device`, `all-by-installation`, `connect`, `connect-demo` or `non-connect` |
| `window_days` | 30 or 90 |
| `error_type` | `FATAL` (a crash) or `ANR` |
| `window_start` / `window_end` | inclusive window bounds |
| `total_events` | total crashes / ANRs |
| `affected_users` | unique crashing / ANR-ing users |
| `total_users` | unique active users over the window |
| `unmatched_affected_users` | of `affected_users`, how many had no GA4 match; NULL for `all-by-installation` |
| `free_users_pct` | `100 * (1 - affected_users / total_users)` |
| `days_covered` | days of Crashlytics history actually present in the window |

`data_lag_days` (default 2) holds the window back from today. The Crashlytics export
lands a day or two late, and including a partial day badly understates the counts.

### The two ways of counting a user

Crashlytics and GA4 do not share a user id, so there are two ways to count one and both
are reported. The `user_segment` value says which is in play.

`all-by-installation` reproduces the original console-comparable measure: Crashlytics
`installation_uuid` over GA4 `user_pseudo_id`. It cannot be broken down, and it is the
only row available for LTS.

`all-by-device` and the three breakdown segments use the `device_id` custom key for both
numerator and denominator. That is what supports the Connect split, and it is internally
consistent - `connect + connect-demo + non-connect` sums exactly to `all-by-device` on
events, affected users and total users. It counts fewer users (158k vs 193k over 30
days, since not every app instance reports a `device_id`), so its percentages sit a
little lower.

The two `all` rows are therefore alternative totals, not parts of one whole - never add
them together, and never chart one against the other.

### Segments

Assigned per device per window from the GA4 `ccc_enabled` user property:

- `connect` - `ccc_enabled` set on any event in the window
- `connect-demo` - a Connect device whose latest `personalid_config_sessions` entry has
  a phone number starting `+7426` or listed in `dimagi_phones`
- `non-connect` - everything else, including devices with no GA4 match

`ccc_enabled` turns on when a user configures their Connect account and stays on, so
"ever set" is the right test: a device that reports it at any point in the window was a
Connect user throughout. Devices whose crashes carry a `device_id` that matches no GA4
device count as non-Connect, on the basis that a Connect user gets far enough through
setup to be reporting one.

Demo devices are split out because they are Dimagi test and demo handsets, not field
users, and they behave nothing like them - see below. Devices are matched to
`personalid_config_sessions` on `device_id`, which is already stored there in the
`commcare_<uuid>` form the Crashlytics key uses, so no rewriting is needed. Only the
most recent session per device counts, and `dimagi_phones` repeats a few numbers, so
that lookup is a semi-join to avoid fanning rows out. A Connect device with no config
session at all stays `connect`.

Demo status is taken from the latest session as of the run, not as of `window_end`.
Rows already written are snapshots and never change, but a device can be reclassified
between runs if a newer session appears.

The unmatched-device rule is not symmetric, which is what `unmatched_affected_users` records.
Unmatched devices are absent from GA4 entirely, so they add to the `non-connect`
numerator but nothing to its denominator - there is no way to know how many *non
crashing* unmatched devices exist. The effect is to push `non-connect` (and `all-by-device`)
`free_users_pct` down by roughly 0.4pp. Small, but it is a floor on how precise these
percentages can be, and it is worth watching if the unmatched share ever grows.

## The GA4 rollup

`mobile_metrics.ga_device_day` is a daily rollup of the GA4 export for
`org.commcare.dalvik`: one row per day x app instance x device x version, carrying
`is_connect`. The metrics queries read it instead of the raw export.

It exists for cost. Reading `user_properties` across 90 days of GA4 was 0.40 TiB on
every run, and 89 of those 90 days had not changed since the previous run. The rollup
reads each day once. It also outlives the exports, which is the other half of the
problem the history table was built for - GA4 shards are dropped at 180 days by
`daily_expired_cleanup.sql`, Crashlytics at 92.

`ga_device_day_insert.sql` is incremental and self-healing: it reprocesses the last
`refresh_days` (3) in case events landed late, fills whatever gap a missed run left, and
backfills the full 90 days into an empty table. It is idempotent - the delete and the
insert share one transaction - so re-running it is always safe.

**Run it before the metrics insert.** `crash_usage_history_insert.sql` opens with an
`ASSERT` that the rollup reaches `window_end` and fails with
`ga_device_day rollup is behind window_end` rather than writing history off stale data.

The rollup is about 0.35 GB for 90 days, roughly 1.4 GB a year, so storage is around a
cent a month.

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

**Connect is a small base, and `connect-demo` is a very small one.** Roughly 2,900
Connect and 600 demo devices over 30 days, against ~155k non-Connect. Connect
percentages move on much smaller counts and will be noisier month to month; demo ones
are built on so few crash events that individual months mean little. `days_covered` is
also close to meaningless for `connect-demo` - with a handful of events it just records
when the first one happened, not how much history the window holds.

Splitting demo devices out matters more than their count suggests: they were pulling
the Connect figures up noticeably. Over 30 days, ANR-free for `connect` drops from
83.2% to 79.7% once they are removed.

**The `all-by-installation` percentage will not match the Firebase console exactly.**
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

Measured at the on-demand rate of $6.25/TiB, with no reservation on the project.

| | per run | per year |
|---|---|---|
| before the rollup, weekly | 0.40 TiB, $2.52 | $131 |
| before the rollup, daily | 0.40 TiB, $2.52 | $920 |
| rollup + metrics, weekly | 64 GiB, $0.39 | $20 |
| rollup + metrics, daily | 32 GiB, $0.20 | $73 |

Measured on a real combined run: rollup insert 26.34 GiB, ASSERT 0.03 GiB, metrics
insert 1.35 GiB.

The metrics query itself is now 1.4 GiB ($0.01); essentially all of the remaining cost is
the rollup refresh reading new GA4 day-shards at about 5.3 GiB each.

Two things worth knowing if the numbers are ever retuned. A weekly rollup is cheaper than
a daily one, because each run pays a fixed overlap - `refresh_days` plus a day of
`_TABLE_SUFFIX` slack either side - and running seven times a week pays it seven times.
And earlier versions of this file quoted $5/TB, which is not the rate; $6.25/TiB is, so
the pre-rollup figures were understated by about 25%. Fine monthly;
worth knowing before putting it on a faster schedule. Dropping the Connect breakdown
would take it back to ~65 GB.

## History table

```
commcare-a57e4.mobile_metrics.crash_usage_history
```

Created in the `US` region to match the Crashlytics and GA4 exports - not in
`firebase_crashlytics`, whose dataset defaults would have given a new table a 60 day
table and partition expiration and quietly deleted it, and not in `analytics_153906101`,
where `daily_expired_cleanup.sql` programmatically drops tables. Same columns as
the query output plus `inserted_at`, partitioned by `run_date` and clustered by
`app, app_version, error_type, user_segment`. Long format rather than one wide row per run (as the spreadsheet
does) so new segments or windows are extra rows, not schema changes.

Row count per run is roughly 24 x (number of versions seen + 1) - 537 on the first
versioned run. The uniqueness key is
`(run_date, app, app_version, user_segment, window_days, error_type)`.

`crash_usage_history_insert.sql` wraps the delete and the insert in one transaction and
clears `run_date = CURRENT_DATE()` first, so running it twice in a day replaces that
day's rows instead of duplicating them. Verified against a scratch copy: a second run
leaves one set of rows, not two.

First run inserted `2026-09-21`.

### Scheduling

Schedule `crash_usage_scheduled.sql`, daily. It is one query, so there is no second job
to keep in step and no window in which the metrics could run off a stale rollup.

Daily is not the cheapest cadence - every run pays a fixed overlap of `refresh_days`
plus a day of `_TABLE_SUFFIX` slack either side, so daily costs about $73 a year against
$20 weekly. It is worth it for release monitoring: on a weekly cadence a bad release can
be live for six days before it appears in a row.

The window is anchored on the run date, not on calendar boundaries. Each row records its
own `window_start` / `window_end`, so a missed or irregular run shifts the window rather
than corrupting the series, and the rollup refresh backfills whatever gap it left.
