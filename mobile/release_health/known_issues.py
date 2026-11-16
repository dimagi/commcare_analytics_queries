"""Apply the release-watch known-issues list to the rows of release_health_issues.sql.

    python known_issues.py <issues.json> --release 2.65.0 [--list known_issues.toml] [--json]
    python known_issues.py --validate [--list known_issues.toml]

The rows are the JSON array bq prints for the issues query. Exits 1 when the list is invalid.
"""
import argparse
import json
import re
import sys
import tomllib
from datetime import date
from pathlib import Path

DEFAULT_LIST = Path(__file__).with_name("known_issues.toml")
STALE_AFTER_RELEASES = 2
ISSUE_ID_RE = re.compile(r"^(?:[0-9a-f]{24}|[0-9a-f]{32})$")
VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+)*$")
PR_RE = re.compile(r"^https://github\.com/[\w.-]+/[\w.-]+/pull/[0-9]+$")
ERROR_TYPES = ("FATAL", "ANR", "NON_FATAL")
REQUIRED = ("issue_id", "title", "reason", "checked_on", "checked_release")
OPTIONAL = ("error_type", "projects", "device_models", "same_as", "expected_fix_release", "fixing_pr")


class ListError(ValueError):
    """The known-issues list breaks one of its rules."""


def version_key(v):
    """A version as a tuple of ints, so 2.65.10 sorts after 2.65.9."""
    if not isinstance(v, str) or not VERSION_RE.fullmatch(v):
        raise ListError("not a version like 2.65.0: %r" % (v,))
    return tuple(int(p) for p in v.split("."))


def releases_between(older, newer):
    """How many feature releases (2.64 to 2.66 is two) separate two versions; hotfixes count as none."""
    o, n = version_key(older), version_key(newer)
    o_line, n_line = (o + (0,))[:2], (n + (0,))[:2]
    if o_line[0] != n_line[0]:
        return STALE_AFTER_RELEASES if n_line > o_line else 0
    return n_line[1] - o_line[1]


def normalize(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def _check_entry(n, e):
    where = "entry %d (%s)" % (n, e.get("issue_id", "no issue_id"))
    unknown = set(e) - set(REQUIRED) - set(OPTIONAL)
    if unknown:
        raise ListError("%s: unknown field(s) %s" % (where, ", ".join(sorted(unknown))))
    for f in REQUIRED:
        if e.get(f) in (None, ""):
            raise ListError("%s: missing %s" % (where, f))
    if not ISSUE_ID_RE.fullmatch(e["issue_id"]):
        raise ListError("%s: issue_id must be 32 lowercase hex characters, or 24 for an older issue" % where)
    if not isinstance(e["checked_on"], date):
        raise ListError("%s: checked_on must be a TOML date, like 2026-10-28" % where)
    if e.get("error_type") is not None and e["error_type"] not in ERROR_TYPES:
        raise ListError("%s: error_type must be one of %s" % (where, ", ".join(ERROR_TYPES)))
    for f in ("projects", "device_models"):
        v = e.get(f, [])
        if not isinstance(v, list) or not all(isinstance(x, str) and x.strip() for x in v):
            raise ListError("%s: %s must be a list of names" % (where, f))
    for f in ("checked_release", "expected_fix_release"):
        if e.get(f) is not None:
            try:
                version_key(e[f])
            except ListError as err:
                raise ListError("%s: %s is %s" % (where, f, err))
    if e.get("fixing_pr") is not None:
        if not PR_RE.fullmatch(e["fixing_pr"]):
            raise ListError("%s: fixing_pr must be a GitHub pull request URL" % where)
        if e.get("expected_fix_release") is None:
            raise ListError("%s: a fixing_pr needs its expected_fix_release" % where)


def load(path=DEFAULT_LIST):
    """The list as {issue_id: entry}, raising ListError when an entry breaks a rule."""
    try:
        data = tomllib.loads(Path(path).read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as e:
        raise ListError("%s is not valid TOML: %s" % (path, e))
    unknown = set(data) - {"issue"}
    if unknown:
        raise ListError("unknown top-level key(s): %s" % ", ".join(sorted(unknown)))
    entries = {}
    for n, e in enumerate(data.get("issue", []), 1):
        _check_entry(n, e)
        if e["issue_id"] in entries:
            raise ListError("entry %d: issue %s is listed twice" % (n, e["issue_id"]))
        entries[e["issue_id"]] = e
    return entries


def scoped(entry):
    return bool(entry.get("projects") or entry.get("device_models"))


def in_scope(entry, domain, model, manufacturer=None):
    """Whether one release device falls under the entry: in a listed project and of a listed model, where given."""
    projects = {normalize(p) for p in entry.get("projects", [])}
    if projects and normalize(domain) not in projects:
        return False
    models = {normalize(m) for m in entry.get("device_models", [])}
    if models and not models & {normalize(model), normalize((manufacturer or "") + (model or ""))}:
        return False
    return True


def out_of_scope(entry, row):
    """(devices, fresh devices) on the release outside the entry's scope, or (None, None) when the row has no breakdown."""
    if not scoped(entry):
        return 0, 0
    scopes = row.get("release_scopes")
    if scopes is None:
        return None, None
    devices = fresh = 0
    for s in scopes:
        if not in_scope(entry, s.get("domain"), s.get("device_model"), s.get("device_manufacturer")):
            devices += int(s["devices"])
            fresh += int(s["fresh_devices"])
    return devices, fresh


def flags(entry, release_version):
    """The recheck flags an entry carries on a release, whether or not the issue shows on it."""
    since = releases_between(entry["checked_release"], release_version)
    fix = entry.get("expected_fix_release")
    return {
        "releases_since_check": since,
        "stale": since >= STALE_AFTER_RELEASES,
        "past_expected_fix": fix is not None and version_key(release_version) >= version_key(fix),
    }


def tag(rows, entries, release_version):
    """One tag per issues row the list holds, in row order.

    `exempt` is True when no release device outside the entry's scope hit the issue: the
    report then shows it as Known and does not hold on it. A row without
    release_scopes cannot show that for a scoped entry, so it is never exempt.
    """
    tags = []
    for row in rows:
        entry = entries.get(row.get("issue_id") or row.get("id"))
        if entry is None:
            continue
        devices, fresh = out_of_scope(entry, row)
        t = {
            "issue_id": entry["issue_id"],
            "title": entry["title"],
            "reason": entry["reason"],
            "scope": scope_text(entry),
            "checked_on": entry["checked_on"].isoformat(),
            "checked_release": entry["checked_release"],
            "expected_fix_release": entry.get("expected_fix_release"),
            "fixing_pr": entry.get("fixing_pr"),
            "same_as": entry.get("same_as"),
            "out_of_scope_devices": devices,
            "out_of_scope_fresh_devices": fresh,
            "exempt": devices == 0,
        }
        t.update(flags(entry, release_version))
        t["past_expected_fix"] = t["past_expected_fix"] and int(row.get("release_events", 1)) > 0
        tags.append(t)
    return tags


def stale_entries(entries, release_version):
    """Entries due for a recheck on this release, shown on the release or not."""
    return [e for e in entries.values() if flags(e, release_version)["stale"]]


def scope_text(entry):
    parts = []
    if entry.get("projects"):
        parts.append("projects " + ", ".join(entry["projects"]))
    if entry.get("device_models"):
        parts.append("models " + ", ".join(entry["device_models"]))
    return "; ".join(parts) or "any device"


def render(tags, stale, release_version):
    out = ["## Known issues on %s" % release_version, ""]
    if tags:
        out.append("| Issue | Scope | Outside scope (fresh) | Status | Reason |")
        out.append("|---|---|---|---|---|")
        for t in tags:
            if t["out_of_scope_devices"] is None:
                outside = "unknown"
                status = ["Known, scope not checked"]
            else:
                outside = "%d (%d)" % (t["out_of_scope_devices"], t["out_of_scope_fresh_devices"])
                status = ["Known" if t["exempt"] else "Known, but hit outside its scope"]
            if t["stale"]:
                status.append("recheck: last checked on %s" % t["checked_release"])
            if t["past_expected_fix"]:
                status.append("still showing on or after its fix release %s" % t["expected_fix_release"])
            out.append("| %s `%s` | %s | %s | %s | %s |" % (
                t["title"], t["issue_id"], t["scope"], outside, "; ".join(status), t["reason"]))
    else:
        out.append("No listed issue shows on the release.")
    if stale:
        out += ["", "Due for a recheck (last checked %d or more releases ago):" % STALE_AFTER_RELEASES, ""]
        out += ["- %s `%s`, checked %s on %s" % (e["title"], e["issue_id"], e["checked_on"].isoformat(),
                                                e["checked_release"]) for e in stale]
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("issues", nargs="?", help="issues.json, the rows of release_health_issues.sql")
    ap.add_argument("--release", help="the version rolling out, e.g. 2.65.0")
    ap.add_argument("--list", default=str(DEFAULT_LIST))
    ap.add_argument("--json", action="store_true", help="print the tags as JSON instead of markdown")
    ap.add_argument("--validate", action="store_true", help="only check the list")
    a = ap.parse_args(argv)
    try:
        entries = load(a.list)
        if a.validate:
            print("%s: %d entries, valid" % (a.list, len(entries)))
            return 0
        if not a.issues or not a.release:
            ap.error("give issues.json and --release, or --validate")
        version_key(a.release)
    except ListError as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 1
    rows = json.loads(Path(a.issues).read_text(encoding="utf-8"))
    tags = tag(rows, entries, a.release)
    stale = stale_entries(entries, a.release)
    if a.json:
        print(json.dumps({"tags": tags, "stale": [e["issue_id"] for e in stale]}, indent=1))
    else:
        print(render(tags, stale, a.release))
    return 0


if __name__ == "__main__":
    sys.exit(main())
