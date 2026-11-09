#!/usr/bin/env python3
"""Tests skill_eval end to end with a stand-in for the model. usage: test_eval.py CTX"""
import json
import os
import re
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
        persist="--no-session-persistence" in a, hooks="disableAllHooks" in a[a.index("--settings") + 1])) + "\\n")
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
env = dict(os.environ, SKILL_EVAL_CLAUDE=FAKE, CTX=os.path.abspath(sys.argv[1]))


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
print("eval tests passed")
