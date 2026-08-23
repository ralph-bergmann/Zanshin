# jj config reference — revset aliases (Story 4.9)

Reading list + verified source pointers. Doc links checked live 2026-08-23; source facts read at the pinned tag (`git -C ../jj show v0.42.0:<path>`) or in the vendored `jj-lib-0.42.0` crate.

## jj documentation (for reading up)

| Topic | Link |
| --- | --- |
| Revset aliases — how users define symbols/functions in config (incl. overloading by arity) | <https://docs.jj-vcs.dev/latest/revsets/#aliases> |
| Customizing `immutable_heads()` — the canonical override example (why this alias matters) | <https://docs.jj-vcs.dev/latest/config/#set-of-immutable-commits> |
| Config file locations & precedence — user files, `JJ_CONFIG`, repo config | <https://docs.jj-vcs.dev/latest/config/#user-config-files> |

Note: `/latest/` tracks jj's newest release, which may be ahead of our v0.42.0 pin — for contract questions the tag's sources below win.

## What a user can set (the story's subject)

```toml
[revset-aliases]
# Override a builtin: fork workflow — trunk is upstream, not origin
'trunk()' = 'main@upstream'

# Override the immutability rule (drives the ◆ flag, the default log view,
# and — Epic 9 — the rewrite guard)
'immutable_heads()' = 'builtin_immutable_heads() | remote_bookmarks()'

# Brand-new aliases, usable in any revset input
'mine()' = 'author(ralph@dasralph.de)'
'wip()' = 'description(glob:"wip:*")'
```

Builtin defaults these override (the layer 4-8 ships): `cli/src/config/revsets.toml` @ v0.42.0 — `trunk()`, `builtin_immutable_heads()` = `trunk() | tags() | untracked_remote_bookmarks()`, `immutable_heads()`, `immutable()` = `::(immutable_heads() | root())`, `mutable()`, `visible()`, `hidden()`.

## Config stack at v0.42.0 (precedence, low → high)

1. Builtin defaults (the CLI embeds its `config/*.toml`; Zanshin's equivalent is 4-8's builtin alias table + constants)
2. User config — platform file discovery; `JJ_CONFIG` (path to a TOML file **or a directory** of TOML files) replaces the discovery
3. Repo config — `.jj/repo/config.toml`, reached through the `.jj/repo` indirection (a FILE in secondary workspaces)
4. *(CLI only, not Zanshin:)* `--config`/`--config-file` command-line layer

## Source pointers (verify observable behavior here at build time)

| What | Where |
| --- | --- |
| Config machinery: `StackedConfig`, `ConfigLayer`, `ConfigSource` | vendored `jj-lib-0.42.0/src/config.rs` (structs at lines ~282/316/647) |
| File discovery order, `JJ_CONFIG` handling (`ConfigEnv`) | `cli/src/config.rs` @ v0.42.0 (replicate observable order; do not link CLI code) |
| Alias injection seam in Zanshin | `crates/zanshin-jj/src/revset.rs` — `build_aliases_map()` feeds `RevsetParseContext.aliases_map`; today `trunk()` only, 4-8 adds the builtin set, 4-9 layers config over it |
| Settings plumbing jj-lib expects (`UserSettings` wraps `StackedConfig`) | vendored `jj-lib-0.42.0/src/settings.rs` |

## Testing notes

- Inject test configs through the already-pinned `JJ_CONFIG` (suite property: never the developer's real config); repo-config cases write `.jj/repo/config.toml` into an extracted fixture copy.
- Assert both directions: override changes resolution (trunk-override flips `immutable` + default view) and absence of overrides reproduces 4-8's builtin behavior bit-identically.
- Malformed-config behavior is golden-tested against what the CLI observably does at the tag (error, not silent builtin fall-back).
