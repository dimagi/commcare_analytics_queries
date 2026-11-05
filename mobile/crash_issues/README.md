# CommCare crash issues

Queries that answer "which crashes matter most in the field right now?" The
`crash_metrics` queries give crash-free rates and `release_health` compares two versions,
but neither says which issues are behind the numbers.

## Files

| File | Takes | What it returns |
|---|---|---|
| `top_issues.sql` | `end_date`, `days`, `top_n` | the `top_n` FATAL and the `top_n` ANR issues of the last `days` days up to `end_date`, ranked by devices affected, once over all devices and once over Connect devices, with counts per segment, per 1,000 active devices, the issue's top project, phone model, Android version and app version, and the rising, new and concentrated flags |

It writes nothing and needs no new table. NON_FATAL issues are left out; LTS is not
covered yet.

## Inputs

These take BigQuery named parameters, like `investigate_user`, so a dry run prices the
real query:

```
bq --project_id=commcare-a57e4 query --use_legacy_sql=false \
  --parameter=end_date:DATE:2026-11-02 \
  --parameter=days:INT64:7 \
  --parameter=top_n:INT64:20 \
  < top_issues.sql
```

Pipe the file on stdin, because a file opening with `--` reads as a flag. In the console,
write the values in for the `@` parameters by hand.

`end_date` is the last day counted, inclusive. Pick a day at least two days back: the
Crashlytics export lands a day or two late, and `mobile_metrics.ga_device_day` has to hold
the window too, as `crash_metrics` needs it to. Seven days is the usual window.

## Output

One row per ranking x error type x issue, `top_n` rows at most for each ranking and error
type.

| Column | Meaning |
|---|---|
| `ranking` | `all`, ranked by `devices`, or `connect`, ranked by `connect_devices` over the issues that reached a Connect device |
| `issue_rank` | 1 for the issue on the most devices. Ties go to more events, then to `issue_id` |
| `issue_id`, `error_type`, `issue_title` | the Crashlytics issue. `error_type` is `FATAL` (a crash) or `ANR` |
| `devices`, `events`, `installations` | distinct devices, events and Crashlytics installations over the window. Both run higher than the console's user count, up to 2.7x (see Checking it) |
| `connect_devices`, `connect_demo_devices`, `non_connect_devices` | `devices` by segment. They add up to `devices` |
| `unmatched_devices` | of `non_connect_devices`, those GA4 never saw over the window |
| `connect_events` | events on Connect devices, the tie-break for the Connect ranking |
| `domains` | distinct projects the issue was seen in |
| `days_with_events`, `last_event_date` | over the window |
| `prior_devices`, `prior_events` | the same counts over the `days` days before the window |
| `first_seen_date` | the issue's first event anywhere in the export, about 90 days |
| `top_domain`, `top_device_model`, `top_os_version`, `top_app_version` | the value with the most devices among the issue's devices, each with a `_devices` count |
| `devices_per_1000`, `connect_devices_per_1000`, `non_connect_devices_per_1000` | devices with the issue per 1,000 active devices in that segment |
| `active_devices`, `connect_active_devices`, `non_connect_active_devices` | the denominators: devices GA4 saw over the window |
| `is_new`, `is_rising`, `is_concentrated` | the flags below |
| `window_start`, `end_date` | the window, inclusive |

## Definitions

**Devices, not events.** One device stuck in a crash loop can send hundreds of events, so
issues are ranked by distinct devices. Devices are keyed by the `device_id` custom key,
falling back to the Crashlytics `installation_uuid`, as in `crash_metrics` and
`release_health`.

**Segments** follow `crash_metrics`: a device is `connect` if GA4 saw `ccc_enabled` on it at
any point in the window, `connect-demo` if it is a Connect device whose latest
`personalid_config_sessions` entry is a Dimagi test number, and `non-connect` otherwise,
including crashing devices GA4 never saw. Those unmatched devices add to the
`non-connect` numerator but not its denominator, so `non_connect_devices_per_1000` reads a
little high; `unmatched_devices` says by how much.

**Connect is ranked on its own** because about 2,900 Connect devices sit against about
155,000 others, so a Connect issue rarely reaches the overall top. The `all` ranking
counts every device, demo devices included, as the console does; the `connect` ranking
leaves demo devices out.

**The project** is the Crashlytics `domain` custom key, which `CrashUtil.registerAppData()`
sets along with `app_version` and `app_name`. A report from before an app is installed
carries none.

**The flags** are flags, not a score, and their thresholds are a first guess:

- `is_new`: the issue's first event in the whole export falls inside the window.
- `is_rising`: at least 5 devices, and at least twice as many as in the `days` days
  before.
- `is_concentrated`: at least 5 devices, and one project or one phone model has more than
  half of them.

## What it does not return

No user data: no user ids, device ids, exception messages, log lines or the issue
subtitle, which can carry an exception message. Look an issue up in the Crashlytics
console by `issue_id` for its stack and events.

## Cost

About 520 MB for a 7 day window, and 1.4 GB for 30 days: the window and the one before
it, plus `issue_id`, `error_type` and `event_timestamp` for the whole export, to find
`first_seen_date`.

`first_seen` reads the export through the wildcard `org_commcare_dalvik_ANDROID*` (only
that table matches). Named directly, BigQuery merges it with the window's read of the same
table, and reads `custom_keys` for all 90 days: 1.76 GB instead of 520 MB.

## Checking it

Checked on 2026-11-05 against the Crashlytics API's top issues for 2026-10-28 to 11-03,
CommCare app, all versions, crashes only. Events match the console: two of the top five
exactly, the other three within 7%. Devices and installations do not: they run 1.1x to
2.7x above the console's users (ExtUtil.readString: 80 installations, 30 users), and
distinct `user.id` in the export is close to installations too, so that isn't the cause.
Until the gap is explained, read `devices` as a ranking, not as the console's user count.
