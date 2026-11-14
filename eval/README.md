# Skill eval

Measures `skill/ctx/SKILL.md` against questions about past work, so changes to
the skill are judged by results. Needs `claude` and a real archive. Run it by
hand; CI only tests the harness, with a stand-in for the model.

Questions come from private sessions, so the bank and every result stay in
`~/.ctx/eval`, which only you can read. Nothing from there goes in this repo.

## The loop

1. **Find what to fix.** `eval/skill_eval.py usage` reads how agents really used
   `ctx`: commands that do not exist, searches with no matches, overlong
   queries. Note anything worth fixing.
2. **Turn a real failure into a question** when you can, by running `author`
   for that project.
3. **Change the skill** and iterate on the dev set:
   `run --set dev`, `grade`, `report`.
4. **Gate it on the held-out set**, using the old and new skill files:

   ```sh
   eval/skill_eval.py run --set holdout --skill OLD.md --name old
   eval/skill_eval.py run --set holdout --name new
   eval/skill_eval.py compare ~/.ctx/eval/runs/old ~/.ctx/eval/runs/new
   ```

   `compare` exits 1 if the score drops, wrong answers rise, or new tokens rise
   more than 15%. Land the change only if it passes, and do not edit the skill
   to fit a held-out question: that spends the held-out set.

A question's set comes from a hash of its id, one in three held out, so new
questions need no bookkeeping.

## What keeps it honest

- Each answer is a fresh headless process with hooks and session saving off, so
  runs cannot see each other or end up in the archive.
- The code and the archive are frozen copies, removed afterwards.
- Conditions: **A** the repo only, **B** grep over transcripts, **C** the skill.
  Only C has `ctx` or the skill. The skill is never mentioned in the prompt, so
  `report` also shows how often agents reach for it.
- `run --ask plain` asks the bare question, with no mention of past work or
  sources, so a run shows whether the agent reaches for `ctx` unprompted. The
  default, `teammate`, frames it as a question about past work. `compare`
  refuses runs with different `--ask` values. Condition B still lists its
  transcript folders in the prompt.
- Condition **M** offers ctx only as a Model Context Protocol server: `ctx mcp`
  with its two tools and a one-sentence note, with no skill and no `ctx` command.
  Its tool calls count as reaching ctx.
- A project in the bank may list `docs`: folders, relative to its repo, that are
  indexed with `ctx docs add` for every condition that has ctx. Condition **N** is
  C plus a one-sentence note that the repository's documents are indexed.
- Condition **P** is H plus a command run after every Grep or Bash call, as a
  PostToolUse hook would be; the command comes from `SKILL_EVAL_POSTTOOL`.
- Condition **Q** is the repo alone with `ctx` on the PATH, no skill and no note,
  plus the same command as P: what a hook does for an agent that was told nothing.
- Condition **G** is the repo alone with `ctx` on the PATH, plus a command run
  before every Grep, Glob or Bash call, as a PreToolUse hook would be; the command
  comes from `SKILL_EVAL_PRETOOL` and may turn a call back.
- Condition **J** is H plus what the UserPromptSubmit injection hook would add,
  joined into one note.
- Condition **R** is C plus what the UserPromptSubmit recall hook would add: it
  runs `ctx recall` on the question text and appends the output to the system
  prompt. I and H are the same idea with `ctx inject` and the SessionStart hook.
- `run --kind KIND[,KIND]` keeps only questions of those kinds. Questions of
  kind `code` can be answered from the code alone, so any `ctx` use on them is
  a false reach.
- Reach is the share of runs with at least one `ctx` call. `report` prints it
  per condition and, for I, H and R, how many runs had text injected and how
  many of those reached `ctx`. `compare` prints old and new reach; the gate
  does not use it.
- Runs that reached session history they should not have are voided.
- `compare` grades both runs in one shuffled pass with sources masked.
- `author` drafts questions, then a separate review pass checks each against
  the sessions and the code, and fixes or removes it.

## Adding a project

```sh
eval/skill_eval.py author --project NAME --repo PATH [--sessions PATH]
```

`NAME` is what `ctx` calls the project. `--sessions` is where sessions ran, if
`--repo` is a copy elsewhere.
