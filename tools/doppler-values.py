#!/usr/bin/env python3
"""Prints every Doppler secret value, one per line, for `ctx audit --known`.

  tools/doppler-values.py | ctx audit --known
  tools/doppler-values.py --name N     names the secret behind "line N" of a finding

Settings that are not secrets are left out by name, and plain words by shape,
since they match ordinary text. The order is stable between runs.
"""
import json
import re
import subprocess
import sys

NOT_SECRET = re.compile(r"(URL|URI|ORIGIN|ENDPOINT|BUCKET|MODEL|EMAIL|_FROM|_TO|PATH|USER|USERNAME|ENVIRONMENT|PROJECT_ID"
                        r"|DATASET|QUEUE|REGION|SPACE|CHAT_ID|AGENT|REMOTES|ACCOUNT_ID|ACCESS_KEY_ID|CLIENT_ID)$")


def doppler(*args):
    p = subprocess.run(["doppler", *args], capture_output=True, text=True)
    if p.returncode:
        sys.exit(p.stderr.strip())
    return json.loads(p.stdout)


def plain_word(value):
    return len(value) < 16 and value.isalpha()


def collect():
    found = {}
    for project in doppler("projects", "--json"):
        slug = project.get("slug") or project["id"]
        for config in doppler("configs", "-p", slug, "--json"):
            name = config["name"]
            for key, value in doppler("secrets", "download", "--no-file", "--format", "json", "-p", slug, "-c", name).items():
                if key.startswith("DOPPLER_") or NOT_SECRET.search(key):
                    continue
                for piece in str(value).splitlines():
                    if len(piece) >= 8 and not plain_word(piece):
                        found.setdefault(piece, f"{slug}/{name}/{key}")
    return sorted(found.items(), key=lambda kv: kv[1])


def main():
    items = collect()
    if len(sys.argv) == 3 and sys.argv[1] == "--name":
        print(items[int(sys.argv[2]) - 1][1])
        return
    for value, _ in items:
        print(value)


if __name__ == "__main__":
    main()
