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
