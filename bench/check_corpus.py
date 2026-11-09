#!/usr/bin/env python3
"""Check that the labelled retrieval fixture is well formed."""
import json
import sys
from pathlib import Path

corpus = json.loads((Path(__file__).parent / "corpus.json").read_text(encoding="utf-8"))
doc_ids = [d["id"] for d in corpus["docs"]]
query_ids = [q["id"] for q in corpus["queries"]]
known = set(doc_ids)

errors = []
if len(known) != len(doc_ids):
    errors.append("duplicate document ids")
if len(set(query_ids)) != len(query_ids):
    errors.append("duplicate query ids")
for d in corpus["docs"]:
    if not d["text"].strip():
        errors.append(f"{d['id']}: empty text")
for q in corpus["queries"]:
    if not q["question"].strip():
        errors.append(f"{q['id']}: empty question")
    for expected in q["expected_ids"]:
        if expected not in known:
            errors.append(f"{q['id']}: unknown document {expected}")

if errors:
    sys.exit("\n".join(errors))
print(f"ok: {len(doc_ids)} documents, {len(query_ids)} queries")
