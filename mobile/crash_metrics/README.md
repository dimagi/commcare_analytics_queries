# CommCare crash & usage metrics

Numbers behind the crash-free and ANR-free user metrics that are currently kept by
hand in the **CommCare Mobile Metrics** spreadsheet (scraped from the Firebase
Crashlytics console), broken down by Connect and non-Connect users.

## Files

| File | What it is |
|---|---|
| `crash_usage_metrics.sql` | measurement only - emits the numbers, writes nothing. Use it to eyeball a window or compare against the console. |
| `crash_usage_history_table.sql` | DDL for the history table. Safe to re-run: `CREATE TABLE IF NOT EXISTS`. |
| `crash_usage_history_insert.sql` | the scheduled query - same body, wrapped in a guarded insert. |

The two query files share a body that is duplicated rather than shared, because each
one has to stand alone as a BigQuery saved query. **Changes to the measurement query
need copying into the insert query**, and the insert is the one that matters.

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

~444 GB per run, nearly all of it reading GA4 `user_properties` over 90 days for the
`device_id` and `ccc_enabled` lookups. Roughly $2.20 at on-demand pricing. Adding the
version breakdown cost about 3% more, since `app_info.version` is a small column. Fine monthly;
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

Not scheduled yet. Monthly fits both the intended use and the cost. Note that the
window is anchored on the run date, not on calendar month boundaries - each row records
its own `window_start` / `window_end`, so an irregular run just shifts the window rather
than corrupting the series.
