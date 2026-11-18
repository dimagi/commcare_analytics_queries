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
| `release_health_upgraders.sql` | the same counts for devices that upgraded, before and after their own upgrade, and for devices that stayed on the baseline, before and after the rollout started, plus the crash and ANR device-days again without the known issues (`*_ex_known`) |
| `release_health_issues.sql` | one row per Crashlytics issue seen on the release since the rollout started: devices and events on the release and the baseline, beta events, events on any other version in the export, and the release devices by project and model (`release_scopes`) |
| `release_health_ga4_failures.sql` | one row per day x version x segment x failure category, from release_start on: device-days, attempts and the device-days with one, failures and the device-days with one, for the failures the app reports to GA4 |
| `release_health_versions.sql` | devices per day x version x segment for every version, and distinct devices per version over the last `week_days` days (grain `week`); a NULL `app_version` row counts each device once across all versions. Same device definition as the daily query, with release days before release_start left out |

All five write nothing and compute no rates. Each stands alone as a BigQuery saved query.

`known_issues.toml` is the team's list of issues already judged not to be regressions,
and `known_issues.py` applies it to the issues query's rows (see [Known issues](#known-issues)).

## Inputs

Each file opens with the same `DECLARE` block:

| Variable | Meaning |
|---|---|
| `release_version` | the version rolling out, as GA4 and Crashlytics report it, e.g. `2.65.0` |
| `baseline_version` | the version it replaces. Usually obvious; when it is not (a hotfix over a release still rolling out, two versions with large shares) it is a judgment call, so it is never worked out |
| `release_start` | the day the store rollout started. Required: beta testers report the same version name before it, and no device count reliably tells them apart (2.64.1's betas reached 150 devices a day) |
| `data_lag_days` | how far `end_date` sits behind today. The Crashlytics export lands a day or two late |
| `pre_release_days` | how far before `release_start` the window opens, for the before half of the upgraders check |
| `known_issues_json` | upgraders query only: the known-issues list, as `python known_issues.py --sql-literal` prints it. The file's default is `'[]'`, an empty list, so in the console the `*_ex_known` columns equal the others unless you paste the list in |

The skill's runner rewrites these defaults. In the console, edit them by hand. From a
shell, pipe the file to bq on stdin, because a file opening with `--` reads as a flag:

```
bq query --use_legacy_sql=false --project_id=commcare-a57e4 < release_health_ga4_failures.sql
```

The GA4 failures query reads events only from `release_start` on, and uses
`pre_release_days` only to decide segments the same way as the other files.

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

`crash_device_days_ex_known` and `anr_device_days_ex_known` count the same device-days
again, leaving out the crashes and ANRs of issues in `known_issues.toml` when the event's
project and model fall inside the entry's scope. A device-day whose only crash was a known
one counts as crash-free there. The rates report shows the same-device check both ways.

**New issues** are issues with no events on any version other than the release in the whole
Crashlytics export, about 90 days. Spellings that end in the release version, like
`CommCare2.65.0`, count as the release. Events on the release before `release_start` are
reported as `prerelease_events` (beta) rather than as another version.

**Fresh devices** (`release_devices_fresh`) are the release devices that have no event for
the issue on any other version in the export. A device that hit the issue on 2.64.1 and
again after upgrading brought it with it, so it says nothing about the release. The rates
report's existing-issue hold counts only fresh devices and shows both counts.

**Release scopes** (`release_scopes`) split each issue's release devices by the
Crashlytics `domain` custom key (the CommCare project) and `device.manufacturer` and
`device.model`, each device counted once, under the project and model of its latest
release event for the issue: `devices` and `fresh_devices` per combination. They add up
to `release_devices` and `release_devices_fresh`. The known-issues list reads them.

## Known issues

`known_issues.toml` lists Crashlytics issues that someone looked into during a release
and judged not to be a regression: an old crash under a new name, one project's devices
that upgraded early, a fault on one device model. It lives here so the team shares one
list, and entries carry over from release to release. Each `[[issue]]` holds:

| Field | Required | Meaning |
|---|---|---|
| `issue_id` | yes | the Crashlytics issue id, 32 hex characters (24 for an older issue), as in the console URL and the issues query |
| `title` | yes | a short name for people; nothing matches on it |
| `reason` | yes | why it is not a regression, with the evidence |
| `checked_on` | yes | the day it was last checked, a TOML date (`2026-10-28`, no quotes) |
| `checked_release` | yes | the release it was checked on, e.g. `2.65.0` |
| `error_type` | no | `FATAL`, `ANR` or `NON_FATAL` |
| `projects` | no | the CommCare projects (Crashlytics `domain`) the judgment covers |
| `device_models` | no | the device models it covers, e.g. `SM-X115` or `Tecno BF6` |
| `same_as` | no | the older issue this one is, when Crashlytics filed an old crash under a new name |
| `expected_fix_release` | no | the release expected to fix it |
| `fixing_pr` | no | the pull request that fixes it, which needs `expected_fix_release` |

**Scope.** With neither `projects` nor `device_models`, an entry covers every device.
With both, a device must match both. Matching ignores case, spaces and punctuation, and
a model matches either `device.model` or the manufacturer and model together, so
`Tecno BF6` matches a `TECNO BF6` model and a `BF6` model made by `TECNO`. The `domain`
key carries the server too (`fundacion-plan.commcarehq.org`), so only the part before its
first dot is matched against `projects`. A device whose report carries no `domain` is
outside any entry that lists projects.

**What it does to a report.** `known_issues.py` tags each issues row the list holds:

- **Known**, with its reason, when no release device outside the scope hit the issue
  (`exempt`). The report shows it and does not hold on it.
- **Known, but hit outside its scope** when some did. It reports how many release devices
  outside the scope hit it, and how many of those are fresh, so the hold rules can run on
  those devices alone. A row without `release_scopes`, such as a Crashlytics API issue,
  cannot show this, so a scoped entry there is never exempt.
- **Recheck** (`stale`) when the entry was last checked two or more feature releases ago
  (checked on 2.65.x, flagged from 2.67.0 on; hotfixes do not count). The list as a whole
  reports its stale entries too, shown on the release or not.
- **Still showing on or after its fix release** (`past_expected_fix`) when the issue has
  events on `expected_fix_release` or later.

The same-device check reads the list too. The upgraders query counts crash and ANR
device-days a second time without the listed issues, each event judged by its own project
and model against the entry's scope, so the rates report can show the check with and
without known issues.

```
python known_issues.py --validate
python known_issues.py <issues.json> --release 2.65.0 [--json]
python known_issues.py --sql-literal
```

The first checks the list after an edit. The second takes the issues query's rows as bq
prints them in JSON and prints the tags as a markdown table, or as JSON for a report to
read. The third prints the list as the `known_issues_json` default for the upgraders
query: issue ids and scopes, with the names already normalized. `python -m pytest mobile/release_health` runs the tests.

**Keeping it current.** Add an entry when a release check finds an issue that is not a
regression, with the evidence in `reason`. When you check it again on a later release,
move `checked_on` and `checked_release` and update the reason. When a PR fixing it
merges, set `fixing_pr` and the next planned release as `expected_fix_release`. Remove an
entry once its fix release shows the issue gone.

## GA4 failures

`release_health_ga4_failures.sql` counts the failures CommCare logs to GA4 through
`FirebaseAnalyticsUtil`, on the same versions, days and segments as the daily query. Every
device-day appears under every category, so a category with no events still has its
device-days and a zero. Rates are failures per 1,000 device-days, and failures per attempt
where the app also logs successes.

| Category | GA4 event | Failure when | Attempts |
|---|---|---|---|
| `sync` | `sync_attempt` | `success` = 0 | every event |
| `sync_non_network` | `sync_attempt` | `success` = 0 and `reason` is not `no_connection`, `unreachable_host`, `connection_timeout`, `captive_portal` or `cancelled` | every event |
| `form_upload` | `form_upload_attempt` | `result` is not `FULL_SUCCESS` | every event |
| `form_upload_non_network` | `form_upload_attempt` | `result` is not `FULL_SUCCESS`, `TRANSPORT_FAILURE` or `CAPTIVE_PORTAL` | every event |
| `form_quarantine` | `form_quarantine_event` | `item_id` is not `manual-quarantine` | none |
| `corrupt_app_state` | `common_commcare_event` | `item_id` = `corrupt_app_state` | none |
| `update_stage_failure` | `common_commcare_event` | `item_id` = `stage_update_failure` | none |
| `update_reset` | `common_commcare_event` | `item_id` = `update_reset` | none |
| `in_app_update` | `in_app_update_event` | `value` = 0 | every event |
| `personalid_config_failure` | `personal_id_configuration_failure` | every event | none |
| `otp_request` | `otp_requested`, `event_type` `request` or `request_email`, Firebase handoffs left out | `outcome` = `failure` | every event but a handoff |
| `otp_request_firebase` | the same, `method` = `firebase` | `outcome` = `failure` | every event but a handoff |
| `otp_request_personalid` | the same, `method` = `personal_id` | `outcome` = `failure` | every event |
| `otp_request_email` | the same, `method` = `email` | `outcome` = `failure` | every event |
| `otp_request_firebase_handoff` | `otp_requested`, `event_type` `request`, `method` = `firebase` | a failure handed off to PersonalID SMS | every event |
| `otp_verify` | `otp_requested`, `event_type` `verify` or `verify_email` | `outcome` = `failure` | every event |
| `personalid_recovery` | `personalid_account_recovered` | `value` = 0 | every event |
| `connect_api_jobs` | `ccc_api_jobs` | `ccc_api_success` = 0 | every event |
| `connect_api_start_learning` | `ccc_api_start_learning` | `ccc_api_success` = 0 | every event |
| `connect_api_claim_job` | `ccc_api_claim_job` | `ccc_api_success` = 0 | every event |
| `connect_api_payment_confirmation` | `ccc_api_payment_confirmation` | `ccc_api_success` = 0 | every event |
| `connect_api_learn_progress` | `ccc_api_learn_progress` | `ccc_api_success` = 0 | none |
| `connect_api_delivery_progress` | `ccc_api_delivery_progress` | `ccc_api_success` = 0 | none |

Some things to know when reading them:

- **The denominator is the device-days GA4 saw**, not the GA4-or-Crashlytics union in
  `release_health_daily.sql`. Only GA4 sends these events.
- **Categories with no attempts** log only failures, or log successes unevenly. The app
  logs a learn progress success only once the assessment is passed, and a delivery
  progress success once per milestone, so their successes mean nothing.
- **One form upload event covers a whole batch** of forms and carries its worst result.
  A batch with nothing to send logs `FULL_SUCCESS`.
- **The `no_connection` sync failure is logged without trying**, when the user presses
  sync with no network. `sync_non_network` leaves out that and the other network
  reasons, so it moves with the release rather than with the user's signal.
- **OTP verify failures include wrong codes typed by the user.** Compare the rate, not
  the count.
- **A failed Firebase phone request hands off to PersonalID SMS**, which logs a request
  of its own straight away. A Firebase failure followed within `handoff_seconds` by a
  PersonalID request is that handoff, as in `personalid/otp/otp_failure_breakdown.sql`.
  `otp_request` and the method rows leave it out, so each request counts once by the
  outcome the user saw and the three method rows add up to `otp_request`. Counting it
  took 2.64.1's request failure rate from 34% to 44% the week of 2026-10-13.
- **Connect and PersonalID categories are near zero for `non-connect`** by construction.

The parameter keys come from `CCAnalyticsEvent`, `CCAnalyticsParam` and
`AnalyticsParamValue` in `commcare-android`'s `org.commcare.google.services.analytics`.
When the app changes an event, change the table and the query together.

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
Crashlytics export, but only a few columns: its final query read about 2.4 GB on 2026-11-02,
under two cents, of which the project and model columns for `release_scopes` add about 0.1 GB.

The GA4 failures query is the exception. It reads the raw GA4 export, about 4 GB a day
from `release_start` on: an upper bound of 37 GB a week into a rollout and 58 GB after two,
or roughly $0.20 to $0.35 a run. It never reads `user_properties`, which would triple
that, by taking each app instance's device_id from `mobile_metrics.ga_device_day`.

A dry run of any of these files as a script does not price the final query: all four
report the same 38,547,416 bytes. Those GA4 figures come from dry runs of the final query
with the variables written in as literals.
