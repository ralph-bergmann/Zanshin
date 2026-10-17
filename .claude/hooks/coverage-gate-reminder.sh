#!/usr/bin/env bash
# Stop hook: remind the agent to run the quality gate when Rust/Dart source has
# changed since the last green `cargo make test` run.
#
# Tracked in git; registered in .claude/settings.json.
# It NEVER breaks the session: on any unexpected condition it exits 0 (silent).
#
# Logic:
#   * skip if jq is missing or this Stop is already a hook-triggered continuation
#     (stop_hook_active) — prevents loops, incl. when the gate genuinely fails;
#   * skip if no uncommitted .rs/.dart source (generated files excluded);
#   * skip if every changed source file is OLDER than target/gate/last-green
#     (the stamp a green `cargo make test` run writes last; the run only executes
#     the steps the change needs) — gate already ran;
#   * otherwise block once and tell the model to run `cargo make test`.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || exit 0

changed="$( { git diff --name-only -- '*.rs' '*.dart'; \
              git diff --cached --name-only -- '*.rs' '*.dart'; \
              git ls-files --others --exclude-standard -- '*.rs' '*.dart'; } 2>/dev/null \
            | sort -u \
            | grep -vE '(_generated\.rs|bindings\.dart|\.ffi_generated\.dart)$' || true )"
[ -z "$changed" ] && exit 0

marker="target/gate/last-green"
need=false
if [ ! -f "$marker" ]; then
    need=true
else
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -e "$f" ] && [ "$f" -nt "$marker" ]; then
            need=true
            break
        fi
    done <<< "$changed"
fi
[ "$need" = "true" ] || exit 0

jq -n '{
  decision: "block",
  reason: "Rust/Dart source changed since the last green gate run. Run `cargo make test` (it runs the steps the change needs, ending with the per-file coverage ratchet when Rust or zanshin_core changed) and make it pass before finishing. If coverage rose, commit the updated coverage-baseline.txt — never lower the baseline to pass; add tests. See docs/coverage.md."
}'
