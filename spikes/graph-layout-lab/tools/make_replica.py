#!/usr/bin/env python3
"""Writes a git fast-import stream that copies a commit graph without any file content.

usage: make_replica.py <log.txt> <refs.txt> <head-hash> <out.stream> [--subjects]
  log.txt:  one commit per line, `%H%x1f%ct%x1f%at%x1f%P%x1f%an%x1f%s`, in --topo-order.
  refs.txt: `%(objectname) %(*objectname) %(refname)`.

Every commit is empty. Without --subjects a commit's subject is the first 7 characters of the
original hash, its author is "a" and ref names become neutral (main, master and trunk keep their
name, so jj still finds the trunk). With --subjects it keeps subject, author name and ref names.
No e-mail address is ever copied.
"""
import sys

log_path, refs_path, head, out_path = sys.argv[1:5]
subjects = "--subjects" in sys.argv[5:]
TRUNK_NAMES = ("main", "master", "trunk")

rows = []
with open(log_path, encoding="utf-8", errors="replace") as log:
    for line in log:
        parts = line.rstrip("\n").split("\x1f")
        if len(parts) == 6:
            rows.append(parts)
rows.reverse()  # parents first

mark = {row[0]: i + 1 for i, row in enumerate(rows)}

with open(out_path, "wb") as out:

    def w(text):
        out.write(text.encode("utf-8"))

    for h, ct, at, parents, author, subject in rows:
        name = author.replace("<", "").replace(">", "").strip() if subjects else ""
        name = name or "a"
        message = (subject if subjects else h[:7]).encode("utf-8")
        w("reset refs/replica/tmp\ncommit refs/replica/tmp\n")
        w(f"mark :{mark[h]}\n")
        w(f"author {name} <a@example.com> {at} +0000\n")
        w(f"committer {name} <a@example.com> {ct} +0000\n")
        w(f"data {len(message)}\n")
        out.write(message)
        w("\n")
        for k, p in enumerate(parents.split()):
            if p in mark:
                w(f"{'from' if k == 0 else 'merge'} :{mark[p]}\n")
        w("\n")

    n = 0
    for line in open(refs_path, encoding="utf-8", errors="replace"):
        parts = line.split()
        target = parts[1] if len(parts) == 3 else parts[0]
        ref = parts[-1]
        if ref.endswith("/HEAD") or target not in mark:
            continue
        n += 1
        leaf = ref.split("/")[-1]
        if subjects:
            new = ref
        elif ref.startswith("refs/heads/"):
            new = ref if leaf in TRUNK_NAMES and ref.count("/") == 2 else f"refs/heads/l{n}"
        elif ref.startswith("refs/remotes/"):
            remote = ref.split("/")[2]
            keep = leaf in TRUNK_NAMES and ref.count("/") == 3
            new = f"refs/remotes/{remote}/{leaf if keep else f'r{n}'}"
        else:
            new = f"refs/tags/t{n}"
        w(f"reset {new}\nfrom :{mark[target]}\n\n")

    if head in mark:
        w(f"reset refs/heads/head\nfrom :{mark[head]}\n\n")
    w("reset refs/replica/tmp\nfrom 0000000000000000000000000000000000000000\n\n")
