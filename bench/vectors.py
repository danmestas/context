#!/usr/bin/env python3
"""Would small static embeddings close the gap on paraphrased questions? A static model has
no network to run: each word piece has a fixed vector, and a text's vector is their
average. This scores the shipyard corpus three ways: ctx's keyword search, vectors alone,
and the two rankings fused. No model is called and nothing is sent anywhere.

  bench/vectors.py --models DIR [--model potion-base-8M ...]

DIR holds one folder per model with model.safetensors and tokenizer.json, fetched from
https://huggingface.co/minishlab/NAME (MIT). They are not in this repository. Needs numpy.
The first question set only: tuning-A is the questions that were never held out,
tuning-B the ones that were. The second set is not touched here.
"""
import argparse
import collections
import glob
import json
import math
import os
import re
import shutil
import struct
import sys
import tempfile
import time
import unicodedata

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shipyard as S

HERE = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(HERE, "shipyard")
MODELS = ""


class Static:
    def __init__(self, name):
        p = os.path.join(MODELS, name) + '/'
        f = open(p + 'model.safetensors', 'rb')
        n = struct.unpack('<Q', f.read(8))[0]
        h = json.loads(f.read(n))['embeddings']
        f.seek(8 + n + h['data_offsets'][0])
        self.E = np.frombuffer(f.read(h['data_offsets'][1] - h['data_offsets'][0]), dtype='<f4').reshape(h['shape'])
        self.vocab = json.load(open(p + 'tokenizer.json'))['model']['vocab']
        self.unk = self.vocab['[UNK]']

    def tokens(self, text):
        text = unicodedata.normalize('NFD', text.lower())
        text = ''.join(c for c in text if unicodedata.category(c) != 'Mn')
        out = []
        for w in re.findall(r"[^\W_]+|[^\w\s]|_", text):
            if len(w) > 100:
                out.append(self.unk)
                continue
            i, piece = 0, []
            while i < len(w):
                j = len(w)
                while j > i and (('##' if i else '') + w[i:j]) not in self.vocab:
                    j -= 1
                if j == i:
                    piece = [self.unk]
                    break
                piece.append(self.vocab[('##' if i else '') + w[i:j]])
                i = j
            out += piece
        return out

    def vec(self, ids):
        if not ids:
            return np.zeros(self.E.shape[1], dtype='f4')
        v = self.E[ids].mean(axis=0)
        n = np.linalg.norm(v)
        return v / n if n else v

    def windows(self, text, size=200, step=100):
        ids = self.tokens(text)
        if len(ids) <= size:
            return [self.vec(ids)]
        return [self.vec(ids[i:i + size]) for i in range(0, max(len(ids) - size, 0) + step, step)]




def rrf(*lists, k=60):
    """Reciprocal rank fusion: a session's score is the sum of 1/(k + rank) over the rankings."""
    score = collections.defaultdict(float)
    for l in lists:
        for r, s in enumerate(l):
            score[s] += 1.0 / (k + r + 1)
    return sorted(score, key=lambda s: -score[s])


def first_seen(order):
    got = []
    for s in order:
        if s not in got:
            got.append(s)
    return got


def strict(fn, qs, w):
    return sum(set(q["gold_sessions"]) <= set(fn(q[w])[:5]) for q in qs)


def sign_p(b, w):
    n = b + w
    return 1.0 if not n else min(1.0, 2 * sum(math.comb(n, k) for k in range(min(b, w) + 1)) / 2 ** n)


def main():
    global MODELS
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--model", action="append")
    a = ap.parse_args()
    MODELS = os.path.expanduser(a.models)
    sessions = {os.path.basename(p)[:-6]: p for p in sorted(glob.glob(D + "/sessions/*.jsonl"))}
    allq = json.load(open(D + "/questions.json"))
    dev = [q for q in allq if not S.held_out(q["id"])]
    old = [q for q in allq if S.held_out(q["id"])]
    work = tempfile.mkdtemp(prefix="vec-")
    try:
        env = dict(os.environ, CTX_DB=work + "/ctx.sqlite", HOME=work)
        bm25 = S.ctx_arm(sessions, work)
        import subprocess
        rows = subprocess.run([S.CTX, "sql", "SELECT json_object('s', cd.session, 'h', c.heading, 'b', c.body) FROM ctx_chunk c"
                               " JOIN ctx_doc d ON d.id = c.doc_id JOIN ctx_capture_day cd ON cd.technote = d.name"],
                              env=env, capture_output=True, text=True).stdout.splitlines()
        chunks = [json.loads(r) for r in rows]
        for name in a.model or ["potion-base-8M"]:
            m = Static(name)
            t = time.time()
            mat, owner = [], []
            for c in chunks:  # what people and agents wrote, in overlapping windows of 64 word pieces; tool output is left out
                if c["h"] not in ("user", "assistant"):
                    continue
                for v in m.windows(c["b"], 64, 32):
                    mat.append(v)
                    owner.append(c["s"])
            mat = np.array(mat, dtype="f4")
            took = time.time() - t
            vs = lambda q: first_seen(owner[i] for i in np.argsort(-(mat @ m.vec(m.tokens(q))))[:600])
            hy = lambda q: rrf(bm25(q), vs(q))
            print(f"{name}: {mat.shape[0]} vectors of {mat.shape[1]} numbers, {mat.nbytes // 1000} KB, embedded in {took:.1f} s")
            for label, fn in (("keywords only (ctx)", bm25), ("vectors only", vs), ("fused", hy)):
                r = [strict(fn, qs, w) for qs in (dev, old) for w in ("question", "paraphrase")]
                print(f"  {label:20} tuning-A own {r[0]}/{len(dev)} para {r[1]}/{len(dev)} | tuning-B own {r[2]}/{len(old)} para {r[3]}/{len(old)}")
            for w in ("question", "paraphrase"):
                x = {q["id"]: set(q["gold_sessions"]) <= set(hy(q[w])[:5]) for q in old}
                y = {q["id"]: set(q["gold_sessions"]) <= set(bm25(q[w])[:5]) for q in old}
                be, wo = sum(x[i] and not y[i] for i in x), sum(y[i] and not x[i] for i in x)
                print(f"  fused against keywords, tuning-B {w}: better {be}, worse {wo}, p={sign_p(be, wo):.3f}")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
