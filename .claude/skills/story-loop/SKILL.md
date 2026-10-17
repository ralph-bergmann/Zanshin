---
name: story-loop
description: Use when Ralph asks to work through one or more Zanshin stories unattended with bmad-build-auto — e.g. "/story-loop 11.1 11.2", "arbeite die Stories … ab", "lass die nächsten Stories laufen".
argument-hint: "<story-id> [<story-id> …]"
---

# Story loop

You orchestrate; `story-builder` subagents implement. Each story gets one story run and **at most one closing run** that works off the deferrals the story run left behind. You edit only bookkeeping (spec frontmatter, `deferred-work.md`), never code, and judge deferred items by their text — the closing run verifies them against the code.

Paths: specs, `deferred-work.md` ("the ledger") and `sprint-status.yaml` live in `_bmad-output/implementation-artifacts/`. "The spec" = the story run's spec/plan file (newer build-auto calls it a plan and ends with `built` instead of `done`).

## Preflight (once, while Ralph is still there)

1. `bmad-method:bmad-build-auto` (plugin `bmad-method@bmad`) is in this session's available-skills list — that exact name is what `story-builder` invokes. If it is missing or named differently, stop and tell Ralph — every `story-builder` would fail.
2. `git status --short` is empty and the branch is `main`.
3. The story ids come from the arguments, in that order. None given → ask Ralph which stories, then start.

From here on, never ask Ralph anything; collect questions for the final report.

## Per story

1. **Story run.** Dispatch `story-builder` (`run_in_background: false`) with the story-run prompt below.
2. **Check the result** — the report is a claim, not proof. Take the spec path from the report, check the file exists, read its frontmatter `status` and run `git status --short`.
   - `done` / `built` and clean tree → step 3. A red `cargo make test` in its verification notes goes into the final report; it does not stop the loop.
   - No final report, or the spec is still `in-progress` / `in-review` (rate limit, cut-off) → dispatch a fresh `story-builder` whose whole intent is the spec's path; build-auto resumes it. At most two resumes, then treat it as blocked.
   - `blocked` → no closing run. Continue with the next story unless that story builds on this one (its `sprint-status.yaml` comment or epics.md text names it); then stop the loop and go to the final report.
3. **Collect** the spec's `deferred:` items without a `resolved:` field, each together with its ledger bullet (match by subject, title or body) under `## Surfaced in Story <id> (bmad-build-auto, …)`. Skip an item whose ledger bullet is already struck. Add a missing bullet in the ledger-bullet shape below, then commit right away (`--no-gpg-sign`, the Co-Authored-By line from `.claude/agents/story-builder.md`, message `chore(ledger): mirror Story <id> deferrals`) — build-auto halts on a dirty tree.
4. **Sort** each item into the first bucket that fits, in this order, reading its spec entry and its ledger bullet together (a condition in either one counts):
   - **record** — the ledger calls it a record, or its Follow-up is "none" in substance. No action.
   - **covered** — a later story's `sprint-status.yaml` comment or epics.md text names this same fix. Note that story; partial overlap does not count.
   - **closing run** — all of these hold:
     - it names a concrete defect, gap or missing test in this repo's code, tests or docs;
     - its text asks for no product or scope decision: no "decision for Ralph" / "Ralph decides", no options to choose between, no conditional follow-up ("if the gate time bites"), no CLI-behavior or API change to agree on;
     - it can be fixed and verified unattended — no manual check at a running app, no Ralph's real repo, no hardware;
     - its fix touches no agent-context or planning file (CLAUDE.md, AGENTS.md, `project-context.md`, `epic-*-context.md`, `epics.md`, ADRs, `sprint-status.yaml`, `decisions-review-*.md`).

     A severity marked `(unverified)` does not disqualify an item.
   - **for Ralph** — everything else, with a one-phrase reason.
5. **Closing run** — only when step 4 put at least one item in the closing-run bucket. Dispatch `story-builder` with the closing-run prompt below. Never a closing run of a closing run.
6. **Close the books** — only after a closing run. Read its spec (the path from its report; check the file exists) and its `## Auto Run Result`, which lists every item's outcome:
   - fixed → origin spec item gets `resolved: >-` `<date> — fixed (<closing spec slug>, commit <hash>): <one line>`; its ledger bullet is struck: `~~**<title>**~~ — RESOLVED <date> (<closing spec slug>, commit <hash>): <one line>`.
   - rejected → same, with `rejected` / `REJECTED`, no commit, and the reason.
   - deferred by the closing run → leave origin item and ledger bullet open; it goes to Ralph.

   Commit as in step 3, message `chore(ledger): close Story <id> deferrals`.
7. Next story.

## Ledger-bullet shape

Under a heading `## Surfaced in <Story <id> | the closing run of Story <id>> (bmad-build-auto, <date>)`. If that section already exists, add to it; otherwise `<date>` is today:

```markdown
- **<one-sentence summary>.** <High|Medium|Low>.
  - <evidence, one or two lines; file:line where known>
  - **Follow-up:** <what would close it, or "none">
```

## Prompts

Never put the origin spec's path into a closing-run prompt: build-auto would treat it as the plan to resume and start a follow-up review of the finished story instead. Quote the items in full instead, rewriting self-references ("this spec", "this story") as "Story <id>'s spec" / "Story <id>".

**Story run:**

```text
Story <id> — <title> (sprint-status.yaml key <key>; epics.md Story <id>).

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

## Final report

One block per story: final status and commits; deferred items counted as fixed / rejected / record / covered (with the story) / for Ralph; `followup_review_recommended: true` if set — the loop runs no follow-up review pass. Then one list of everything waiting for Ralph across all stories — the for-Ralph items with their reasons and ledger sections, closing-run deferrals, and blocked conditions — merging items that ask Ralph for the same action.
