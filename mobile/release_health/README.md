# CommCare release health

Queries for watching a CommCare release during its staged Play Store rollout. They
compare the new release with the version it replaces, and are run by the
`release-watch` Claude skill before each rollout step, which turns their counts into
rates, intervals and a Go / Hold / Halt verdict.

The `crash_metrics` queries answer "how healthy is the fleet over 30 or 90 days". These
answer a narrower question: "is the new release worse than the old one, on the same days
and on the same devices". A 30 day window cannot answer that for a version that is three
days old, which is why this is separate.

## Files

| File | What it returns |
|---|---|
| `release_health_daily.sql` | one row per day x version (release or baseline) x segment: device-days and the device-days, events and so on for crashes, ANRs and non-fatals |
| `release_health_upgraders.sql` | the same counts for devices that upgraded, before and after their own upgrade, and for devices that stayed on the baseline, before and after the rollout started |
| `release_health_issues.sql` | one row per Crashlytics issue seen on the release since the rollout started: devices and events on the release and the baseline, beta events, and events on any other version in the export |

All three write nothing and compute no rates. Each stands alone as a BigQuery saved query.

## Inputs

Each file opens with the same `DECLARE` block:

| Variable | Meaning |
|---|---|
| `release_version` | the version rolling out, as GA4 and Crashlytics report it, e.g. `2.65.0` |
| `baseline_version` | the version it replaces. Usually obvious; when it is not (a hotfix over a release still rolling out, two versions with large shares) it is a judgment call, so it is never worked out |
| `release_start` | the day the store rollout started. Required: beta testers report the same version name before it, and no device count reliably tells them apart (2.64.1's betas reached 150 devices a day) |
| `data_lag_days` | how far `end_date` sits behind today. The Crashlytics export lands a day or two late |
| `pre_release_days` | how far before `release_start` the window opens, for the before half of the upgraders check |

The skill's runner rewrites these defaults. In the console, edit them by hand.

`end_date` is also capped at the last day `mobile_metrics.ga_device_day` holds, and every
file asserts that at least one complete day exists after `release_start`. On the first day
of a rollout that assert fails, by design.

## Definitions

**A device-day** is one device running one version on one day. A device counts as active
if GA4 saw it **or** it sent any Crashlytics report that day. Taking the union keeps
devices that crash before GA4 uploads anything, which is the failure a broken release is
most likely to cause. `crash_only_device_days` counts the device-days GA4 never saw.

Devices are keyed by the `device_id` custom key, as in `crash_metrics`, falling back to
the Crashlytics `installation_uuid` when a report carries no `device_id`.

**Segments** are worked out once per device across the whole window and every version, so
an upgrade cannot move a device between segments: `connect`, `connect-demo` (Dimagi test
handsets, from the same `personalid_config_sessions` rule as `crash_metrics`),
`non-connect`, and `unmatched` for crashing devices GA4 never saw at all.

**The upgraders check** compares each device with itself. `upgraded` devices ran the
baseline and then the release; their before days are baseline days before their own first
release day. `stayed` devices ran the baseline throughout; their before and after split at
`release_start`. Only devices with days in both periods count. Dividing the upgraded
ratio by the stayed ratio cancels whatever changed for everyone over those weeks.

**New issues** are issues with no events on any version other than the release in the whole
Crashlytics export, about 90 days. Spellings that end in the release version, like
`CommCare2.65.0`, count as the release. Events on the release before `release_start` are
reported as `prerelease_events` (beta) rather than as another version.

## Reading the numbers

**The same-day comparison and the same-device check can disagree, and the second is the
one to trust.** During a staged rollout the release runs on early adopters: auto-updaters,
newer phones, people on Wi-Fi. Tested on 2.64.1 against 2.64.0 over its first three days,
the same-day crash ratio was 1.26x (interval 1.07-1.49), while the same-device check,
adjusted for devices that stayed, was 1.04x (0.80-1.36). The gap was the population, not
the release.

**Intervals are too narrow.** They treat device-days as independent, and one device
appears on many days. A ratio just clearing 1 at the low end of its interval is a reason
to look, not proof.

**Data is thin early.** 2.64.1 carries about 31k devices on a weekday, with about 0.65%
of device-days having a crash and 2.8% an ANR. At a 5% rollout only a large regression
shows within a few days. The skill reports the smallest increase each comparison could
detect.

## Cost

About 38 MB per file per run, so effectively free. The issues query reads every day in the
Crashlytics export, but only a few columns.
