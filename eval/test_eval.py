#!/usr/bin/env python3
"""Tests skill_eval end to end with a stand-in for the model. usage: test_eval.py CTX"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ["SKILL_EVAL_HOME"] = tempfile.mkdtemp()
import skill_eval as se  # noqa: E402

assert se.sign_p(3, 0) == 0.25 and se.sign_p(0, 0) == 1.0
assert se.set_of("a") == se.set_of("a")
assert 20 < sum(se.set_of(str(i)) == "holdout" for i in range(100)) < 50, "about a third held out"
assert "ctx" not in se.mask("ran ctx search on x.jsonl, see #1234")
assert se.breaches([("Bash", "ls ~/.claude/projects/-Users-me-p", False)], "-work")
assert not se.breaches([("Bash", "ls ~/.claude/projects/-Users-me-p", True)], "-work"), "a refusal is no breach"
assert not se.breaches([("Glob", '{"path": "/h/.claude/projects/-work-A"}', False)], "-work"), "its own folder"

sys.dont_write_bytecode = True
body = 'we ran ctx and it worked\nBash {"command":"cd x; ~/.local/bin/ctx search a b | head -3"}\nBash {"command":"grep ctx file"}\nBash {"command":"A=1 ctx show 5"}'
assert se.ctx_calls(body) == [("search", ["a", "b"]), ("show", ["5"])], se.ctx_calls(body)
code = json.dumps({"command": "cat > x.go <<'EOF'\nctx context.Context\nfunc f(ctx interface{}) {}\nEOF\nctx turn 5"})
assert se.ctx_calls("Bash " + code) == [("turn", ["5"])], se.ctx_calls("Bash " + code)
assert se.ctx_calls('Bash {"command":"go test -run X(ctx context.Context)"}') == []

assert not se.breaches([("Bash", "cd /h/.ctx/eval/work/x/repos/C/p", False)], "-work"), "its own workspace"
assert se.breaches([("Read", "/h/.ctx/ctx.sqlite", False)], "-work"), "the live archive"

T = tempfile.mkdtemp()
LOG = f"{T}/log"
FAKE = f"{T}/fake"
with open(FAKE, "w") as f:
    f.write(f"""#!{sys.executable}
import json, os, re, sys
a = sys.argv
prompt = a[a.index("-p") + 1]
fmt = a[a.index("--output-format") + 1]
if "BLIND-GRADE" in prompt:
    answers = json.loads(prompt[prompt.index("ANSWERS:") + 8:])
    print(json.dumps({{"result": json.dumps([{{"answer_id": x["answer_id"],
        "grade": "correct" if "good" in x["answer"] else "wrong"}} for x in answers])}}))
    sys.exit(0)
with open({LOG!r}, "a") as f:
    f.write(json.dumps(dict(skill=os.path.exists(".claude/skills/ctx/SKILL.md"), db=os.environ.get("CTX_DB"),
        persist="--no-session-persistence" in a, prompt=prompt,
        extra=a[a.index("--append-system-prompt") + 1] if "--append-system-prompt" in a else None, hooks="disableAllHooks" in a[a.index("--settings") + 1])) + "\\n")
print(json.dumps({{"type": "assistant", "message": {{"content": [{{"type": "tool_use", "id": "1", "name": "Bash",
    "input": {{"command": "ctx search thing"}}}}]}}}}))
print(json.dumps({{"type": "result", "subtype": "success", "result": os.environ.get("ANSWER", "good answer"),
    "num_turns": 2, "duration_ms": 1000, "total_cost_usd": 0.01, "permission_denials": [],
    "usage": {{"input_tokens": 10, "output_tokens": 5, "cache_creation_input_tokens": int(os.environ.get("TOKENS", "100")),
    "cache_read_input_tokens": 7}}}}))
""")
os.chmod(FAKE, 0o755)
os.makedirs(f"{T}/repo/proj")
open(f"{T}/repo/proj/code.txt", "w").write("x\n")
skill = f"{T}/SKILL.md"
open(skill, "w").write("skill text\n")
se.write_json(se.BANK, {"projects": {"proj": {"repo": f"{T}/repo/proj", "sessions": f"{T}/repo/proj"}},
                        "questions": [{"id": i, "project": "proj", "kind": "fix", "question": f"what about {i}?",
                                       "answer": "it", "must_include": ["it"]} for i in ("a", "b", "c")]})
env = dict(os.environ, SKILL_EVAL_CLAUDE=FAKE, CTX=os.path.abspath(sys.argv[1]), CTX_DB=f"{T}/ctx.sqlite")
subprocess.run([env["CTX"], "init"], env=env, capture_output=True, check=True)  # never the real archive


def cli(*args, ok=True, **extra):
    p = subprocess.run([sys.executable, f"{HERE}/skill_eval.py", *args], env=dict(env, **extra), capture_output=True, text=True)
    assert (p.returncode == 0) == ok, f"{args}: exit {p.returncode}\n{p.stderr}{p.stdout}"
    return p.stdout


good = cli("run", "--set", "all", "--cond", "A,C", "--skill", skill, "--name", "good", "--jobs", "2").strip()
seen = [json.loads(x) for x in open(LOG)]
assert len(seen) == 6 and all(x["persist"] and x["hooks"] for x in seen), "isolated"
assert sum(x["skill"] for x in seen) == 3 and sum(bool(x["db"]) for x in seen) == 3, "only C gets the skill and archive"
assert not any(x["db"] and "/snap.sqlite" not in x["db"] for x in seen), "C reads the frozen copy"
assert not os.listdir(f"{se.HOME}/work"), "the workspace is removed"

cli("grade", good)
report = cli("report", good)
assert re.search(r"C: score 3\.0/3", report), report

bad = cli("run", "--set", "all", "--skill", skill, "--name", "bad", ANSWER="poor answer").strip()
cost = cli("run", "--set", "all", "--skill", skill, "--name", "cost", TOKENS="500").strip()
assert "FAIL: score dropped" in cli("compare", good, bad, ok=False)
assert "PASS" in cli("compare", bad, good)
assert "tokens rose" in cli("compare", good, cost, ok=False)
assert "ctx commands by agents" in cli("usage")
via = f"{T}/via.json"
json.dump({"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:1", "ANTHROPIC_DEFAULT_SONNET_MODEL": "cheap", "ANTHROPIC_AUTH_TOKEN": "s3cret"}}, open(via, "w"))
routed = subprocess.run([sys.executable, f"{HERE}/skill_eval.py", "--via", via, "--yolo", "run", "--set", "all", "--skill", skill, "--name", "routed"],
                        env=env, capture_output=True, text=True).stdout.strip()
meta = json.load(open(f"{routed}/meta.json"))
assert meta["yolo"] and meta["via"]["ANTHROPIC_DEFAULT_SONNET_MODEL"] == "cheap", meta
assert "s3cret" not in open(f"{routed}/meta.json").read(), "a token is never recorded"
mixed = subprocess.run([sys.executable, f"{HERE}/skill_eval.py", "compare", good, routed], env=env, capture_output=True, text=True)
assert mixed.returncode and "different models" in mixed.stderr, mixed.stderr
known = se.known_commands(os.path.abspath(sys.argv[1]))
assert {"wiki", "source", "project", "index", "sync", "remote", "rebuild", "search", "turn"} <= known, known
assert "nonsense" not in known
# Documents: S and W get the same tools; only W can find the wiki.
sw = cli("run", "--set", "all", "--cond", "S,W", "--skill", skill, "--name", "docs").strip()
rows = json.load(open(f"{sw}/runs.json"))
assert sorted(r["cond"] for r in rows) == ["S", "S", "S", "W", "W", "W"], rows
ri = cli("run", "--set", "all", "--cond", "I", "--skill", skill, "--name", "inj").strip()
assert all(r["cond"] == "I" and "injected" in r for r in json.load(open(f"{ri}/runs.json")))
rh = cli("run", "--set", "all", "--cond", "C,H", "--skill", skill, "--name", "hook").strip()
assert sorted(r["cond"] for r in json.load(open(f"{rh}/runs.json"))) == ["C", "C", "C", "H", "H", "H"], "the hook condition runs"
# Plain ask, condition R, --kind and reach.
mark = len(open(LOG).readlines())
STUB, RLOG = f"{T}/stubctx", f"{T}/recall.log"
with open(STUB, "w") as f:
    f.write(f"""#!{sys.executable}
import json, os, re, sys
if sys.argv[1] == "recall":
    with open({RLOG!r}, "a") as f:
        f.write(sys.stdin.read() + "\\n")
    if not os.environ.get("RECALL_EMPTY"):
        print(json.dumps({{"hookSpecificOutput": {{"hookEventName": "UserPromptSubmit", "additionalContext": "recalled text"}}}}))
elif sys.argv[1] == "sql":
    m = re.search(r"VACUUM INTO '(.*)'", sys.argv[2])
    if m:
        open(m.group(1), "w").close()
""")
os.chmod(STUB, 0o755)
rr = cli("run", "--set", "all", "--cond", "R", "--skill", skill, "--name", "recall", CTX=STUB).strip()
rows = json.load(open(f"{rr}/runs.json"))
new = [json.loads(x) for x in open(LOG)][mark:]
assert len(new) == 3 and all(r["cond"] == "R" and r["injected"] for r in rows), rows
assert all(x["extra"] == "recalled text" and x["skill"] and x["db"] for x in new), "R gets the skill, archive and hook text"
asked = [json.loads(x) for x in open(RLOG)]
assert sorted(x["prompt"] for x in asked) == ["what about a?", "what about b?", "what about c?"], asked
assert all(x["session_id"] == "eval" and x["cwd"] for x in asked), asked
open(RLOG, "w").close()
re_ = cli("run", "--set", "all", "--cond", "R", "--skill", skill, "--name", "recall-empty", CTX=STUB, RECALL_EMPTY="1").strip()
assert not any(r["injected"] for r in json.load(open(f"{re_}/runs.json"))), "no output, no injection"
cli("grade", rr)
rep_r = cli("report", rr)
assert "reached ctx 3/3 (100%)" in rep_r and "fired 3, reached 3 of them" in rep_r, rep_r
assert "fired" not in cli("report", good), "fired is for I, H and R"
pl = cli("run", "--set", "all", "--cond", "C", "--ask", "plain", "--skill", skill, "--name", "plain").strip()
new = [json.loads(x) for x in open(LOG)][mark + 3 + 3:]
assert sorted(x["prompt"] for x in new) == sorted(f"what about {i}?\n\nReply in under 120 words; if you do not know, say so rather than guessing." for i in "abc"), new
assert json.load(open(f"{pl}/meta.json"))["ask"] == "plain" and json.load(open(f"{good}/meta.json"))["ask"] == "teammate"
assert "past work" in open(LOG).read(), "teammate is still the default"
diff = subprocess.run([sys.executable, f"{HERE}/skill_eval.py", "compare", good, pl], env=env, capture_output=True, text=True)
assert diff.returncode and "different prompts" in diff.stderr, diff.stderr
old = f"{T}/noask"
shutil.copytree(good, old)
meta = json.load(open(f"{old}/meta.json"))
del meta["ask"]
json.dump(meta, open(f"{old}/meta.json", "w"))
assert "PASS" in cli("compare", old, good), "no ask recorded counts as teammate"
bank2 = f"{T}/bank2.json"
se.write_json(bank2, {"projects": {"proj": {"repo": f"{T}/repo/proj", "sessions": f"{T}/repo/proj"}},
                      "questions": [{"id": i, "project": "proj", "kind": k, "question": f"q {i}", "answer": "it", "must_include": ["it"]}
                                    for i, k in (("x", "code"), ("y", "fix"), ("z", "decision"))]})


def qids(*kind):
    r = cli("--bank", bank2, "run", "--set", "all", "--skill", skill, "--name", "kinds", *kind).strip()
    return sorted(r_["qid"] for r_ in json.load(open(f"{r}/runs.json")))


assert qids("--kind", "code") == ["x"] and qids("--kind", "code,fix") == ["x", "y"] and qids() == ["x", "y", "z"]
assert "--bank" in subprocess.run([sys.executable, f"{HERE}/skill_eval.py", "-h"], capture_output=True, text=True).stdout
print("eval tests passed")
