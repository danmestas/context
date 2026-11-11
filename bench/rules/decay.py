#!/usr/bin/env python3
"""Replays rule-decay policies over the archive and scores them against the person's
labels of which rules are still true. Nothing here changes ctx; it decides whether a
policy is worth building.

  bench/rules/decay.py [--labels ~/.ctx/eval/rules/decay-labels.json] [--today 2026-11-10]

Labels are private and stay in ~/.ctx/eval/rules: a JSON list of {n, kind, project,
label (true|stale|unsure), since, key} where key names an imported rule; stated
rules without a key are matched by text from --stated.

A policy says, for a rule on a given day, whether it is quiet (not offered). Scored at
--today: of the stale rules, how many are quiet (recall); of the quiet rules, how many
are stale (precision); and how many true rules were quieted by mistake.
"""
import argparse
import collections
import datetime as dt
import json
import os
import re
import shutil
import subprocess

CTX = os.environ.get("CTX") or os.path.realpath(shutil.which("ctx") or "ctx")
STOP = set("""about above after again against also always because before being below between both could does doing
during each every from further have having here into itself just more most never once only other ought ourselves
over same should some such than that their them then there these they this those through under until very what when
where which while will with would your yours user session agent before after rule rules make sure dont don't""".split())


def sql(q):
    return subprocess.run([CTX, "sql", q], capture_output=True, text=True, check=True).stdout


def day(s):
    return dt.date.fromisoformat(s[:10]) if s and len(s) >= 10 else None


def terms(text):
    """Distinctive words of a rule: longer words that are not common."""
    words = re.findall(r"[a-z][a-z0-9_.-]{4,}", text.lower())
    return [w for w in dict.fromkeys(words) if w not in STOP][:12]


def load(a):
    labels = json.load(open(os.path.expanduser(a.labels)))
    stated = json.load(open(os.path.expanduser(a.stated))) if a.stated and os.path.exists(os.path.expanduser(a.stated)) else {}
    rules = []
    for x in labels:
        if x["label"] == "unsure":
            continue
        if x.get("key"):
            row = sql(f"SELECT replace(c.body, char(10), ' ') FROM ctx_doc d JOIN ctx_chunk c ON c.doc_id = d.id"
                      f" WHERE d.kind = 'rule' AND d.name = '{x['key'].replace(chr(39), chr(39) * 2)}'").strip()
            born = None
            path = x["key"]
            if os.path.exists(path):
                st = os.stat(path)
                born = dt.date.fromtimestamp(getattr(st, "st_birthtime", st.st_mtime))
            m = re.search(r"originSessionId:\s*([0-9a-f-]{36})", row)
            if m:  # the session it was written in, when the archive has it
                d = sql(f"SELECT min(c.at) FROM ctx_chunk c JOIN ctx_capture_day cd ON cd.session = '{m.group(1)}'"
                        f" JOIN ctx_doc dd ON dd.kind = 'session' AND dd.name = cd.technote AND dd.id = c.doc_id").strip()
                born = day(d) or born
            body = re.sub(r"^---.*?---", "", row, flags=re.S)
        else:
            s = stated.get(str(x["n"]), {})
            body, born = s.get("text", ""), day(s.get("at", ""))
        if not body or not born:
            continue
        rules.append(dict(n=x["n"], project=x["project"], label=x["label"], since=x.get("since", ""), body=body,
                          born=born, terms=terms(body)))
    return rules


def activity(projects):
    """For each project: the days it had sessions, and its user turns with their day."""
    days, turns = collections.defaultdict(set), collections.defaultdict(list)
    for p in projects:
        q = p.replace("'", "''")
        for line in sql(f"SELECT substr(c.at, 1, 10), c.heading, lower(replace(substr(c.body, 1, 2000), char(10), ' '))"
                        f" FROM ctx_chunk c JOIN ctx_doc d ON d.id = c.doc_id WHERE d.kind = 'session'"
                        f" AND coalesce(c.project, d.project) = '{q}' AND c.at IS NOT NULL AND c.at <> ''"
                        f" AND c.heading IN ('user', 'assistant')").splitlines():
            parts = line.split("\t", 2)
            if len(parts) < 3 or not day(parts[0]):
                continue
            d = day(parts[0])
            days[p].add(d)
            if parts[1] == "user":
                turns[p].append((d, parts[2]))
    return days, turns


def renewals(rule, turns):
    """Days the person mentioned the rule again: a turn of theirs holding enough of its terms."""
    need = max(2, (len(rule["terms"]) + 2) // 3)
    out = []
    for d, text in turns[rule["project"]]:
        if d <= rule["born"]:
            continue
        if sum(t in text for t in rule["terms"]) >= need:
            out.append(d)
    return sorted(set(out))


def paths_gone(rule):
    """A file path or command the rule names that no longer exists."""
    for p in re.findall(r"(?:~|/Users/[\w.-]+)/[\w./-]+", rule["body"]):
        q = os.path.expanduser(p.rstrip(".,;:)"))
        if q.count("/") >= 3 and not os.path.exists(q):
            return True
    return False


def policies(today, days):
    def none(r, ren):
        return False

    def flat90(r, ren):
        return (today - r["born"]).days > 90

    def schedule(r, ren):
        last, interval = r["born"], 90
        for d in ren:  # each renewal inside the interval doubles it, up to a year
            if (d - last).days <= interval:
                interval = min(interval * 2, 365)
            last = d
        return (today - last).days > interval

    def dormant(r, ren):
        active = [d for d in days[r["project"]] if d <= today]
        return not active or (today - max(active)).days > 60

    def schedule_checks(r, ren):
        return schedule(r, ren) or dormant(r, ren) or paths_gone(r)

    return {"none": none, "flat 90 days": flat90, "schedule": schedule, "schedule + checks": schedule_checks}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--labels", default="~/.ctx/eval/rules/decay-labels.json")
    ap.add_argument("--stated", default="~/.ctx/eval/rules/decay-stated.json")
    ap.add_argument("--today", default=dt.date.today().isoformat())
    a = ap.parse_args()
    today = dt.date.fromisoformat(a.today)
    rules = load(a)
    days, turns = activity({r["project"] for r in rules})
    for r in rules:
        r["renewals"] = renewals(r, turns)
    stale = [r for r in rules if r["label"] == "stale"]
    true = [r for r in rules if r["label"] == "true"]
    print(f"{len(rules)} labelled rules scored ({len(stale)} stale, {len(true)} true); today {today}")
    print(f"renewals found: median {sorted(len(r['renewals']) for r in rules)[len(rules) // 2]}, rules with none {sum(not r['renewals'] for r in rules)}")
    for name, quiet in policies(today, days).items():
        q = {r["n"] for r in rules if quiet(r, r["renewals"])}
        hit = len([r for r in stale if r["n"] in q])
        wrong = len([r for r in true if r["n"] in q])
        prec = hit / len(q) if q else 0
        rec = hit / len(stale) if stale else 0
        print(f"  {name:18} quiet {len(q):2}  stale caught {hit}/{len(stale)} ({rec:.0%})  true wrongly quiet {wrong}/{len(true)}"
              f"  precision {prec:.0%}")
    # timing: rules said to have gone stale in a month, quiet by the end of the next one?
    timed = [r for r in stale if r["since"]]
    for r in timed:
        y, m = map(int, r["since"].split("-"))
        end = dt.date(y + (m == 12), m % 12 + 1, 28)
        late = {name: quiet(r, [d for d in r["renewals"] if d <= end]) for name, quiet in policies(end, days).items()}
        print(f"  rule {r['n']} stale since {r['since']}: quiet by {end}? " + ", ".join(f"{k}: {'yes' if v else 'no'}" for k, v in late.items()))
    # how often an agent would ask: rules newly due per project per week over the last 26 weeks, schedule policy
    sched = policies(today, days)["schedule"]
    weekly = collections.Counter()
    for w in range(26):
        t = today - dt.timedelta(weeks=w)
        prev = t - dt.timedelta(weeks=1)
        pol_t, pol_p = policies(t, days)["schedule"], policies(prev, days)["schedule"]
        for r in rules:
            if r["born"] <= prev and pol_t(r, [d for d in r["renewals"] if d <= t]) and not pol_p(r, [d for d in r["renewals"] if d <= prev]):
                weekly[(w, r["project"])] += 1
    worst = max(weekly.values()) if weekly else 0
    print(f"  asks under the schedule (this labelled sample only): {sum(weekly.values())} in 26 weeks, at most {worst} for one project in one week")


if __name__ == "__main__":
    main()
