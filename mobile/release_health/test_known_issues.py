"""Tests for known_issues.py. Run with `python -m pytest mobile/release_health`."""
import json
from datetime import date

import pytest

import known_issues as ki

A = "a" * 32
B = "b" * 32


def entry(**kw):
    e = {"issue_id": A, "title": "Some crash", "reason": "old", "checked_on": date(2026, 10, 28),
         "checked_release": "2.65.0"}
    e.update(kw)
    return e


def row(issue_id=A, scopes=None, **kw):
    r = {"issue_id": issue_id, "release_events": 5, "release_devices": 3}
    if scopes is not None:
        r["release_scopes"] = [{"domain": d, "device_manufacturer": mf, "device_model": m,
                                "devices": n, "fresh_devices": f} for d, mf, m, n, f in scopes]
    r.update(kw)
    return r


def write_list(tmp_path, text):
    p = tmp_path / "list.toml"
    p.write_text(text, encoding="utf-8")
    return p


GOOD = """
[[issue]]
issue_id = "%s"
title = "Some crash"
reason = "old"
checked_on = 2026-10-28
checked_release = "2.65.0"
projects = ["proj-a"]
""" % A


def test_shipped_list_is_valid():
    entries = ki.load()
    assert entries
    for e in entries.values():
        assert e["checked_release"]


def test_load_good(tmp_path):
    entries = ki.load(write_list(tmp_path, GOOD))
    assert list(entries) == [A]
    assert entries[A]["checked_on"] == date(2026, 10, 28)


def test_load_older_issue_id(tmp_path):
    older = "c" * 24
    assert list(ki.load(write_list(tmp_path, GOOD.replace(A, older)))) == [older]


@pytest.mark.parametrize("change, message", [
    (('issue_id = "%s"' % A, 'issue_id = "XYZ"'), "32 lowercase hex"),
    (('issue_id = "%s"' % A, 'issue_id = "%s"' % ("a" * 28)), "32 lowercase hex"),
    (('reason = "old"\n', ""), "missing reason"),
    (("checked_on = 2026-10-28", 'checked_on = "last week"'), "TOML date"),
    (('checked_release = "2.65.0"', 'checked_release = "2.65.0-beta"'), "checked_release"),
    (('projects = ["proj-a"]', 'projects = "proj-a"'), "list of names"),
    (('projects = ["proj-a"]', 'project = ["proj-a"]'), "unknown field"),
    (('projects = ["proj-a"]', 'fixing_pr = "https://github.com/dimagi/commcare-android/pull/1"'),
     "needs its expected_fix_release"),
    (('projects = ["proj-a"]', 'fixing_pr = "PR 12"\nexpected_fix_release = "2.66.0"'), "pull request URL"),
    (('projects = ["proj-a"]', 'error_type = "CRASH"'), "error_type"),
])
def test_load_rejects(tmp_path, change, message):
    with pytest.raises(ki.ListError, match=message):
        ki.load(write_list(tmp_path, GOOD.replace(*change)))


def test_load_rejects_duplicates(tmp_path):
    with pytest.raises(ki.ListError, match="listed twice"):
        ki.load(write_list(tmp_path, GOOD + GOOD))


def test_releases_between():
    assert ki.releases_between("2.65.0", "2.65.3") == 0
    assert ki.releases_between("2.65.0", "2.66.0") == 1
    assert ki.releases_between("2.64.1", "2.66.0") == 2
    assert ki.releases_between("2.66.0", "2.65.0") == -1
    assert ki.releases_between("2.99.0", "3.0.0") == ki.STALE_AFTER_RELEASES


def test_in_scope_matches_project_and_model_loosely():
    e = entry(projects=["Proj-A"], device_models=["Tecno BF6"])
    assert ki.in_scope(e, "proj-a", "TECNO BF6")
    assert ki.in_scope(e, "proj-a", "BF6", "TECNO")
    assert not ki.in_scope(e, "proj-b", "TECNO BF6")
    assert not ki.in_scope(e, "proj-a", "SM-A175F", "samsung")
    assert ki.in_scope(entry(), None, None)


def test_in_scope_reads_the_project_out_of_the_domain_key():
    e = entry(projects=["fundacion-plan"])
    assert ki.in_scope(e, "fundacion-plan.commcarehq.org", "SM-A175F")
    assert ki.in_scope(e, "fundacion-plan.india.commcarehq.org", "SM-A175F")
    assert not ki.in_scope(e, "fundacion-plan-2.commcarehq.org", "SM-A175F")
    assert not ki.in_scope(e, None, "SM-A175F")


def test_unscoped_entry_is_exempt():
    [t] = ki.tag([row(scopes=[("x", "m", "y", 4, 2)])], {A: entry()}, "2.65.0")
    assert t["exempt"] and t["out_of_scope_devices"] == 0


def test_scoped_entry_exempt_when_all_devices_in_scope():
    e = entry(projects=["proj-a"])
    [t] = ki.tag([row(scopes=[("proj-a", "samsung", "SM-A175F", 3, 1)])], {A: e}, "2.65.0")
    assert t["exempt"]
    assert (t["out_of_scope_devices"], t["out_of_scope_fresh_devices"]) == (0, 0)


def test_scoped_entry_not_exempt_when_hit_outside():
    e = entry(projects=["proj-a"])
    rows = [row(scopes=[("proj-a", "samsung", "SM-A175F", 3, 1),
                        ("proj-b", "samsung", "SM-A175F", 2, 2),
                        (None, None, None, 1, 0)])]
    [t] = ki.tag(rows, {A: e}, "2.65.0")
    assert not t["exempt"]
    assert (t["out_of_scope_devices"], t["out_of_scope_fresh_devices"]) == (3, 2)


def test_scoped_entry_without_breakdown_is_not_exempt():
    [t] = ki.tag([row()], {A: entry(projects=["proj-a"])}, "2.65.0")
    assert t["out_of_scope_devices"] is None and not t["exempt"]


def test_only_listed_rows_are_tagged_and_crashlytics_ids_work():
    tags = ki.tag([row(B), {"id": A, "events": 2}], {A: entry()}, "2.65.0")
    assert [t["issue_id"] for t in tags] == [A]


def test_stale_after_two_releases():
    entries = {A: entry(checked_release="2.65.0"), B: entry(issue_id=B, checked_release="2.66.0")}
    assert [t["stale"] for t in ki.tag([row(A), row(B)], entries, "2.66.1")] == [False, False]
    assert [t["stale"] for t in ki.tag([row(A), row(B)], entries, "2.67.0")] == [True, False]
    assert [e["issue_id"] for e in ki.stale_entries(entries, "2.67.0")] == [A]


def test_past_expected_fix():
    e = entry(expected_fix_release="2.66.0", fixing_pr="https://github.com/dimagi/commcare-android/pull/4000")
    assert not ki.tag([row()], {A: e}, "2.65.2")[0]["past_expected_fix"]
    assert ki.tag([row()], {A: e}, "2.66.0")[0]["past_expected_fix"]
    assert ki.tag([row()], {A: e}, "2.67.1")[0]["past_expected_fix"]
    assert not ki.tag([row()], {A: entry()}, "2.70.0")[0]["past_expected_fix"]


def test_cli_markdown_and_json(tmp_path, capsys):
    lst = write_list(tmp_path, GOOD)
    issues = tmp_path / "issues.json"
    issues.write_text(json.dumps([row(scopes=[("proj-b", "x", "y", 2, 1)])]), encoding="utf-8")
    assert ki.main([str(issues), "--release", "2.67.0", "--list", str(lst)]) == 0
    out = capsys.readouterr().out
    assert "Known, but hit outside its scope" in out and "recheck" in out and "2 (1)" in out
    assert ki.main([str(issues), "--release", "2.65.0", "--list", str(lst), "--json"]) == 0
    data = json.loads(capsys.readouterr().out)
    assert data["tags"][0]["out_of_scope_devices"] == 2 and data["stale"] == []


def test_cli_validate_reports_errors(tmp_path, capsys):
    assert ki.main(["--validate", "--list", str(write_list(tmp_path, GOOD))]) == 0
    assert ki.main(["--validate", "--list", str(write_list(tmp_path, GOOD + GOOD))]) == 1
    assert "listed twice" in capsys.readouterr().err
