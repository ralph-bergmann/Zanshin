# Stack-titles spike: AI titles for commit stacks

A throwaway, **detached** spike (not part of the Cargo or Dart workspaces; `cargo make test`
skips `spikes/`) for the backlog idea Story 10.18 in `epics.md`: can Apple's on-device model
name what a collapsed commit stack contains, instead of showing the newest member's subject
(Story 10.17)?

The program reads a jj repo **read-only**: `jj --ignore-working-copy` takes no snapshot, imports
nothing and writes no operation. It groups linear runs into stacks with Story 4.13's run rule and
asks the on-device model for a title and a one- or two-sentence summary per stack. Nothing leaves
the Mac.

It writes a Markdown report, in German. Per stack it shows:
- what the card shows today (the newest member's subject);
- a label without AI (the most frequent ticket keys or conventional-commit scopes);
- the AI title and summary;
- the time and the input tokens of the model call;
- the members, newest first.

## Requirements

- macOS 26.4 or later on Apple silicon, with Apple Intelligence turned on (System Settings →
  Apple Intelligence & Siri). `tokenCount(for:)` needs 26.4.
- Xcode with a macOS 26.4 or later SDK (`xcrun swiftc`).
- `jj` on the `PATH`. Tested with jj 0.45.1; the template uses `escape_json()` and
  `working_copies`.

## Build and run

From `spikes/stack-titles/`:

```bash
mkdir -p build out
```

```bash
xcrun swiftc -O -target arm64-apple-macos26.4 stack_titles.swift -o build/stack-titles
```

```bash
build/stack-titles /path/to/a/jj/repo out/report.md
```

Progress goes to stderr: the commit and stack counts, the cold start, then every tenth stack.
103 stacks took about two minutes on an M4 Pro.

**A report holds the tested repo's commit subjects, change ids and author names.** `build/` and
`out/` are gitignored; never commit a report.

## What it computes

- **Revsets:** the configured default (`jj log` without `-r`, i.e. `revsets.log`) and `all()`.
- **Run rule** (4.13 item 1, the design's `groupStacks`): a candidate is neither the root nor a
  working copy and carries no bookmark or tag. It has exactly one parent, reached by a direct
  edge, and exactly one child edge. A run breaks where `immutable` changes; a run of at least 2
  is a stack.
- **Elided edges:** in the default revset they are computed without jj's transitive pruning. A
  commit may keep an extra edge there, so the default view's stack count is a lower bound.
- **Default state:** a stack of mutable ancestors of @ is flagged as starting expanded (4.13
  item 2).
- **Prompt:** the subjects newest first, capped at the newest 40. Greedy sampling, guardrails
  `permissiveContentTransformations`, and guided generation of `title` (at most about 6 words)
  and `summary`. Each stack gets a fresh session; identical prompts are asked once.

## Result 2026-09-28

A real 1.4k-commit client repo, on an M4 Pro with macOS 27 (context 8,192 tokens):

- **Default `jj log` view (12 commits): no stack.** `all()` gave 103 stacks, all immutable, with
  2 to 119 members (median 6).
- **Time per stack** (title and summary): median 1.06 s, p90 1.81 s, max 3.74 s. The input was
  84 tokens in the median, 604 at most. Cold start 1.0 s; all 103 took 132 s. No errors and no
  guardrail refusals.
- **Quality** (all 103 reviewed): the AI title was clearly more informative than the newest
  subject in about half the stacks, mostly those with 5 or more members. The rest were about
  equal. One title was misleading: it named the single feature commit of a stack whose other
  commits were tests and refactorings. No title invented a fact. "At most 6 words" was often
  ignored, and the casing varied.
- **The summaries** mostly re-listed the subjects and took most of the time.
- **The label without AI** mostly showed Jira keys in that repo: it names the ticket, not the
  content.

The conclusions and the recommendation are in `epics.md`, Story 10.18.
