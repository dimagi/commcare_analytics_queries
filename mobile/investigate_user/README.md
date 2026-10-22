# Investigate one user

Queries behind the `investigate-user` Claude skill (v1, BigQuery only). They link a
device to the PersonalID user on it, then gather that user's GA4 activity and the
Crashlytics issues on their devices, as counts and flags the skill turns into a report.

The link is GA4. Every event CommCare logs carries two user properties set by
`FirebaseAnalyticsUtil.setUserProperties`:

- `user_cid`, the PersonalID user id, set only while a PersonalID user is logged in
- `device_id`, the CommCare device id without its `commcare_` prefix (the app keeps the
  last 36 characters, which is the uuid)

Crashlytics carries the full `commcare_<uuid>` as its `device_id` custom key, so a device
found in GA4 finds its crashes.

## Files

| File | Takes | What it returns |
|---|---|---|
| `device_users.sql` | `device_id`, `start_date`, `end_date` | one row per `user_cid` seen on the device, plus a row with a NULL `user_cid` for events logged with nobody logged in to PersonalID: first and last day seen, active days, events, app instances, app ids and versions, whether `ccc_enabled` or the demo user flag was ever set, and how many users the device had |
| `user_devices.sql` | `user_cid`, `start_date`, `end_date` | one row per device the user was seen on: the same counts for the user's own events, how many other PersonalID users used the device (`is_shared_device`), events with nobody logged in, and whether the device was still used after the user's last day on it |
| `user_activity.sql` | `user_cid`, `start_date`, `end_date` | one row per day x device x version x category for the user's own events: `events`, and `attempts` and `failures` where the category has them |
| `user_crashes.sql` | `device_ids`, `user_cid`, `start_date`, `end_date` | one row per Crashlytics issue and error type on those devices: events, devices, days with events, first and last day, versions, and how many events carried the user's id or someone else's as the Crashlytics user id |

The usual order is `device_users` (or start from a known `user_cid`), then
`user_devices`, then `user_activity` and `user_crashes` with the device ids
`user_devices` returned. `user_crashes` takes the device ids rather than looking them up
again, because the lookup is the expensive part.

## Inputs

Unlike the other folders, these take BigQuery named parameters instead of a `DECLARE`
block. The ids come from whoever asks, so they are passed as values and never pasted into
the SQL, and a dry run prices the real query (a dry run of a script does not).

```
bq --project_id=commcare-a57e4 query --use_legacy_sql=false \
  --parameter=user_cid::<id> \
  --parameter=start_date:DATE:2026-09-21 \
  --parameter=end_date:DATE:2026-10-20 \
  < user_devices.sql

bq ... --parameter='device_ids:ARRAY<STRING>:["commcare_<uuid>"]' ... < user_crashes.sql
```

A device id may be given with or without its `commcare_` prefix. In the console, write
the values in for the `@` parameters by hand.

Days are GA4 export days, read from the table suffix. Device clocks put some event
timestamps in the future, so the queries never filter or group on `event_timestamp`.
Crashlytics days come from its `event_timestamp`, as in the other folders.

## Categories in `user_activity.sql`

`all_events`, `session_start`, `screen_view`, `first_open`, `app_update` and
`app_exception` count events. `app_exception` also counts every event as a failure. The
rest are the failure categories of `mobile/release_health/release_health_ga4_failures.sql`,
with the same rules; its README explains them. Keep the two lists in step when the app
changes an event.

## What these cannot tell

- **Activity before login, and after logout, has no `user_cid`.** Those events count only
  as `logged_out_events` in `user_devices.sql` and in the NULL row of `device_users.sql`.
- **A crash cannot be pinned on one user of a shared device.** `user_crashes.sql` joins by
  device. On a device where `is_shared_device` is true, some of its crashes may be another
  user's. The Crashlytics user id is the CommCare username while one is logged in, and the
  PersonalID id otherwise, so `events_user_id_is_user` only confirms some of them.
- **GA4 keeps 180 days**, and Crashlytics about 90.
- **No PHI comes back.** The output holds ids, counts and flags, never names, phone
  numbers, the Crashlytics user id itself, or the issue subtitle, which can carry an
  exception message. Look up the subtitle in the Crashlytics console by `issue_id` when it
  is needed.

## Cost

The GA4 queries read `user_properties`, the most expensive column of the export, for every
day in the window, whichever user is asked about: the export is not clustered, so a filter
on one user saves nothing. Keep the window as short as the question allows.
`user_crashes.sql` reads only a few Crashlytics columns.
