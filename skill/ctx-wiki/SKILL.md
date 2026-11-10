---
name: ctx-wiki
description: Compile or maintain a project's wiki from its version-pinned sources with ctx. Use when asked to compile a source into the wiki, write or update a wiki page, fix wiki citations, or work a ticket titled "Compile" or "Wiki:". Not for answering questions from past sessions; use the ctx skill for that.
---

# ctx-wiki

The wiki is Markdown pages compiled from immutable sources. Every claim must trace
back to a literal quote from an exact source version. `ctx wiki save` checks this
without a model and refuses a page that fails, so write for the gate.

## Before writing

```sh
ctx ticket claim ID             # if working from a ticket
ctx index                       # sources and pages at trunk
ctx wiki publish                # then read Wiki Index to see what already exists
```

Read each source completely. Prefer updating an existing page to adding one.
Pin citations to the trunk check-in: `ctx sql "SELECT fsl_open('repo:NAME'), fsl_use('repo:NAME'), fsl_resolve('trunk')"`, with hyphens in NAME written as underscores. Take the full hash from the last column.

## Page format

Write Markdown. Do not use Fossil wiki markup.

```markdown
# Cache design

The cache keeps entries for 30 seconds.[^ttl]

Synthesis: short lifetimes and nightly eviction keep the table small.[^ttl][^evict]

See [Eviction](/wiki?name=Eviction).

[^ttl]: "The cache TTL is 30 seconds." [design.md](/file?name=sources/design.md&ci=FULLHASH&txt=1)
[^evict]: "Evictions run nightly." [ops.md](/file?name=sources/ops.md&ci=FULLHASH&txt=1)
```

- Every paragraph or list item stating a claim needs a footnote marker.
- A footnote is exactly: marker, colon, the quote in straight double quotes, a space, then one link.
- Copy each quote character for character from the source. It may cross a line break, and must contain no `"`.
- Choose a short quote that really supports the claim. A quote that exists but says something else still passes the gate and is still wrong.
- A claim combining sources starts with `Synthesis:` and cites each source it uses.
- Cite sources, code, sessions and tickets of this project. Never cite a wiki page: links between pages are navigation only.
- Only link to pages that exist. Save the target first.
- Do not write `## Sources` or `## Provenance`. `ctx` generates them.
- Keep a page under 32 KB and to one topic.
- Do not state anything the sources do not say. Leave out what you cannot support.

## Saving

```sh
ctx wiki save "Page Name" draft.md --model MODEL [--ticket ID]
```

If it says `refused`, nothing was saved. Fix every line it lists and run it again.
Never weaken a claim's meaning, or find a loosely related quote, only to pass.

If `removed claim` appears, confirm you meant to drop that claim. Keep claims unless
the sources no longer support them.

## After saving

```sh
ctx wiki publish                # regenerates the index and health pages
ctx wiki check                  # must report 0 problems
ctx wiki why "Page Name"        # read it: does each quote support its claim?
ctx ticket done ID --result "Page Name"
```

## When a source changes

```sh
ctx wiki repin                  # moves claims whose quotes survive; tickets the rest
ctx wiki queue                  # stale knowledge, most depended-on first
```

For a ticket that says a claim lost its source, find current support and rewrite
the claim, or remove it if nothing supports it. Contradictions, removing claims,
and anything about security, money or law go to a person.
