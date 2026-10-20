---
name: story-loop
description: Use when Ralph asks to work through one or more Zanshin stories unattended with bmad-build-auto — e.g. "/story-loop 11.1 11.2", "arbeite die Stories … ab", "lass die nächsten Stories laufen".
argument-hint: "<story-id> [<story-id> …]"
---

# Story loop

You orchestrate; `story-builder` subagents implement. Each story gets one story run and **at most one closing run** that works off the deferrals the story run left behind. A run whose spec ends with `followup_review_recommended: true` gets **follow-up review passes** until that flag is `false` (at most two per spec). **The full quality gate runs once, at the end of the loop** (Ralph, 2026-10-20): every run inside the loop verifies with targeted checks only (the gate rule below), and a red final gate gets fix-up runs. Open ledger items that name a story travel into that story's run as **inbound items**: build-auto never reads the ledger, so the story-run prompt is their only way in. You edit only bookkeeping (spec frontmatter, `deferred-work.md`), never code, and judge ledger items by their text — the story and closing runs verify them against the code.

Paths: specs, `deferred-work.md` ("the ledger") and `sprint-status.yaml` live in `_bmad-output/implementation-artifacts/`. "The spec" = the story run's spec/plan file (newer build-auto calls it a plan and ends with `built` instead of `done`).

## Preflight (once, while Ralph is still there)

1. `bmad-method:bmad-build-auto` (plugin `bmad-method@bmad`) is in this session's available-skills list — that exact name is what `story-builder` invokes. If it is missing or named differently, stop and tell Ralph — every `story-builder` would fail.
2. `git status --short` is empty and the branch is `main`.
3. The story ids come from the arguments, in that order. None given → ask Ralph which stories, then start.

From here on, never ask Ralph anything; collect questions for the final report.

## Per story

1. **Inbound items.** Search the ledger for open bullets (not struck), in any section, that name this story as the one to fix or settle them — by number (`11.3`, `Story 11.3`) or by its `sprint-status.yaml` key. Newer bullets say so in their Follow-up line; older ones have none, so read the whole bullet. Read every hit: a story named only as evidence or background (`epics.md Story 11.3 item 2`), or a longer number (`11.31`), is no inbound item. Leave out a bullet whose part for this story is only a decision for Ralph or a manual check (a running app, Ralph's real repo, hardware); it goes on Ralph's list. Number the rest I1, I2, …; when a bullet also names other stories, note which part is this story's.
2. **Story run.** Dispatch `story-builder` (`run_in_background: false`) with the story-run prompt below.
3. **Check the result** — the report is a claim, not proof. Take the spec path from the report, check the file exists, read its frontmatter `status` and run `git status --short`.
   - `done` / `built` and clean tree → step 4. A red targeted check in its verification notes goes into the final report; it does not stop the loop (the final gate catches it).
   - No final report, or the spec is still `in-progress` / `in-review` (rate limit, cut-off) → dispatch a fresh `story-builder` whose whole intent is the spec's path; build-auto resumes it. At most two resumes, then treat it as blocked.
   - `blocked` → no closing run; its inbound items stay open, untouched. Continue with the next story unless that story builds on this one (its `sprint-status.yaml` comment or epics.md text names it); then stop the loop and go to the final report.
4. **Close inbound items** — only when step 1 found some. The spec's `## Auto Run Result` lists each by its number:
   - fixed, while another story's part of the bullet is still open → as partly done.
   - fixed → strike its bullet: `~~**<title>**~~ — RESOLVED <date> (<spec slug>, commit <hash>): <one line>`. If the bullet sits under `## Surfaced in Story <x> …` and Story <x>'s spec still holds the matching `deferred:` item without `resolved:`, give that item `resolved: >-` `<date> — fixed (<spec slug>, commit <hash>): <one line>`.
   - rejected → same, with `REJECTED` / `rejected`, no commit, and the reason.
   - partly done → leave the bullet open and add the sub-bullet `- **<date>, Story <id>:** <what was done> (commit <hash>); left: <what remains>`.
   - not done, or missing from the Auto Run Result → leave the bullet open; its reason goes into the final report.

   Commit right away (`--no-gpg-sign`, the Co-Authored-By line from `.claude/agents/story-builder.md`, message `chore(ledger): close items handed to Story <id>`) — build-auto halts on a dirty tree.
4a. **Follow-up review** — only when the spec's frontmatter has `followup_review_recommended: true`. It runs after step 4 because a review pass rewrites `## Auto Run Result`, which step 4 reads. Dispatch `story-builder` with the follow-up prompt below; build-auto routes a `done` / `built` spec to a fresh review pass, which sets the flag again (on a follow-up pass `true` only if it patched a `high`). Check the result as in step 3 (status back at `done` / `built`, clean tree). Repeat while the flag is `true`, at most two passes per spec; still `true` after the second → the named risk goes into the final report. Deferrals a pass adds are collected in step 5 like the story run's.
5. **Collect** the spec's `deferred:` items without a `resolved:` field, each together with its ledger bullet (match by subject, title or body) under `## Surfaced in Story <id> (bmad-build-auto, …)`. Skip an item whose ledger bullet is already struck, and an inbound item the run deferred again (step 4 handled it). Add a missing bullet in the ledger-bullet shape below.
6. **Sort** each item into the first bucket that fits, in this order, reading its spec entry and its ledger bullet together (a condition in either one counts):
   - **record** — the ledger calls it a record, or its Follow-up is "none" in substance. No action.
   - **covered** — a later story that is not done yet names this same fix in its `sprint-status.yaml` comment or epics.md text. Note that story; partial overlap does not count. The bullet stays open until that story's run closes it as an inbound item; if the bullet's Follow-up line does not name that story, append ` Covered by Story <x>.` to it.
   - **closing run** — all of these hold:
     - it names a concrete defect, gap or missing test in this repo's code, tests or docs;
     - its text asks for no product or scope decision: no "decision for Ralph" / "Ralph decides", no options to choose between, no conditional follow-up ("if the gate time bites"), no CLI-behavior or API change to agree on;
     - it can be fixed and verified unattended — no manual check at a running app, no Ralph's real repo, no hardware;
     - its fix touches no agent-context or planning file (CLAUDE.md, AGENTS.md, `project-context.md`, `epic-*-context.md`, `epics.md`, ADRs, `sprint-status.yaml`, `decisions-review-*.md`).

     A severity marked `(unverified)` does not disqualify an item.
   - **handed on** — its text names one or more later stories that are not done yet as the ones to fix or settle it, and their part is more than a decision or a manual check by Ralph. Note those stories; the bullet stays open and each one's run gets it as an inbound item. A manual check or a decision for Ralph the item also asks for goes on Ralph's list.
   - **for Ralph** — everything else, with a one-phrase reason.

   If steps 5–6 changed the ledger, commit as in step 4, message `chore(ledger): mirror Story <id> deferrals`.
7. **Closing run** — only when step 6 put at least one item in the closing-run bucket. Dispatch `story-builder` with the closing-run prompt below. Never a closing run of a closing run.
8. **Close the books** — only after a closing run. Read its spec (the path from its report; check the file exists) and its `## Auto Run Result`, which lists every item's outcome:
   - fixed → origin spec item gets `resolved: >-` `<date> — fixed (<closing spec slug>, commit <hash>): <one line>`; its ledger bullet is struck: `~~**<title>**~~ — RESOLVED <date> (<closing spec slug>, commit <hash>): <one line>`.
   - rejected → same, with `rejected` / `REJECTED`, no commit, and the reason.
   - deferred by the closing run → leave origin item and ledger bullet open; it goes to Ralph.

   Commit as in step 4, message `chore(ledger): close Story <id> deferrals`.
8a. **Follow-up review of the closing run** — as step 4a, for the closing run's spec, after step 8 (same reason: a pass rewrites `## Auto Run Result`). Deferrals these passes add get no closing run; they go to Ralph.
9. Next story.

## Loop end: the one full gate

After the last story (also when the loop stopped early on a blocked story, as long as some run committed code):

1. **Run `cargo make test`** from this session — in the background (a full run takes longer than one foreground command), waiting for it with a Monitor; never from a subagent. Log to the scratchpad. It runs every step the loop's changes need, ending with the coverage ratchet.
   - `coverage` fails with "missing …/llvm-profdata" → rerun that step alone as `RUSTUP_HOME=$HOME/.rustup cargo make --allow-private coverage`, then `cargo make --allow-private gate-stamp` and `cargo make --allow-private gate-sweep`.
2. **Green** → if `coverage-baseline.txt` changed (the ratchet raises it), commit it: `chore(coverage): raise the baseline after the story loop <ids>`. Done.
3. **Red** → dispatch `story-builder` with the fix-up prompt below, quoting the failing steps and their error lines from the log (not the whole log). Check its result as in step 3 of "Per story", then rerun the gate (step 1). At most two fix-up runs; still red → stop, and the failures with the stories that likely caused them go to the top of Ralph's list.

## Gate rule (goes into every prompt the loop sends, except the fix-up prompt)

```text
Gate rule for this run (Ralph, 2026-10-20): do NOT run the full quality gate — no `cargo make test`,
`cargo make test-full` or `cargo make coverage`; the story loop runs it once after its last story. This
overrides CLAUDE.md's "the quality gate is the definition of done" and build-auto's gate steps for this
run. Verify with targeted checks instead, as far as the change reaches: `cargo test -p <crate>` (or
`--test <name>`; `zanshin-jj`/`zanshin-ffi` have one, `--test it <module>::`) for every touched crate and its dependents' affected tests, `cargo clippy -p <crate>
--all-targets -- -D warnings`, `cargo fmt --all --check`, `cargo make codegen` when the FFI or the schema
changed (commit what it generates), the parity oracle (`cargo test -p zanshin-parity --test oracle`) when a
jj verb changed, and `flutter test` / `dart analyze` / `dart format --set-exit-if-changed` for each touched
Dart package. Coverage is not measured here: still add the tests a new or changed line needs. Record every
check you ran and its outcome under the spec's verification notes.
```


## Ledger-bullet shape

Under a heading `## Surfaced in <Story <id> | the closing run of Story <id> | the follow-up review of Story <id>> (bmad-build-auto, <date>)`. If that section already exists, add to it; otherwise `<date>` is today:

```markdown
- **<one-sentence summary>.** <High|Medium|Low>.
  - <evidence, one or two lines; file:line where known>
  - **Follow-up:** <what would close it, or "none">
```

## Prompts

Never put a spec's path into a closing-run prompt or an inbound item: build-auto would treat it as the plan to resume and start a follow-up review of the finished story instead. The follow-up prompt is the one place where that is wanted. Quote the items in full instead, rewriting self-references ("this spec", "this story") and spec paths as "Story <id>'s spec" / "Story <id>".

Every prompt below except the fix-up prompt ends with the gate rule above, verbatim.

**Story run** — the block from `Also part of` to `or not done (why).` goes in only when step 1 found inbound items:

```text
Story <id> — <title> (sprint-status.yaml key <key>; epics.md Story <id>).

Also part of Story <id>: these open items in _bmad-output/implementation-artifacts/deferred-work.md name
Story <id> as the one to fix or settle them.

I1. <summary> <severity>. (deferred-work.md, section "<section heading>")
    <every evidence line of the bullet, in full>
    Follow-up: <the bullet's Follow-up line, if it has one>
    Story <id>'s part: <only when the bullet also names other stories>
I2. …

For each item: verify it against the code as Story <id> leaves it. Fix or settle it if it is real; reject it
with the reason if it is false or no longer applies; defer it only when it needs a decision from Ralph or a
story after Story <id> — do not mirror such an item into deferred-work.md again, it is already there. Under
`## Auto Run Result`, list every item by its number with its outcome: fixed (commit hash), rejected (reason),
partly done (what is left) or not done (why).

Extra rule for this run: mirror every item you add to the spec's `deferred:` list into
_bmad-output/implementation-artifacts/deferred-work.md, in the same commit as the spec, in this shape:
<the ledger-bullet shape above, with the heading for Story <id>>
```

**Closing run:**

```text
Closing run for Story <id>: work off exactly these items that Story <id>'s run deferred, nothing else. This is
new work with its own spec; Story <id>'s finished spec is not to be resumed or reviewed.

1. <summary>
   Location: <file:line or component, all of them>
   Severity: <the spec item's severity>
   Evidence: <the spec item's evidence, in full>
   Ledger follow-up: <the ledger bullet's Follow-up line>
2. …

For each item: verify it against the current code first. Fix it if it is real; reject it with the reason if it
is false or not worth the added complexity. Defer it only when the fix needs a product decision from Ralph —
do not mirror such an item into deferred-work.md again, it is already there. Change Story <id>'s code only as
far as an item needs. Under `## Auto Run Result`, list every item by its number with its outcome: fixed (commit
hash), rejected (reason) or deferred (what Ralph must decide).

Extra rule for this run: mirror every NEW finding you add to this run's `deferred:` list into
_bmad-output/implementation-artifacts/deferred-work.md, in the same commit as the spec, in this shape:
<the ledger-bullet shape above, with the heading for the closing run of Story <id>>
```

**Follow-up review:**

```text
<the spec's absolute path>

Follow-up review pass of Story <id>'s finished spec (or: of the closing run of Story <id>).

Extra rule for this run: mirror every item you add to the spec's `deferred:` list into
_bmad-output/implementation-artifacts/deferred-work.md, in the same commit as the spec, in this shape:
<the ledger-bullet shape above, with the heading for the follow-up review of Story <id>>
```

**Fix-up run** (after a red final gate; this run DOES run the full gate):

```text
Fix-up run after the story loop <ids>: make `cargo make test` green, nothing else. This is new work with its
own spec; no story's finished spec is to be resumed or reviewed.

Failing gate steps (from the loop's final `cargo make test`):
1. <step name>: <the error lines, in full>
   Likely from: Story <id> (<why>)
2. …

Fix each failure at its cause. A coverage regression is fixed by adding tests, never by lowering
coverage-baseline.txt or adding an exclude_prefix. Change only what a failure needs. Finish with a green
`cargo make test` (commit a raised coverage-baseline.txt with the fix). Under `## Auto Run Result`, list
every failure by its number with what fixed it (commit hash), or why it is still red.
```

## Final report

One block per story: final status and commits; inbound items counted as fixed / rejected / partly done / not done; deferred items counted as fixed / rejected / record / covered (with the story) / handed on (with the story) / for Ralph; follow-up review passes run (per spec) and their patched counts; a `followup_review_recommended: true` still set after the second pass, with its named risk. Then the final gate: green or red, its duration, the fix-up runs it needed and their commits, and a raised coverage baseline. Then one list of everything waiting for Ralph across all stories — the for-Ralph items with their reasons and ledger sections, the inbound bullets step 1 left out, inbound items not done for a reason Ralph must settle, manual checks of handed-on items, closing-run deferrals, and blocked conditions — merging items that ask Ralph for the same action.
