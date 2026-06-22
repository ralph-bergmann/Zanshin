# Test Fixture Repos

Pre-built jj repository snapshots committed as `.tar.zst` archives. Tests extract them at runtime
via `test_helpers::extract_fixture(name)` — they are **never rebuilt** during `cargo test`.

## Available Fixtures

| Archive | Contents | Compressed size |
|---|---|---|
| `tiny-3-commits.tar.zst` | 3 linear commits, single author, fixed timestamps | < 50 KB |
| `medium-1k-commits.tar.zst` | 1 000 commits: 200 linear → 3 parallel branches (66 each) → merge → 601 linear; ~30 bookmarks | < 5 MB |
| `large-10k-commits.tar.zst` | 10 000 commits: 2 000 linear → 3 parallel branches (660 each) → merge → 6 019 linear; ~45 bookmarks | ~5 MB |

> **`large-10k` is opt-in:** it is *not* produced by `--all`. Generate it deliberately with
> `cargo xtask gen-fixture --size large` (drives the `bench_repo_state_large` decision benchmark,
> Story 3.11 / ADR-0002). Whether the archive is committed in-tree is a separate call — the
> generator (`xtask` `build_large`) is the reviewable recipe.

## Regenerating

```sh
cargo xtask gen-fixture --all
```

Archives are regenerated in `test-fixtures/repos/` and should be committed after verification.

## Format

Archives use **zstd level 19** compression (high ratio, paid once at generation time, never at test
time). The `tar` layout mirrors the jj workspace root — extracting to any temp directory gives a
valid, relocatable jj workspace with `.jj/` at its root.

## Why committed?

Committed fixtures give deterministic, reviewable diffs and let CI run tests without a `jj`
binary. The `test_helpers::extract_fixture` helper unpacks the archive into a fresh `TempDir`
for each test, ensuring isolation and automatic cleanup.

## Git attributes

`test-fixtures/**/*.tar.zst` is declared `binary` in `.gitattributes` so git never attempts
text diffs or line-ending conversion on these files.
