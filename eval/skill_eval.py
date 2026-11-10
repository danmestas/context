#!/usr/bin/env python3
"""Measures the ctx agent skill against a private bank of past-work questions.

See eval/README.md. Everything derived from sessions stays in ~/.ctx/eval.
"""
import argparse
import concurrent.futures as cf
import glob
import hashlib
import json
import math
import os
import random
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

HOME = os.environ.get("SKILL_EVAL_HOME") or os.path.expanduser("~/.ctx/eval")
BANK = f"{HOME}/questions.json"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SKILL = os.path.join(HERE, "..", "skill", "ctx", "SKILL.md")
CLAUDE = os.environ.get("SKILL_EVAL_CLAUDE") or os.path.realpath(shutil.which("claude") or "claude")
CTX = os.environ.get("CTX") or os.path.realpath(shutil.which("ctx") or "ctx")

RUN_DEADLINE = 480
LONG_DEADLINE = 2400
VALUE = {"correct": 1.0, "partial": 0.5, "wrong": 0.0, "dont_know": 0.0}
SETTINGS = json.dumps({"disableAllHooks": True, "permissions": {"blockReadsOutsideWorkingDirectories": True}})
SKIP = shutil.ignore_patterns("node_modules", ".wrangler", "dist", "target", ".zig-cache", "zig-out", ".next", ".turbo")
READ_ONLY = ["Bash(git log*)", "Bash(git show*)", "Bash(git grep*)", "Bash(ls*)", "Bash(head*)", "Bash(tail*)",
             "Bash(wc*)", "Bash(cut*)", "Bash(sort*)", "Bash(uniq*)", "Bash(grep*)", "Bash(rg*)", "Bash(find*)",
             "Bash(cd*)", "Bash(echo*)", "Bash(cat*)", "Bash(sed*)", "Bash(awk*)", "Bash(tr*)", "Bash(xargs*)"]

ASK_DOCS = ("A teammate asks about this project's documents: {q}\n\n"
            "Find the answer from whatever sources you have here. If you cannot find it, say you do not know "
            "rather than guessing. Reply with the answer in under 120 words and name the evidence you relied on.")

ASK = ("A teammate asks about past work on this project: {q}\n\n"
       "Find the answer from whatever sources you have here. If you cannot find it, say you do not know "
       "rather than guessing. Reply with the answer in under 120 words and name the evidence you relied on.")

AUTHOR = """Write a gold question set for a memory benchmark about past work on the project `{project}`.
Reply with only a JSON array, no other text.

The archive of its sessions is available through `ctx`, run from this directory, which is a copy of the code:
`ctx search [--limit N] WORDS...` (any word matches, ranked), `ctx turn ID [BEFORE [AFTER]] [--full]`, and
`ctx sql "SELECT ... FROM ctx_chunk WHERE project='{project}' ..."` (columns id, doc_id, seq, heading [speaker],
at, turn, project, body). Only read.

Write {n} objects shaped {{"kind":"decision|failure|fix|user-said|status","question":"...","answer":"1-3 sentences",
"must_include":["each essential fact"],"evidence":[turn ids]}}.

Rules:
- Each answer must exist only in session history: why an option was rejected, what failed, a root cause that left
  no trace, what a person asked for. Grep the code, docs, comments, changelog and git log for the key terms and
  discard anything they answer.
- Read the turns yourself, and read far enough to get the final outcome. Plans get reversed.
- Spread across many sessions and across the five kinds.
- Word each question as a teammate would. Do not copy distinctive phrases from the session.
- A must_include item is a fact the question asks for. Never include incidental detail.
- No secrets, tokens or edit links.
{avoid}"""

REVIEW = """Adversarially verify this benchmark answer key for project `{project}`. Assume some entries are wrong.
Reply with only a JSON array of the surviving entries, in the same shape, with any corrections applied, no other text.

The archive is available through `ctx turn ID [BEFORE [AFTER]] [--full]`, `ctx search` and read-only `ctx sql`.
This directory is a copy of the code.

For each entry check: the evidence really says it; no later turn or session reverses it; the code, docs, changelog
and git log do not answer it, using your own search terms; every must_include item is something the question asks
for, and two graders would agree. Fix what can be fixed faithfully. Remove the entry otherwise. Add nothing new.

{questions}"""

GRADE = """BLIND-GRADE each answer against the key. Reply with only a JSON array of
{{"answer_id":"...","grade":"correct|partial|wrong|dont_know"}}, one per answer, no other text.

correct: states every must_include fact in any wording and nothing materially false.
partial: at least one must_include fact, not all, nothing materially false.
wrong: contradicts the key, misses every must_include fact while claiming an answer, or adds a materially false claim.
dont_know: says it could not find or does not know, without asserting a wrong answer.
Source mentions are masked as [source] and [ref]; ignore them. Grade each answer on its own, consistently.

KEY:
{key}

ANSWERS:
{answers}"""


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def set_of(qid):
    """A question's set never changes and needs no bookkeeping. One in three is held out."""
    return "holdout" if int(sha(qid), 16) % 3 == 0 else "dev"


def slug(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def mask(text):
    for pat, sub in ((r"`?\bctx\b( (search|turn|sql))?`?", "[source]"), (r"#\d{3,}", "[ref]"),
                     (r"\b[Tt]ranscripts?\b", "[source]"), (r"[\w.-]*\.jsonl", "[source]"),
                     (r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f-]{20,}", "[ref]"),
                     (r"\b[Aa]rchived? (sessions?|turns?)\b", "[source]"),
                     (r"\b(past|earlier|prior) sessions?\b", "[source]")):
        text = re.sub(pat, sub, text)
    return text


def sign_p(better, worse):
    """Two-sided exact sign test."""
    n = better + worse
    if not n:
        return 1.0
    return min(1.0, 2 * sum(math.comb(n, k) for k in range(min(better, worse) + 1)) / 2 ** n)


def load_bank():
    if not os.path.exists(BANK):
        return {"projects": {}, "questions": []}
    with open(BANK) as f:
        return json.load(f)


def write_json(path, value):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "w") as f:
        json.dump(value, f, indent=1)
    os.chmod(path, 0o600)


def parse_array(text):
    return json.loads(text[text.index("[") : text.rindex("]") + 1])


def spawn(cmd, cwd, env, deadline):
    return subprocess.run(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                          preexec_fn=lambda: signal.alarm(deadline))


def claude(prompt, model, fmt, tools, allow=(), dirs=()):
    cmd = [CLAUDE, "-p", prompt, "--model", model, "--setting-sources", "project", "--no-session-persistence",
           "--settings", SETTINGS, "--strict-mcp-config", "--permission-mode", "dontAsk", "--output-format", fmt,
           "--tools", tools]
    if fmt == "stream-json":
        cmd.append("--verbose")
    for d in dirs:
        cmd += ["--add-dir", d]
    if allow:
        cmd += ["--allowedTools", *allow]
    return cmd


class Workspace:
    """A frozen copy of the archive and of the code, removed afterwards."""

    def __enter__(self):
        os.makedirs(f"{HOME}/work", mode=0o700, exist_ok=True)
        self.dir = os.path.realpath(tempfile.mkdtemp(dir=f"{HOME}/work"))
        self.bin = f"{self.dir}/bin"
        os.makedirs(self.bin)
        shutil.copy(CTX, f"{self.bin}/ctx")
        self.snap = f"{self.dir}/snap.sqlite"
        p = subprocess.run([CTX, "sql", f"VACUUM INTO '{self.snap}'"], capture_output=True, text=True)
        if p.returncode:
            sys.exit(f"cannot freeze the archive: {p.stderr}")
        return self

    def __exit__(self, *_):
        shutil.rmtree(self.dir, ignore_errors=True)

    def wiki_files(self, cwd):
        """Writes each current wiki page to wiki/NAME.md, for condition F."""
        if os.path.isdir(f"{cwd}/wiki"):
            return
        os.makedirs(f"{cwd}/wiki")
        env = dict(os.environ, CTX_DB=self.snap)
        names = subprocess.run([CTX, "sql", "SELECT d.name, r.name FROM ctx_doc d JOIN ctx_repo r ON r.id = d.repo_id"
                                " WHERE d.kind = 'wiki' AND coalesce(d.status, '') <> 'retired'"],
                               env=env, capture_output=True, text=True).stdout.splitlines()
        for line in names:
            page, repo = line.split("\t")
            text = subprocess.run([CTX, "sql", f"SELECT fsl_open('repo:{repo}', 'eval'), fsl_use('repo:{repo}'), fsl_wiki('" + page.replace("'", "''") + "')"],
                                  env=env, capture_output=True, text=True).stdout
            body = "\t".join(text.split("\t")[2:]) if "\t" in text else text
            with open(f"{cwd}/wiki/{re.sub(r'[^A-Za-z0-9._-]+', '-', page)}.md", "w") as f:
                f.write(body)

    def without_wiki(self):
        """A second frozen copy with the wiki taken out of the index, for condition S."""
        path = f"{self.dir}/snap-nowiki.sqlite"
        if not os.path.exists(path):
            part = path + ".part"  # renamed into place only when complete
            shutil.copy(self.snap, part)
            env = dict(os.environ, CTX_DB=part)
            for sql in ("DELETE FROM ctx_chunk WHERE doc_id IN (SELECT id FROM ctx_doc WHERE kind = 'wiki')",
                        "DELETE FROM ctx_doc WHERE kind = 'wiki'"):
                p = subprocess.run([CTX, "sql", sql], env=env, capture_output=True, text=True)
                if p.returncode:
                    sys.exit(f"cannot remove the wiki: {p.stderr}")
            os.rename(part, path)
        return path

    def repo(self, cond, project, source):
        dst = f"{self.dir}/repos/{cond}/{project}"
        if not os.path.exists(dst):
            shutil.copytree(source, dst, symlinks=True, ignore=SKIP)
        return dst

    def env(self, with_ctx, db=None):
        env = dict(os.environ)
        hide = os.path.dirname(CTX)
        env["PATH"] = ":".join(p for p in env.get("PATH", "").split(":") if p != hide)
        env.pop("CTX_DB", None)
        if with_ctx:
            env["PATH"] = f"{self.bin}:{env['PATH']}"
            env["CTX_DB"] = db or self.snap
        return env


def breaches(inputs, own):
    """Tool calls that reached session history they should not have seen."""
    found = []
    for name, text, failed in inputs:
        if failed:
            continue
        if ".ctx/" in text.replace("/.ctx/eval/work/", "/"):  # the workspace itself lives under .ctx
            found.append(text[:90])
        for target in re.findall(r"\.claude/projects/([^\s\"'/]*)", text):
            if not target.startswith(own):
                found.append(text[:90])
    return found


def digest(stdout, cond, own):
    r = dict(tools=0, ctx=0, skill=0, breach=[], result=None, ok=False, new=0, cached=0, secs=0, turns=0,
             denials=0, cost=0)
    uses, inputs = {}, []
    for line in stdout.splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("type") == "assistant":
            for c in d["message"].get("content", []):
                if c.get("type") == "tool_use":
                    r["tools"] += 1
                    text = json.dumps(c["input"])
                    uses[c["id"]] = (c["name"], text)
                    r["skill"] += c["name"] == "Skill" and "ctx" in text
                    r["ctx"] += c["name"] == "Bash" and bool(re.search(r"(^|[\s;&|\"])ctx\s", text))
        elif d.get("type") == "user" and isinstance(d["message"].get("content"), list):
            for c in d["message"]["content"]:
                if c.get("type") == "tool_result" and c.get("tool_use_id") in uses:
                    inputs.append((*uses[c["tool_use_id"]], bool(c.get("is_error"))))
        elif d.get("type") == "result":
            u = d["usage"]
            r.update(ok=d.get("subtype") == "success", result=d.get("result"), turns=d.get("num_turns", 0),
                     secs=round(d.get("duration_ms", 0) / 1000), cost=d.get("total_cost_usd") or 0,
                     new=u["input_tokens"] + u.get("cache_creation_input_tokens", 0) + u["output_tokens"],
                     cached=u.get("cache_read_input_tokens", 0), denials=len(d.get("permission_denials") or []))
    if cond != "B":
        r["breach"] = breaches(inputs, own)
    return r


def cmd_run(a):
    bank = load_bank()
    qs = [q for q in bank["questions"] if a.set == "all" or set_of(q["id"]) == a.set]
    if a.only:
        qs = [q for q in qs if q["id"] in a.only.split(",")]
    if not qs:
        sys.exit("no questions in that set; run `author` first")
    with open(a.skill) as f:
        skill = f.read()
    skill_id = sha(skill)[:12]
    name = a.name or f"{time.strftime('%Y%m%d-%H%M%S')}-{skill_id}-{a.set}"
    out = f"{HOME}/runs/{name}"
    conds = a.cond.split(",")
    with Workspace() as w:
        own = slug(w.dir)

        def job(item):
            q, cond = item
            project = bank["projects"][q["project"]]
            cwd = w.repo(cond, q["project"], project["repo"])
            prompt = (ASK_DOCS if cond in "SWF" else ASK).format(q=q["question"])
            allow, dirs = list(READ_ONLY), []
            if cond == "B":
                dirs = glob.glob(os.path.expanduser(f"~/.claude/projects/{slug(project['sessions'])}*"))
                prompt += "\n\nTranscripts of past coding sessions on this project are JSONL files in:\n" + "\n".join(dirs)
                allow += ["Bash(jq*)", "Bash(python3*)"]
            if cond in "CI":
                allow.append("Bash(ctx *)")
            if cond in "SWF":  # same tools; only the wiki differs: W in the index, F as files, S neither
                allow += ["Bash(ctx search *)", "Bash(ctx turn *)"]
            db = w.without_wiki() if cond in "SF" else None
            cmd = claude(prompt, a.model, "stream-json", "Bash,Read,Grep,Glob,Skill", allow, dirs)
            if cond == "I":  # what the UserPromptSubmit hook would add for this prompt
                hook = subprocess.run([f"{w.bin}/ctx", "inject"], input=json.dumps({"session_id": "eval", "cwd": cwd, "prompt": prompt}),
                                      env=w.env(True), cwd=cwd, capture_output=True, text=True, timeout=30).stdout
                extra = json.loads(hook)["hookSpecificOutput"]["additionalContext"] if hook.strip() else ""
                if extra:
                    cmd += ["--append-system-prompt", extra]
            p = spawn(cmd, cwd, w.env(cond in "CSWFI", db), RUN_DEADLINE)
            r = digest(p.stdout, cond, own)
            r.update(qid=q["id"], cond=cond, project=q["project"], kind=q["kind"], injected=cond == "I" and "--append-system-prompt" in cmd)
            return r

        for q in qs:  # copies are made up front so parallel jobs never race
            for cond in conds:
                cwd = w.repo(cond, q["project"], bank["projects"][q["project"]]["repo"])
                if cond == "F":
                    w.wiki_files(cwd)
                if cond in "CSWFI":
                    os.makedirs(f"{cwd}/.claude/skills/ctx", exist_ok=True)
                    with open(f"{cwd}/.claude/skills/ctx/SKILL.md", "w") as f:
                        f.write(skill)
        if set(conds) & set("SF"):  # made before the parallel runs, which share it
            w.without_wiki()
        items = [(q, c) for q in qs for c in conds]
        random.Random(7).shuffle(items)
        with cf.ThreadPoolExecutor(a.jobs) as ex:
            rows = list(ex.map(job, items))
    write_json(f"{out}/runs.json", rows)
    write_json(f"{out}/meta.json", dict(skill=skill_id, set=a.set, conds=conds, model=a.model, at=time.time(),
                                        questions=[q["id"] for q in qs]))
    bad = sum(not r["ok"] for r in rows)
    void = sum(bool(r["breach"]) for r in rows)
    print(out)
    print(f"{len(rows)} runs, {bad} failed, {void} breached isolation", file=sys.stderr)


def grade(paths, model):
    """Grades runs in one shuffled pass, so comparisons share one grader."""
    gold = {q["id"]: q for q in load_bank()["questions"]}
    entries = []
    for path in paths:
        for r in json.load(open(f"{path}/runs.json")):
            if r["result"] and not r["breach"]:
                entries.append((path, r))
    random.SystemRandom().shuffle(entries)
    ids = {sha(f"{i}{time.time()}")[:10]: e for i, e in enumerate(entries)}
    used = {r["qid"] for _, r in entries}
    key = [{k: gold[q][k] for k in ("id", "question", "answer", "must_include")} for q in sorted(used)]
    answers = [{"answer_id": i, "question_id": e[1]["qid"], "answer": mask(e[1]["result"])} for i, e in ids.items()]
    got = {}
    batch = 25  # one call cannot reliably grade more; batches share the key and the shuffle
    for start in range(0, len(answers), batch):
        part = answers[start:start + batch]
        want = {x["answer_id"] for x in part}
        ids_in = {x["question_id"] for x in part}
        prompt = GRADE.format(key=json.dumps([k for k in key if k["id"] in ids_in], indent=0), answers=json.dumps(part, indent=0))
        for _ in range(3):
            with tempfile.TemporaryDirectory(dir=HOME) as cwd:
                p = spawn(claude(prompt, model, "json", ""), cwd, dict(os.environ), LONG_DEADLINE)
            try:
                found = {x["answer_id"]: x["grade"] for x in parse_array(json.loads(p.stdout)["result"])}
            except (ValueError, KeyError, TypeError):
                continue
            if want <= set(found) and {found[k] for k in want} <= set(VALUE):
                got.update({k: found[k] for k in want})
                break
        else:
            sys.exit("the grader did not grade every answer")
    pass_id = sha(f"{paths}{time.time()}")[:12]
    per = {path: {} for path in paths}
    for i, (path, r) in ids.items():
        per[path][f"{r['qid']}.{r['cond']}"] = got[i]
    for path in paths:
        write_json(f"{path}/grades.json", dict(pass_id=pass_id, grades=per[path]))


def cmd_grade(a):
    grade(a.runs, a.model)
    print("graded", *a.runs)


def table(path):
    rows = json.load(open(f"{path}/runs.json"))
    g = json.load(open(f"{path}/grades.json"))
    out = {}
    for r in rows:
        k = f"{r['qid']}.{r['cond']}"
        if k in g["grades"]:
            out.setdefault(r["cond"], {})[r["qid"]] = dict(r, grade=g["grades"][k])
    return out, g["pass_id"]


def stats(cells):
    grades = [c["grade"] for c in cells.values()]
    return dict(n=len(grades), score=sum(VALUE[x] for x in grades), wrong=grades.count("wrong"),
                correct=grades.count("correct"), partial=grades.count("partial"), dont_know=grades.count("dont_know"),
                new=sum(c["new"] for c in cells.values()),
                tools=statistics.median(c["tools"] for c in cells.values()),
                secs=statistics.median(c["secs"] for c in cells.values()),
                used=sum(c["ctx"] > 0 for c in cells.values()))


def paired(a, b):
    """How often a beat b on the questions they share."""
    shared = set(a) & set(b)
    better = sum(VALUE[a[q]["grade"]] > VALUE[b[q]["grade"]] for q in shared)
    worse = sum(VALUE[a[q]["grade"]] < VALUE[b[q]["grade"]] for q in shared)
    return better, worse, sign_p(better, worse)


def cmd_report(a):
    t, _ = table(a.run)
    for cond in sorted(t):
        s = stats(t[cond])
        print(f"{cond}: score {s['score']:.1f}/{s['n']}  correct {s['correct']} partial {s['partial']} wrong {s['wrong']} "
              f"dont_know {s['dont_know']}  new tokens {s['new']}  tools {s['tools']:g}  secs {s['secs']:g}  used ctx {s['used']}")
    conds = sorted(t)
    for i, x in enumerate(conds):
        for y in conds[i + 1 :]:
            print("%s vs %s: better %d, worse %d, p=%.3f" % (y, x, *paired(t[y], t[x])))


def cmd_compare(a):
    told, pold = table(a.old) if os.path.exists(f"{a.old}/grades.json") else (None, None)
    tnew, pnew = table(a.new) if os.path.exists(f"{a.new}/grades.json") else (None, None)
    if told is None or tnew is None or pold != pnew:
        grade([a.old, a.new], a.model)
        told, _ = table(a.old)
        tnew, _ = table(a.new)
    old, new = told["C"], tnew["C"]
    shared = set(old) & set(new)
    if not shared:
        sys.exit("the runs share no questions")
    so = stats({q: old[q] for q in shared})
    sn = stats({q: new[q] for q in shared})
    better, worse, p = paired(new, old)
    print(f"questions {len(shared)}")
    print(f"old: score {so['score']:.1f} wrong {so['wrong']} new tokens {so['new']}")
    print(f"new: score {sn['score']:.1f} wrong {sn['wrong']} new tokens {sn['new']}")
    print(f"new better on {better}, worse on {worse}, p={p:.3f}")
    fails = []
    if sn["score"] < so["score"]:
        fails.append("score dropped")
    if sn["wrong"] > so["wrong"]:
        fails.append("more wrong answers")
    if sn["new"] > so["new"] * 1.15:
        fails.append("tokens rose over 15%")
    print("PASS" if not fails else "FAIL: " + ", ".join(fails))
    sys.exit(1 if fails else 0)


def ctx_calls(body):
    """Each `ctx SUBCOMMAND ARGS` an assistant turn ran, from its recorded Bash calls."""
    found = []
    for line in body.splitlines():
        if not line.startswith("Bash {"):
            continue
        try:
            command = json.loads(line[5:])["command"]
        except (ValueError, KeyError):
            continue
        command = re.sub(r"<<-?\s*['\"]?(\w+)['\"]?.*?\n\s*\1\b", "", command, flags=re.S)  # heredoc bodies are data
        for m in re.finditer(r"(?:^\s*|[;&|]\s*)(?:\w+=\S+\s+)*(?:\S*/)?ctx\s+([a-z-]+)([^;&|\n]*)", command, re.M):
            found.append((m.group(1), m.group(2).split()))
    return found


def known_commands(ctx=None):
    """The subcommands ctx lists in its own usage text, so the list cannot fall behind."""
    p = subprocess.run([ctx or CTX], capture_output=True, text=True)
    return set(re.findall(r"^\s*(?:usage: )?ctx ([a-z]+)", p.stderr + p.stdout, re.M))


def cmd_usage(a):
    known = known_commands()
    sql = ("SELECT json_object('project', a.project, 'at', substr(a.at,1,10), 'body', a.body, 'next', substr(b.body,1,300))"
           " FROM ctx_chunk a LEFT JOIN ctx_chunk b ON b.doc_id = a.doc_id AND b.seq = a.seq + 1"
           " WHERE a.heading = 'assistant' AND a.body LIKE '%Bash {%ctx %'"
           f" AND coalesce(a.project,'') <> '{a.exclude}'")
    p = subprocess.run([CTX, "sql", sql], capture_output=True, text=True)
    if p.returncode:
        sys.exit(p.stderr)
    calls = unknown = nohit = long_query = 0
    examples = {"unknown": [], "nohit": [], "long": []}
    for line in p.stdout.splitlines():
        d = json.loads(line)
        for sub, rest in ctx_calls(d["body"]):
            calls += 1
            if sub not in known:
                unknown += 1
                examples["unknown"].append(f"ctx {sub}")
            elif sub == "search":
                words = [w for w in rest if not w.startswith("--") and not w.isdigit()]
                if len(words) > 4:
                    long_query += 1
                    examples["long"].append(" ".join(words)[:70])
                if d.get("next") and "no matches" in d["next"]:
                    nohit += 1
                    examples["nohit"].append(" ".join(words)[:70])
    print(f"ctx commands by agents: {calls}\nunknown commands: {unknown}\nsearches over 4 words: {long_query}\nsearches with no matches: {nohit}")
    for k, v in examples.items():
        for e in sorted(set(v))[:a.examples]:
            print(f"  {k}: {e}")


def cmd_author(a):
    bank = load_bank()
    bank["projects"][a.project] = dict(repo=os.path.abspath(a.repo), sessions=os.path.abspath(a.sessions or a.repo))
    have = [q["question"] for q in bank["questions"] if q["project"] == a.project]
    avoid = "- Do not repeat these existing questions:\n" + "\n".join(f"  {q}" for q in have) if have else ""
    tools, allow = "Bash,Read,Grep,Glob", READ_ONLY + ["Bash(ctx *)"]
    with Workspace() as w:
        cwd = w.repo("author", a.project, bank["projects"][a.project]["repo"])

        def ask(prompt):
            for attempt in range(2):
                p = spawn(claude(prompt, a.model, "json", tools, allow), cwd, w.env(True), LONG_DEADLINE)
                try:
                    d = json.loads(p.stdout)
                    print(f"{a.project}: {d.get('num_turns')} turns", file=sys.stderr)
                    return parse_array(d["result"])
                except (ValueError, KeyError):
                    print(f"{a.project}: attempt {attempt + 1} gave no JSON (exit {p.returncode}): "
                          f"{(p.stdout or p.stderr)[-200:]}", file=sys.stderr)
            sys.exit(f"{a.project}: no usable reply")

        drafted = ask(AUTHOR.format(project=a.project, n=a.n, avoid=avoid))
        kept = ask(REVIEW.format(project=a.project, questions=json.dumps(drafted, indent=0)))
    for q in kept:
        q.update(project=a.project, id=f"{slug(a.project).lower()}-{sha(q['question'])[:8]}",
                 added=time.strftime("%Y-%m-%d"))
    latest = load_bank()  # other projects may have been added while this one ran
    latest["projects"][a.project] = bank["projects"][a.project]
    seen = {q["id"] for q in latest["questions"]}
    latest["questions"] += [q for q in kept if q["id"] not in seen]
    bank = latest
    write_json(BANK, bank)
    print(f"drafted {len(drafted)}, kept {len(kept)}, bank now {len(bank['questions'])}")


def main():
    ap = argparse.ArgumentParser(prog="skill_eval")
    ap.add_argument("--bank", help="question bank file, if not ~/.ctx/eval/questions.json")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("author", help="add reviewed questions for a project to the bank")
    p.add_argument("--project", required=True, help="the project name ctx knows it by")
    p.add_argument("--repo", required=True, help="a checkout of the code")
    p.add_argument("--sessions", help="the path sessions ran in, if not --repo")
    p.add_argument("--n", type=int, default=12)
    p.add_argument("--model", default="opus")
    p.set_defaults(fn=cmd_author)
    p = sub.add_parser("run", help="answer questions in fresh isolated processes")
    p.add_argument("--set", choices=("dev", "holdout", "all"), default="dev")
    p.add_argument("--cond", default="C", help="A repo only, B grep over transcripts, C the skill, I the skill plus injection; for documents, S sources only, W wiki in the index, F wiki as files")
    p.add_argument("--skill", default=DEFAULT_SKILL)
    p.add_argument("--only", help="comma-separated question ids")
    p.add_argument("--name")
    p.add_argument("--model", default="sonnet")
    p.add_argument("--jobs", type=int, default=6)
    p.set_defaults(fn=cmd_run)
    p = sub.add_parser("grade", help="grade runs blind, in one pass")
    p.add_argument("runs", nargs="+")
    p.add_argument("--model", default="opus")
    p.set_defaults(fn=cmd_grade)
    p = sub.add_parser("report", help="summarize a graded run")
    p.add_argument("run")
    p.set_defaults(fn=cmd_report)
    p = sub.add_parser("compare", help="gate a new skill against an old one; exits 1 on regression")
    p.add_argument("old")
    p.add_argument("new")
    p.add_argument("--model", default="opus")
    p.set_defaults(fn=cmd_compare)
    p = sub.add_parser("usage", help="how agents really used ctx, from the archive")
    p.add_argument("--exclude", default="context", help="project to leave out")
    p.add_argument("--examples", type=int, default=8)
    p.set_defaults(fn=cmd_usage)
    a = ap.parse_args()
    if a.bank:
        global BANK
        BANK = os.path.abspath(a.bank)
    os.makedirs(HOME, mode=0o700, exist_ok=True)
    a.fn(a)


if __name__ == "__main__":
    main()
