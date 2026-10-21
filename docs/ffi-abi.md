# FFI ABI Reference

Low-level contract between the Dart layer (`packages/zanshin_core`) and the
compiled Rust cdylib (`zanshin_ffi`). Implementors of new FFI wrappers must
read this document together with `ADR-0001` (FlatBuffers envelope transport)
and `docs/rust-error-codes.md`.

---

## Token contract

Every **fallible composite** `extern "C"` function returns a `*mut ZanshinBuf`
**token** — never null.

| Step | Actor                                     | Action                                                    |
|------|-------------------------------------------|-----------------------------------------------------------|
| Rust | writes heap bytes into `ZanshinBuf`       | returns the pointer as a token                            |
| Dart | calls `FfiBuffer.fromToken(token)`        | reads `.bytes` (a `Uint8List` copy)                       |
| Dart | calls `buf.dispose()` / `NativeFinalizer` | Rust frees the allocation via `zanshin_buffer_free_token` |

The Dart copy is isolated from Rust memory; it is safe to send across isolate
ports and use after disposal. *(2026-10-01, Story 4.12: `zanshin_graph_topology` is the
one exception — its envelope is read through the `FfiBuffer` view and copied once into a
`TransferableTypedData`, so it crosses the isolate boundary with ONE copy instead of the
two every other envelope costs; see § GraphTopology payload below.)*

**Infallible functions return plain types — no envelope.** There are ten:
`zanshin_ffi_version` (a `char *` the caller frees via `zanshin_string_free`),
`zanshin_network_token` (a `uint64_t`, Story 9.52) and the eight `void`-returning
ones — `zanshin_string_free`, `zanshin_buffer_free`, `zanshin_buffer_free_token`,
`zanshin_log`, `zanshin_logging_init`, `zanshin_events_register`,
`zanshin_events_unregister`, `zanshin_network_cancel` (Story 9.52).

The converse does **not** hold: returning an envelope does not make a function
fallible. `zanshin_diagnostics` returns a `ZanshinBuf *` token and is infallible
by contract (three compile-time constants plus one path resolution with a temp
fallback), so it carries no `# Errors` block and answers `ok == true` for every
input — the `internal.panic` backstop below is its only `ok == false` arm. It
is on the token path purely because its result is composite. "Infallible" in this
document means *has no `# Errors` block in `zanshin_ffi.h`* — eleven of the 72
exported symbols, these ten plus `zanshin_diagnostics`.

`zanshin_buffer_free_token` frees **two** allocations: the payload the token
points at, and the token struct itself. It skips the payload when `ptr` is null
**or** `len == 0`, and always frees the token struct. So a caller that released
the payload through the synchronous `zanshin_buffer_free(ptr, len)` path can
still hand the token back for disposal by first zeroing `token.ptr` /
`token.len` — that is the only supported way to mix the two halves without a
double free, and it is what
`packages/zanshin_core/test/ffi/buffer_free_test.dart` does. Production Dart
never mixes them: `FfiBuffer` always uses the token path.

---

## Envelope format

Every token carries a FlatBuffers `Envelope` root (schema: `schemas/envelope.fbs`):

```
Envelope {
  ok:           bool           // true = success; false = error
  error:        FfiError?      // non-null only when ok == false
  data_type:    Payload        // union discriminant (NONE when ok == false)
  data:         Payload        // union value (absent when ok == false)
  precondition: Precondition?  // the pre-verb snapshot's report (Story 9.26), ok OR error
  warnings:     [Warning]?     // the call's CLI warnings (Story 9.32), ok OR error
}

Warning { code: string; message: string; }
```

**Success:** `ok = true`, `data` holds the concrete payload variant.  
**Error:** `ok = false`, `error.code` holds the dotted AR-P-4 code, `error.context`
holds human-readable detail. See `docs/rust-error-codes.md` for the full registry.

### `warnings` — the CLI's `Warning:` blocks as coded facts (Story 9.32)

Every envelope-returning symbol may carry `Envelope.warnings`: the jj CLI @ v0.44.0's
`ui.warning_*` output for the same call, one `Warning` per CLI block, in the CLI's print
order (config-load warnings, the pre-verb snapshot and imports, the verb body,
`finish_transaction`). `code` is one of the registered `jj.*` warning codes
(`docs/rust-error-codes.md` § Warning Codes); `message` is the CLI's text, verbatim,
without the `Warning: ` heading and without hints. A warning never changes the
outcome: it rides the ok envelope AND the error envelope (a precondition that warned
before the verb refused keeps its warnings next to the error). The vector is
**absent** when there is nothing to warn about — every reader treats that as an empty
list — and never appears on `PANIC_FALLBACK_ENVELOPE`, whose bytes are unchanged.
Success without a caveat is `ok` with no warnings; there is no success code and no
severity. Config-load warnings are recorded once per call. On the Dart side every
`ZanshinWorker` / `RepoHandle` command result exposes them as `warnings`
(`List<ZanshinWarning>`), decoded by one shared helper — except `closeRepo` / `close`
(lifecycle) and `events` (a stream, not a command); a list result is a `WarnedList<E>`;
payloads nested in another payload carry none. The creations (Story 9.33) —
`zanshin_repo_init` / `_clone` / `_convert` — carry the creating call's warnings on the
`RepoHandle` ok envelope AND on every error envelope (including `watcher.io_error` after a
successful creation); in Dart `initRepo`, `cloneRepo` and `convert` return a
`CreatedRepoHandle` (a `RepoHandle` subtype, so existing callers compile unchanged)
exposing them as `warnings`; a refused creation throws `ZanshinFfiException` exposing them
as its `warnings` (e.g. `jj.clone_cleanup_failed`, which only an error envelope carries).
On every error envelope — handle-scoped, handle-less or creation — Dart reads the warnings
the same way: the thrown `ZanshinFfiException.warnings` (Story 9.35).
`zanshin_commit_contents` (Story 4.10) never carries the vector, on the ok or the error
envelope: the op-pinned read loads no config and runs no snapshot, so it has nothing to warn
about (Dart still returns a `WarnedList`, always empty).

**The start-up secure-config fix-up (Story 9.37).** At the start of every command the jj CLI
runs jj-lib's `SecureConfig::maybe_load_config` for the repo, then the workspace config
layer: a legacy `.jj/repo/config.toml` / `.jj/workspace-config.toml` is migrated into
`<config_dir>/jj/{repos,workspaces}/<id>/` (the legacy path becomes a symlink), a moved
repo's `metadata.binpb` is re-pointed, a copied repo's config is forked under a new id, a
missing secure directory is regenerated. Zanshin runs the very same function wherever it
plays a command's start-up — `zanshin_repo_open`, every symbol that runs the pre-verb
snapshot (see *`precondition`* below), and the `zanshin_config_*` wrappers given a
`workspace_root` (not the `gc` pair) — and its notices (`jj.config_migrated`,
`jj.config_copied`, `jj.config_regenerated`) are the call's FIRST warnings, on the ok AND
the error envelope. `zanshin_repo_open` answers like a creation: the `RepoHandle` ok
envelope, the refusal and a late `watcher.io_error` all carry them; in Dart `openRepo`
returns an `OpenedRepoHandle` (a `RepoHandle` subtype) exposing them as `warnings`. The
notices are one-shot — the next call finds nothing left to fix.

### `precondition` — the pre-verb snapshot, whenever it ran (Story 9.26)

Like every jj CLI command, every handle-scoped symbol except `zanshin_repo_close`,
`zanshin_log_defaults`, `zanshin_workspace_root`, `zanshin_commit_contents` (the
continuation of the topology call's `jj log`, Story 4.10) and
`zanshin_workspace_update_stale` (the recovery itself, see below) first runs the CLI's
`snapshot_impl`: under jj's own `git_import_export.lock` (colocated workspaces
only) it imports a moved Git HEAD (`import git head`), snapshots the working copy
into `@` (`snapshot working copy`), and imports the Git refs (`import git refs`) —
each an operation only when it changed something. So a READ can write
operations, exactly as `jj log` does. `zanshin_snapshot` runs it alone (the CLI's
`jj util snapshot`).

Whenever the verb's pre-verb snapshot ran, the envelope — ok **and** error —
carries the report in `Envelope.precondition`: the facts the CLI prints before a command runs
(`was_snapshot_taken`, the snapshot's untracked paths, the head/refs import
outcome and rebased counts, and the ref export failures as `finish`). The pure
notes — `@` was immutable, `.jjconflict` files present, a failed Git HEAD reset —
are not fields: they are `Envelope.warnings` (Story 9.32). On an error it is PARTIAL — every field
up to the failing step. The field is **absent** on every other symbol (open,
init, clone, detect, close, `zanshin_log_defaults`,
`zanshin_workspace_root`, `zanshin_commit_contents`, `zanshin_git_remote_changes` (Story 9.24), the infrastructure symbols, async events, and every
`zanshin_config_*` symbol but one) and whenever
the call was refused before the verb ran (`ffi.null_pointer`, `ffi.invalid_handle`,
a request buffer that fails validation). `zanshin_repo_convert` (Story 9.33) carries
the conversion's snapshot report — `jj git init`'s `maybe_snapshot` — iff that snapshot
started, on the ok and the error envelope (after a failure before the re-open it
describes state the rollback removed; a failed re-open or watcher arming leaves `.jj/`
in place); Dart exposes it as `CreatedRepoHandle.precondition`, never as
`lastPrecondition`, because a creation is not a verb on the handle — and a refused
conversion's as the thrown `ZanshinFfiException.precondition`. Every error envelope's
report reaches Dart that way (Story 9.35): the exception's `precondition` (`null` when
the envelope has none) — when a failed handle-scoped call's error envelope carries one,
the same report `RepoHandle.lastPrecondition` holds (one without a report leaves
`lastPrecondition` at the previous report while the exception's is `null`).
A failed pre-verb snapshot is `jj.stale_working_copy`, `jj.config_error` or
`jj.jj_lib_error`; every such symbol's row names all three. Before it, every such verb
builds the CLI's start-up environment in the CLI's order (fileset, revset and template
aliases, `immutable_heads()`, `revsets.short-prefixes`; Story 9.51's closing run): a
broken one is `jj.config_error` with nothing written, whether or not the verb renders a
template.

With `snapshot.auto-update-stale = true` (Story 9.23) a stale working copy is not refused:
the pre-verb snapshot runs the stale-working-copy recovery under its lock, reports it in
`Precondition.stale_recovery` (the facts the CLI prints ahead of the verb's output) and the
verb runs on the recovered state; a concurrent writer caught by that recovery is
`jj.concurrent_working_copy`. `zanshin_workspace_update_stale` runs the same recovery
explicitly and no pre-verb snapshot: its envelope's `precondition` is the recovery's
TRAILING snapshot report (the conversion precedent), on the ok and the error envelope.

`zanshin_config_set` (Story 9.28) is handle-less but runs the snapshot for
`user.name` / `user.email` with a workspace root — the CLI's `check_wc_author`,
whose failure it skips silently. Its envelope, ok or error, carries
`precondition` exactly when that snapshot ran — in Dart `ConfigSetResult.precondition`
on success, the thrown `ZanshinFfiException.precondition` on error (Story 9.35).

Every mutation whose CLI verb ends in `tx.finish` (all but `zanshin_file_track` /
`_untrack`, which the CLI commits through the locked working copy) likewise runs the
CLI's `finish_transaction`: in a
colocated workspace it resets Git HEAD to `@`'s parent and exports the refs, and
if `@` became immutable it creates a new `@` on top. The refs the export could not
write ride `MutationResult.finish` (absent when none failed); `@` becoming immutable,
a failed HEAD reset, the export failures themselves and an empty identity are
`Envelope.warnings` (Story 9.32).

`Payload` has **41** members. Two of them — `WatcherEvent` and `Progress` — are
returned by no exported symbol: they arrive asynchronously through the
`zanshin_events_register` callback (see *Async events* below). Union member order
is the wire discriminant, so the union is **append-only**.

### `internal.panic` — the universal backstop

Every fallible wrapper's body runs inside `envelope::catch`, a `catch_unwind`
that turns any Rust panic into an ordinary error envelope carrying
**`internal.panic`** with the panic message in `context`. Because it is universal
it is documented **only here**: it appears in no symbol's `# Errors` block and
therefore in no row of the symbol index below. Assume it for every symbol that
returns an envelope, including the otherwise-infallible `zanshin_diagnostics` —
that is the one way such a symbol can answer `ok == false`.

The backstop relies on the crate being built with `panic = "unwind"` (the
workspace default); under `panic = "abort"` `catch_unwind` cannot intercept at
all (`crates/zanshin-ffi/src/envelope.rs:499-502`).

**Coverage is not universal across the `void`-returning symbols.** Four of the
seven are wrapped and swallow a panic, having no channel to report on:
`zanshin_log` and `zanshin_logging_init` (`crates/zanshin-ffi/src/logging.rs`)
and `zanshin_events_register` / `_unregister`
(`crates/zanshin-ffi/src/events.rs`) — for `zanshin_log` deliberately, since
logging must never break its caller. The three deallocators —
`zanshin_string_free`, `zanshin_buffer_free`, `zanshin_buffer_free_token`
(`crates/zanshin-ffi/src/ffi_strings.rs`) — carry **no** `catch_unwind`, so a
panic in them would unwind across the C ABI. Their bodies are pointer-validity
checks plus a `drop`, which is why nothing was added; do not read the backstop as
a blanket guarantee that no panic ever crosses the boundary.

---

## Request-buffer contract

Forty of the 75 exported symbols take their arguments as a **FlatBuffers
request buffer** — the ADR-0001 composite-input pattern — rather than as C
strings. Twenty-eight use the handle-scoped three-parameter shape:

```c
ZanshinBuf* zanshin_<verb>(uint64_t handle, const uint8_t* data, uintptr_t len);
```

The nine `zanshin_config_*` symbols (Story 9.28) use the **handle-less
two-parameter shape**, every input — the workspace root included — inside the
request table (`workspace_root` absent = no workspace, the CLI run without `-R`):

```c
ZanshinBuf* zanshin_config_<verb>(const uint8_t* data, uintptr_t len);
```

They are handle-less on purpose: a stack only the workspace LOAD refuses (a
wrong-typed `git.*` key) makes `zanshin_repo_open` fail, and the config verbs are
how the user repairs it — exactly as the CLI's config commands never load the
workspace. With a `workspace_root`, every one of them but the `gc` pair still starts
like a CLI command (Story 9.37): the secure-config fix-up runs for the repo, then the
workspace layer — inside the start-up stack load, or ALONE for the two `edit` halves,
which load no stack — so a legacy repo config is migrated (a copied repo's config
forked, a missing secure directory regenerated) even by a call that then refuses, and
its `jj.config_migrated` / `jj.config_copied` / `jj.config_regenerated` notices are the
envelope's first warnings, ok or error.

`zanshin_environment_adopt` (Story 9.36) uses the same two-parameter shape: the app
calls it once at start-up, before any worker or repo exists, so there is no handle to
pass — and, being handle-less and cheap (Rust only stores the map), it is called on the
app's main isolate, not through the worker.

This section is the whole convention. The per-symbol rustdoc in
`crates/zanshin-ffi/include/zanshin_ffi.h` does not repeat it.

### Building the buffer (Dart side)

Dart builds the table with the flatc-generated object builder and hands the bytes
to `withRequestBytes` (`packages/zanshin_core/lib/src/ffi/request_bytes.dart:46-54`),
which `malloc`-copies them, calls the wrapper, and frees the pointer in a
`finally`. `callWithRequest` (`:110-113`) composes that with `readToken` for the
common call-and-decode shape:

```dart
// packages/zanshin_core/lib/src/ffi/commit_views.dart:59
final Uint8List request = fbs.ShowRequestObjectBuilder(revset: revset, ...).toBytes();
return callWithRequest(request, (ptr, len) => zanshin_show(rawHandle, ptr, len));
```

**Ownership is the AR-P-5 *inbound* rule: Dart allocates AND frees; Rust only
borrows for the duration of the call.** That is the exact **reverse** of the
outbound token rule above, where Rust allocates and Dart releases the allocation
through `zanshin_buffer_free_token`. The two directions never mix: a request
buffer is never freed Rust-side, and a returned token is never freed by `malloc`.

An empty buffer is deliberately **not** collapsed to `nullptr`
(`request_bytes.dart:40-45`). Every caller passes a finished FlatBuffers buffer,
which always carries at least a root offset and a vtable — but if a zero-length
buffer ever did arrive, passing `nullptr` instead would change the observable
answer to `ffi.null_pointer`, which is a different refusal.

### Reading the buffer (Rust side) — the refusal ladder

All thirty wrappers share one reader shape (worked example:
`crates/zanshin-ffi/src/commit_views.rs:82-98`, whose module banner at `:51-56`
carries the SAFETY argument for the unbounded lifetime
`std::slice::from_raw_parts` produces — each reader builds its own slice in its
own scope and returns an OWNED struct, so the slice provably cannot outlive the
call). Five distinct refusals sit at five distinct layers:

| Order | Check | Code | `context` |
|-------|-------|------|-----------|
| 1 | `reject_null_request(data)` — `envelope.rs:183-191` | `ffi.null_pointer` | **absent** |
| 2 | `flatbuffers::root_with_opts::<fbs::X>(…)` verification — `envelope.rs:194-199` | `ffi.invalid_argument` | the flatbuffers verifier message |
| 3 | `expect_request_kind(req.kind(), …)` — the buffer was built for THIS wrapper | `ffi.invalid_argument` | `request kind mismatch: expected <K>, got <K>` |
| 4 | a required field is ABSENT from an otherwise valid table | `jj.invalid_input` | the field name |
| 5 | `session_from_handle(handle)` — the handle is `0` or the borrow yields `None` | `ffi.invalid_handle` | **absent** |

The two-parameter `zanshin_config_*` shape has rows 1–4 and **no row 5**: after the
required fields (row 4 there also refuses `ConfigScope::Unspecified` where a scope
is required, and `zanshin_config_list`'s scope-plus-`include_defaults` conflict)
come the verb's own codes. `zanshin_environment_adopt` has rows 1–4 and nothing after
them: row 4 refuses an absent or EMPTY `variables` vector (an empty environment is never
a login shell's — `variables is required`) and an entry whose `name` is absent or empty
(`variables[<i>].name is required`); an absent `value` is the empty value. A login shell
that could not be read never reaches Rust: the Dart reader reports it itself.

Row 4 is the *reader's* own required-field guard, which among the handle-taking
readers only seven have (`file annotate`'s `path`, `file search`'s `pattern`, `git remote add`'s `name`
and `url`, `git remote set-url`'s `name`, `interdiff`'s `from.id` / `to.id` — the
`id` inside a present `RevisionRef` union arm — since Story 4.10 `commit contents`'s
`operation_id`, and since Story 4.12 `graph topology`'s `revset`, `prioritize` and
`short_prefixes`), plus the `zanshin_config_*` readers
above (`name`, `value`, `path`, `text`, a required scope) and the
`zanshin_environment_adopt` reader (`variables`, each entry's `name`). `interdiff`'s "at least one of from or to" refusal is
*not* row 4: an absent side is a legal value there, and the pair is judged by the
jj layer after row 5. Refusals raised further in — an empty `names` vector, an
unparseable pattern, a malformed commit-id prefix — likewise come from the jj
layer and land AFTER row 5. The per-symbol `# Errors` bullets in
`zanshin_ffi.h` are an inventory, not an evaluation order; this table is the
order.

`InterdiffRequest`'s two `RevisionRef` unions add one refusal *shape* to row 2:
a union occupies two vtable slots (discriminant + value) and
`Verifier::visit_union` requires them present or absent **together**, so a
half-written union is an inconsistent-union failure at row 2 rather than
anything the reader ever sees. An out-of-**range** discriminant byte does verify
— a union tag is range-checked no more than a plain enum is — and is refused by
the reader, as `ffi.invalid_argument` naming the tag.

A **zero-length or garbage buffer** fails verification, so it lands on
`ffi.invalid_argument` — never on `ffi.null_pointer`. Only a genuinely null
`data` pointer produces `ffi.null_pointer`.

**The whole request buffer is judged before the handle is borrowed.** Every one
of the twenty handle-scoped wrappers calls its reader BEFORE `session_from_handle`, so rows 1
through 4 all precede row 5. That order is deliberate: a buffer built for the
wrong verb has to be refused on its own merits, not only when the caller happens
to hold a live handle. The only callers that see a different answer than they
would have before the tag landed are those that get BOTH wrong at once — a
malformed, mis-tagged or incomplete buffer together with a dead handle.

**The ladder starts only once `len` is honest.** `len` must describe exactly the
bytes readable at `data`; the reader builds its slice with
`std::slice::from_raw_parts(data, len)` before any verification runs, so a `len`
larger than the allocation is an out-of-bounds read — undefined behaviour, not a
refusal, and no ladder row covers it. That obligation is the caller's, and it is
repeated in every one of the thirty symbols' `# Safety` blocks.

Layer 4 is a different question from layer 2: the buffer verified, but the *table*
does not carry a field the verb requires. ABSENCE is meaningful throughout —
across these tables an absent field is the wire form of "the user did not supply
it", which is what applies the CLI's own default (`@` for a revision, `mutable()`
for `absorb`'s `into`, the current workspace for `workspace root`). An explicitly
present **empty string is a VALUE, not an absence**, and takes the value path.

### Interior NUL

A FlatBuffers string is length-prefixed, so a NUL survives the wire and would
land inside a jj change id, path, pattern, bookmark name or remote URL. It is
rejected **Dart-side, at two layers**:

- `rejectInteriorNul` / `rejectInteriorNuls`
  (`request_bytes.dart:56-73`, `:81-85`) throw an `ArgumentError` — the
  direct-caller backstop.
- The **primary** guard sits one layer up, on the calling side in `ZanshinWorker`
  and `RepoHandle`, because a throw inside the worker isolate comes back as
  `internal.dispatch_error` rather than as the documented `ArgumentError`.

The check is deliberately spelled at both layers for that reason.

**Rust does not re-check.** There is no `reject_interior_nul` beside
`reject_null_request`: both enforcement layers are Dart-side, so a caller that
bypasses the generated adapters can put a NUL into a request string and it will
reach jj-lib. The guard is the adapter, not the wrapper. (The `RequestKind` tag
below is guarded on BOTH sides for the opposite reason: mis-routing a buffer is a
wire-level hazard, not a value-level one.)

### The request tables

`schemas/envelope.fbs` declares **38** request tables. They are **not** members of
the `Payload` union (that union is response-only). Field order IS the wire
contract: field ids are assigned by declaration order and baked into both
committed codegen sides. `kind` is **always field 0**; any other change to a
request table's field order is an in-place WIP edit that MUST regenerate BOTH
committed codegen sides in the same commit.

Two tables are shared by two symbols each: `ChangeIdList` (`zanshin_new_change`'s
`parents` and `zanshin_abandon`'s `change_ids`; its `insert_after` / `insert_before`
lists — `jj new -A` / `-B`, Story 9.48 — are read only by `zanshin_new_change`,
`zanshin_abandon` ignores them) and `SquashRequest`
(`zanshin_squash` and `zanshin_squash_plan`, Story 9.15 — the plan previews the
squash its caller is about to run, with the same arguments). Every other table has
exactly one caller, and no table is orphaned. 38 tables + 2 shared reuses = the 40
request-buffer symbols (Story 9.20 adds `GitPushRequest`, `RepoCloneRequest` and
`RepoInitRequest` — `zanshin_repo_init` / `zanshin_repo_clone` took two C strings / a string and
an `int32_t` backend before; Story 9.30 adds `GitFetchRequest` — `zanshin_git_fetch` took a
remote name and a cancel token before; Story 9.31 adds `DropActionsRequest`).

`ChangeIdRef` and `CommitIdRef` are **not** in that count. They are the two
members of the `RevisionRef` union carried by `InterdiffRequest`'s `from`/`to`,
so they are nested values, never a buffer root: nothing verifies them
standalone, and they carry no `kind` tag of their own — the tag belongs to the
request table that owns them. `EnvironmentVariable` (Story 9.36) is the same kind of
nested helper: the entries of `EnvironmentAdoptRequest`'s `variables` vector, `name` and
`value` as `[ubyte]` because an environment is not guaranteed UTF-8. `DropLocation` (Story 9.31) is one
too: the entries of `DropActionsRequest`'s `locations` vector.

#### The `RequestKind` tag

Nothing in the FlatBuffers layer tells one request table from another: a buffer
built for one verb verifies as another verb's table, because none carries a
`file_identifier` and several put one string in the same slot. Field 0 of every
request table is therefore `kind: RequestKind`, and every reader refuses a buffer
whose tag is not its own — row 3 of the ladder above, before any other field is
read and before the handle is borrowed.

The tag is per-**wrapper**, not per-table. For 36 tables the variant name plus
`Request` is the table name; `ChangeIdList` carries **two** kinds, `NewChange`
and `Abandon`, because a per-table tag would have left the sharpest collision
unrefused — a buffer meant as `parents` abandoning those commits instead. Only
`NewChange` reads the table's `insert_after` / `insert_before` (Story 9.48).
`SquashRequest` is the one deliberate exception: both of its wrappers accept the
single kind `Squash`, because a mis-routed buffer can only run or preview the SAME
squash — never a different verb. Its `edited_description` (Story 9.54) is read by both:
`zanshin_squash` writes it, `zanshin_squash_plan` only refuses it together with `message`
and otherwise ignores it.

`Unspecified = 0` is FlatBuffers' default for an absent field, so a buffer built
by a producer that never sets `kind` is **byte-identical to a pre-tag buffer**,
decodes as `Unspecified`, and is always refused. "Legacy buffer" and "forgotten
tag" are the same, always-refused state; nothing untagged is ever accepted as any
verb. The tag is caller-supplied data and is never trusted: a byte outside the
enum verifies (FlatBuffers range-checks no enum scalar) and is refused by the
same rung, printing as `got <UNKNOWN n>`.

Member order in `RequestKind` IS the wire value — it is append-only, like the
tables it tags.

The tag guards the **wire**, not the caller: a caller bypassing the generated
adapters can still set it by hand. What it removes is the silent
mis-**execution** — a mis-routed buffer is now a refusal.

This closes the former "request tables verify interchangeably" caveat, one of the
cross-cutting must-haves on the central ledger,
`_bmad-output/implementation-artifacts/deferred-work.md` (others there remain
open).

---

## RepoKind enum

Used by `zanshin_repo_detect` and its `RepoDetect` payload.

| Variant        | Value | Meaning                                                |
|----------------|-------|--------------------------------------------------------|
| `Jj`           | 0     | Path is a jj workspace (`.jj/` present).               |
| `Git`          | 1     | Path is a plain Git repo (`.git/` present, no `.jj/`). |
| `Neither`      | 2     | Path exists but contains neither.                      |
| `PathNotFound` | 3     | Path does not exist on disk.                           |

Order must stay identical to `zanshin_jj::RepoKind` and `fbs::RepoKind`
(generated from `schemas/envelope.fbs`).

---

## Symbol index

The cdylib exports **75** `extern "C"` functions. Every one has a row here; the
list is derived from `crates/zanshin-ffi/include/zanshin_ffi.h` and kept in sync
by `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs`, which fails if a header symbol
appears in neither a heading nor a first table cell of this file.

**The header rustdoc is authoritative for each code's CONDITION** — when a code
fires, what lands in `context`, which argument it blames. This index only *names*
the codes a symbol can return; read `zanshin_ffi.h`'s `# Errors` block for that
symbol to learn why. `internal.panic` is documented once under *Envelope format*
and is deliberately absent from every row.

Rows are grouped by noun: repository lifecycle, repo-state reads, commit views,
file reads, refs and workspaces, change mutations, bookmarks, working-copy tracking
and snapshot, git sync, config (Story 9.28), the start-up environment (Story 9.36), and
infrastructure. `—` means "not applicable": no request table, no success payload,
or no `# Errors` block.

| Symbol | Args | Request table | Success payload | Error codes | Story |
|--------|------|---------------|-----------------|-------------|-------|
| `zanshin_repo_open` | `(const char *path)` | — | `RepoHandle` | `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `ffi.null_pointer`, `ffi.utf8_error`, `watcher.io_error` | 3.4a (+9.37) |
| `zanshin_repo_init` | `(const uint8_t *data, uintptr_t len)` | `RepoInitRequest` | `RepoHandle` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.jj_lib_error`, `jj.git_repo_exists`, `jj.already_jj_repo`, `jj.convert_failed`, `jj.config_error`, `watcher.io_error` | 3.4a (+9.33, 9.20) |
| `zanshin_repo_clone` | `(const uint8_t *data, uintptr_t len)` | `RepoCloneRequest` (+ `cancel_token`, see § Cancel) | `RepoHandle` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.destination_not_empty`, `jj.network_error`, `jj.cancelled`, `jj.jj_lib_error`, `jj.config_error`, `watcher.io_error` | 3.4a (+9.33, 9.20, 9.20 closing run, 9.52; `Progress`: 9.20) |
| `zanshin_repo_convert` | `(const char *path)` | — | `RepoHandle` | `jj.already_jj_repo`, `jj.not_a_git_repo`, `jj.convert_failed`, `jj.config_error`, `ffi.null_pointer`, `ffi.utf8_error`, `watcher.io_error` | 3.4c (+9.33) |
| `zanshin_repo_detect` | `(const char *path)` | — | `RepoDetect` | `jj.detect_failed`, `ffi.null_pointer`, `ffi.utf8_error` | 3.4c |
| `zanshin_repo_close` | `(uint64_t handle)` | — | — (no-payload success) | `ffi.invalid_handle` | 3.4a |
| `zanshin_status` | `(uint64_t handle)` | — | `Status` | `ffi.invalid_handle`, `jj.no_working_copy`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 3.4b |
| `zanshin_change` | `(uint64_t handle, const char *change_id)` | — | `Change` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.change_not_found`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 3.4b |
| `zanshin_op_log` | `(uint64_t handle, int64_t limit)` | — | `OpLog` | `ffi.invalid_handle`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 3.4b |
| `zanshin_log_defaults` | `(uint64_t handle)` | — | `LogDefaults` | `ffi.invalid_handle`, `jj.config_error` | 4.9 |
| `zanshin_graph_topology` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `GraphTopologyRequest` | `GraphTopology` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.stale_working_copy`, `jj.config_error`, `jj.jj_lib_error`, `graph.dangling_edge` | 4.12 |
| `zanshin_commit_contents` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `CommitContentsRequest` | `CommitContents` (no `precondition`, no `warnings`) | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.operation_not_found`, `jj.change_not_found`, `jj.jj_lib_error` | 4.10 |
| `zanshin_show` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `ShowRequest` | `ShowView` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.6 |
| `zanshin_evolog` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `EvologRequest` | `EvologView` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.6 |
| `zanshin_interdiff` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `InterdiffRequest` | `InterdiffView` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.revset_resolution_error`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.6 |
| `zanshin_file_list` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileListRequest` | `FileList` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.change_not_found`, `jj.invalid_input`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.4 |
| `zanshin_file_show` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileShowRequest` | `FileContents` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.path_not_found`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.4 |
| `zanshin_file_annotate` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileAnnotateRequest` | `FileAnnotation` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.change_not_found`, `jj.invalid_input`, `jj.path_not_found`, `jj.not_a_file`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.4 |
| `zanshin_file_search` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileSearchRequest` | `FileSearch` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.change_not_found`, `jj.invalid_input`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.4 |
| `zanshin_bookmarks` | `(uint64_t handle)` | — | `Bookmarks` (rows + tracking facts, see § `Bookmarks` payload) | `ffi.invalid_handle`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 3.4b, 9.29 |
| `zanshin_remotes` | `(uint64_t handle)` | — | `Remotes` | `ffi.invalid_handle`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 3.4b |
| `zanshin_git_push_remotes` | `(uint64_t handle)` | — | `GitPushRemotes` (the default push remotes; empty when none matches or on a non-Git backend) | `ffi.invalid_handle`, `jj.config_error`, `jj.invalid_input`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.54 |
| `zanshin_git_fetch_remotes` | `(uint64_t handle)` | — | `GitFetchRemotes` (the default fetch remotes — the Fetch button's enable rule; empty when none matches or on a non-Git backend) | `ffi.invalid_handle`, `jj.config_error`, `jj.invalid_input`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.30 |
| `zanshin_workspace_list` | `(uint64_t handle)` | — | `WorkspaceList` | `ffi.invalid_handle`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.7 |
| `zanshin_workspace_root` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `WorkspaceRootRequest` | `WorkspaceRoot` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.workspace_not_found`, `jj.workspace_no_recorded_path`, `jj.jj_lib_error` | 9.7 |
| `zanshin_workspace_add` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `WorkspaceAddRequest` | `WorkspaceAddResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.workspace_exists`, `jj.destination_not_empty`, `jj.git_worktree_failed`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.config_error`, `jj.stale_working_copy`, `jj.no_working_copy`, `jj.concurrent_working_copy`, `jj.jj_lib_error` | 9.23 |
| `zanshin_workspace_update_stale` | `(uint64_t handle)` | — | `StaleRecovery` (+ `precondition` = the trailing snapshot) | `ffi.invalid_handle`, `jj.concurrent_working_copy`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.23 |
| `zanshin_describe` | `(uint64_t handle, const char *change_id, const char *description)` | — | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.change_not_found`, `jj.invalid_input`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5 |
| `zanshin_new_change` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `ChangeIdList` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5, 9.48 |
| `zanshin_edit` | `(uint64_t handle, const char *change_id)` | — | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5 |
| `zanshin_abandon` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `ChangeIdList` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5 |
| `zanshin_restore` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `RestoreRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.3 |
| `zanshin_absorb` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `AbsorbRequest` | `AbsorbResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.3 |
| `zanshin_squash` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `SquashRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.15 (+9.54) |
| `zanshin_squash_plan` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `SquashRequest` | `SquashPlan` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.15 (+9.54) |
| `zanshin_split` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `SplitRequest` | `SplitResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.15 (+9.54) |
| `zanshin_drop_actions` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `DropActionsRequest` | `DropActions` (see § `DropActions` / `ChangeActions` payloads) | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.31 |
| `zanshin_change_actions` | `(uint64_t handle, const char *change_id)` | — | `ChangeActions` (see § `DropActions` / `ChangeActions` payloads) | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.31 |
| `zanshin_commit` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `CommitRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.no_working_copy`, `jj.invalid_input`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.49 |
| `zanshin_undo` | `(uint64_t handle, bool allow_cross_workspace)` | — | `MutationResult` | `ffi.invalid_handle`, `jj.undo_cross_workspace`, `jj.nothing_to_undo`, `jj.invalid_input`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5 (+9.39) |
| `zanshin_bookmark_create` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `BookmarkCreateRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.bookmark_exists`, `jj.bookmark_tracked_remote_exists`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.8 |
| `zanshin_bookmark_delete` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `BookmarkDeleteRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.8 |
| `zanshin_file_track` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileTrackRequest` | `TrackResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.config_error`, `jj.no_working_copy`, `jj.concurrent_working_copy`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.22 |
| `zanshin_file_untrack` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileUntrackRequest` | `UntrackResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.config_error`, `jj.no_working_copy`, `jj.concurrent_working_copy`, `jj.path_not_ignored`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.22 |
| `zanshin_snapshot` | `(uint64_t handle)` | — | — (no-payload success; the report is `Envelope.precondition`) | `ffi.invalid_handle`, `jj.stale_working_copy`, `jj.config_error`, `jj.jj_lib_error` | 9.26 |
| `zanshin_git_fetch` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `GitFetchRequest` (+ `cancel_token`, see § Cancel) | `GitFetchResult` (see § `GitFetchResult` payload) | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.not_a_git_repo`, `jj.config_error`, `jj.remote_not_found`, `jj.network_error`, `jj.cancelled`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5 (domain side + `Progress`: 6.4a; `cancel_token`: 9.52; request + `GitFetchResult`: 9.30) |
| `zanshin_git_remote_changes` | `(uint64_t handle, const char *remote_name, uint64_t cancel_token)` | — | `RemoteChanges` (the refs that moved, are new or were deleted upstream; empty = nothing new) | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.remote_not_found`, `jj.not_a_git_repo`, `jj.config_error`, `jj.invalid_input`, `jj.network_error`, `jj.cancelled`, `jj.jj_lib_error` | 9.24, 9.30 |
| `zanshin_git_push` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `GitPushRequest` (+ `cancel_token`, see § Cancel) | `GitPushResult` (see § `GitPushResult` payload; a cancel is `failure.kind = Cancelled`) | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.bookmark_exists`, `jj.bookmark_tracked_remote_exists`, `jj.push_ref_refused`, `jj.push_commit_rejected`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.config_error`, `jj.not_a_git_repo`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.20 (+`Progress`) |
| `zanshin_git_import` | `(uint64_t handle)` | — | `GitImportResult` | `ffi.invalid_handle`, `jj.not_a_git_repo`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_git_export` | `(uint64_t handle)` | — | `GitExportResult` | `ffi.invalid_handle`, `jj.not_a_git_repo`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_git_remote_add` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `GitRemoteAddRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.remote_exists`, `jj.not_a_git_repo`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_git_remote_remove` | `(uint64_t handle, const char *name)` | — | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.config_error`, `jj.remote_not_found`, `jj.remote_nonstandard_config`, `jj.not_a_git_repo`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_git_remote_rename` | `(uint64_t handle, const char *old_name, const char *new_name)` | — | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.config_error`, `jj.invalid_input`, `jj.remote_not_found`, `jj.remote_exists`, `jj.remote_nonstandard_config`, `jj.not_a_git_repo`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_git_remote_set_url` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `GitRemoteSetUrlRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.remote_not_found`, `jj.not_a_git_repo`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_config_list` | `(const uint8_t *data, uintptr_t len)` | `ConfigListRequest` | `ConfigListResult` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_parse_error` | 9.28 (+9.37) |
| `zanshin_config_get` | `(const uint8_t *data, uintptr_t len)` | `ConfigGetRequest` | `ConfigGetResult` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_parse_error`, `jj.config_not_found` | 9.28 (+9.37) |
| `zanshin_config_path` | `(const uint8_t *data, uintptr_t len)` | `ConfigPathRequest` | `ConfigPathResult` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_path_not_found` | 9.28 (+9.37) |
| `zanshin_config_set` | `(const uint8_t *data, uintptr_t len)` | `ConfigSetRequest` | `ConfigSetResult` (+ `precondition` iff the identity check snapshotted) | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_parse_error`, `jj.config_path_not_found`, `jj.config_unrecognized_file`, `jj.config_would_overwrite` | 9.28 (+9.37) |
| `zanshin_config_unset` | `(const uint8_t *data, uintptr_t len)` | `ConfigUnsetRequest` | `ConfigUnsetResult` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_parse_error`, `jj.config_path_not_found`, `jj.config_unrecognized_file`, `jj.config_would_delete_table`, `jj.config_not_found` | 9.28 (+9.37) |
| `zanshin_config_file_read` | `(const uint8_t *data, uintptr_t len)` | `ConfigFileReadRequest` | `ConfigFileText` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_path_not_found`, `jj.config_unrecognized_file` | 9.28 (+9.37) |
| `zanshin_config_file_write` | `(const uint8_t *data, uintptr_t len)` | `ConfigFileWriteRequest` | — (no-payload success) | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_unrecognized_file`, `jj.config_parse_error`, `jj.config_error` | 9.28 (+9.37) |
| `zanshin_config_gc_list` | `(const uint8_t *data, uintptr_t len)` | `ConfigGcListRequest` | `ConfigGcList` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.config_error`, `jj.config_path_not_found` | 9.28 |
| `zanshin_config_gc_delete` | `(const uint8_t *data, uintptr_t len)` | `ConfigGcDeleteRequest` | `ConfigGcResult` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.config_error`, `jj.config_path_not_found` | 9.28 |
| `zanshin_environment_adopt` | `(const uint8_t *data, uintptr_t len)` | `EnvironmentAdoptRequest` | — (no-payload success, no warnings) | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input` | 9.36 |
| `zanshin_network_token` | `(void)` → `uint64_t` | — | — | — | 9.52 |
| `zanshin_network_cancel` | `(uint64_t token)` → `void` | — | — | — | 9.52 |
| `zanshin_ffi_version` | `(void)` → `char *` | — | — | — | 3.2 |
| `zanshin_diagnostics` | `(void)` | — | `Diagnostics` | — (infallible; see *Token contract*) | 3.8 (+11.6) |
| `zanshin_log` | `(int32_t level, const char *target, const char *message)` → `void` | — | — | — | 3.3 |
| `zanshin_logging_init` | `(void)` → `void` | — | — | — | 3.3 |
| `zanshin_events_register` | `(void (*callback)(ZanshinBuf *event))` → `void` | — | — | — | 3.6 |
| `zanshin_events_unregister` | `(void)` → `void` | — | — | — | 3.6 |
| `zanshin_string_free` | `(char *ptr)` → `void` | — | — | — | 3.2 |
| `zanshin_buffer_free` | `(uint8_t *ptr, uintptr_t len)` → `void` | — | — | — | 3.2 |
| `zanshin_buffer_free_token` | `(ZanshinBuf *token)` → `void` | — | — | — | 3.2 |

Every symbol not marked `→ char *` or `→ void` returns `ZanshinBuf *` — the
never-null token described under *Token contract*.

**The empty-identity note (Stories 9.27 → 9.32).** A call whose `finish_transaction`
committed an operation while `user.name` and/or `user.email` was empty in the effective
config stack carries a `jj.identity_missing` entry in `Envelope.warnings` — the jj CLI's
post-transaction "Name and email not configured." block (or its name-only / email-only
variant), verbatim. Story 9.27's `MutationResult.identity_missing` table
(`IdentityMissing { name, email }`) is gone: the warning is the fact's only carrier. It
is never a refusal: the commit was created with the empty identity, exactly as the CLI
creates it; nothing is emitted when both are configured or when the call committed nothing
(and not for `zanshin_file_track` / `_untrack`, whose CLI verbs skip the finish). The
pre-verb snapshot's own import finishes warn too, as the CLI's do. Since Story 9.33 the
creations carry it where the CLI's flow finishes a transaction: `zanshin_repo_clone` ONCE
after its single `clone` operation (the CLI, which finishes up to three transactions, warns
up to three times — a recorded Story 9.20 deferral), the conversion snapshot's own finishes;
never `zanshin_repo_init` (an empty-directory `jj git init` finishes nothing) and never the
conversion's raw commits.

---

## Per-symbol contracts

Five symbols carry more contract than their rustdoc can hold, and keep a prose
section: `zanshin_repo_detect` and `zanshin_repo_convert` here,
`zanshin_graph_topology`, `zanshin_log_defaults` and `zanshin_commit_contents` further down. For every other
symbol the rustdoc block above its declaration in `zanshin_ffi.h` is the contract.

### `zanshin_repo_detect`

```c
ZanshinBuf* zanshin_repo_detect(const char* path);
```

Classifies the repository kind at `path`.

**`Neither` and `PathNotFound` are success results**, not errors. Only a
genuine filesystem I/O failure (e.g. `EACCES`, `ENOTDIR`) yields an error
envelope.

When the result is `Neither` or `PathNotFound` and an enclosing jj or Git
repo is found by the consent-gated ancestor walk (FR-JJ-14), the payload
populates `suggested_root` and `suggested_kind`. The UI decides whether to
offer opening it — the backend never auto-opens.

The ancestor walk stops at the `$HOME` ceiling: a repo at or above `$HOME`
(e.g. a dotfiles repo at `~`) is intentionally **not** surfaced as a
suggestion, so `suggested_root` may be null even though an ancestor technically
contains a repo.

**Success payload:** `Envelope<RepoDetect>`

```
RepoDetect {
  kind:           RepoKind   // classification of path
  suggested_root: string?    // enclosing repo path, or null if no suggestion
  suggested_kind: RepoKind   // kind of the enclosing repo (only valid when
                             // suggested_root is non-null — D4 presence flag)
}
```

**Error codes:**

| Code               | Condition                                      |
|--------------------|------------------------------------------------|
| `jj.detect_failed` | Filesystem I/O error prevented classification. |
| `ffi.null_pointer` | `path` is null.                                |
| `ffi.utf8_error`   | `path` contains invalid UTF-8.                 |

---

### `zanshin_repo_convert`

```c
ZanshinBuf* zanshin_repo_convert(const char* path);
```

Converts the Git repository at `path` to a colocated jj workspace in-place
by calling `convert_colocated` (`zanshin_jj`). It runs the same sequence as
`jj git init` over an existing `.git/` (`do_init`'s External arm): `import git
refs` (skipped when it changed nothing), a `.jj/.gitignore` containing `/*`, then
the CLI's per-command snapshot under jj's Git import/export lock (Story 9.26) —
`import git head` re-parents `@` onto the Git HEAD by resetting the working-copy
STATE only, and `snapshot working copy` records a dirty work tree into `@` — and
finally, when `refs/remotes/upstream/HEAD` or `refs/remotes/origin/HEAD` names a
bookmark, `revset-aliases.'trunk()'` in the repo-level config file, which lives
**outside** `.jj/`, under `<config_dir>/jj/repos/<config-id>/config.toml`. No
work-tree file is written or deleted. `.git/` is written only by the CLI's own
colocated steps — jj exports back the refs it has just imported and, when the
snapshot recorded changes, adds intent-to-add entries for the new files to
`.git/index` (`@` is mutable after the conversion, so the snapshot takes the
CLI's `export_working_copy_changes_to_git` branch; the HEAD/index reset happens
only for an immutable `@`) — so no
user-visible ref and no HEAD is moved, and a rollback never deletes or rewrites
`.git/`.

On success the function returns a live `RepoHandle` for the converted
workspace. The Dart worker stores the raw handle in its Model-A handle table
(`handleId → raw *mut RepoSession`) and returns an opaque `handleId` to the caller.

**The conversion's report (Story 9.33).** Both envelopes — ok and error — carry what
`jj git init` would have printed. `Envelope.precondition` is the report of the snapshot
the conversion runs, present iff it started (PARTIAL when it failed). `Envelope.warnings`
holds, in the CLI's order: the refs step's `jj.git_import_failed` (`git/init.rs:304`,
also when the step writes no operation) and colocated `jj.git_export_failed`
(`:311-312`); the config-load warnings (`jj.config_alias_invalid`,
`jj.config_alias_redefined`, `jj.revset_diagnostic`); the snapshot's own warnings (its
colocated refs import reports an unreadable ref a SECOND time, as the CLI does); then,
on the snapshot's success, `jj.snapshot_files_refused` / `jj.snapshot_paths_not_utf8`.
The refs step and the head import commit without a finish, so an empty identity is
warned only by a finish the snapshot itself runs. A failure keeps everything reported
before it — when it came before the re-open, although the rollback removes `.jj/`; a
failed re-open or watcher arming leaves `.jj/` in place.

**Success payload:** `Envelope<RepoHandle>`

```
RepoHandle {
  handle:     uint64   // raw *mut RepoSession reinterpreted as u64; opaque to Dart
  session_id: uint64   // process-unique event-correlation id (never reused);
                       // async events carry it — see "Correlation and demux"
}
```

**Error codes:**

| Code                 | Condition                                              |
|----------------------|--------------------------------------------------------|
| `jj.already_jj_repo` | `.jj/` already exists at `path`.                       |
| `jj.not_a_git_repo`  | No `.git/` at `path` (or path does not exist).         |
| `jj.convert_failed`  | jj-lib, config-write or `detect_repo` I/O error during conversion; detail in `context`. |
| `ffi.null_pointer`   | `path` is null.                                        |
| `ffi.utf8_error`     | `path` contains invalid UTF-8.                         |
| `watcher.io_error`   | The filesystem watcher could not be armed, so no handle is returned (strict-fail, OQ-1 — see *Async events* below). The written `.jj/` persists; detail in `context`. |

---

## Dart worker integration

Both functions are **handle-free** (path-in only). The Dart worker dispatches
them directly without a handle-table lookup:

```dart
case DetectRepoCommand(:final String path):
  final bytes = repo_ffi.zanshinRepoDetect(path);
  responseSP.send((commandId, BufferResult(bytes)));

case ConvertRepoCommand(:final String path):
  final bytes = repo_ffi.zanshinRepoConvert(path);
  _replyRepoOp(bytes, ...);  // stores handle on success, replies HandleResult(id, bytes)
```

Public `ZanshinWorker` API:

- `Future<RepoDetectResult> detect(String path)` — decodes via `decodeRepoDetectEnvelopeInternal`
- `Future<CreatedRepoHandle> convert(String path)` — stores handle, returns a
  `CreatedRepoHandle` whose `warnings` / `precondition` are decoded from the ok envelope
  `HandleResult` forwards (`decodeCreationReportInternal`, Story 9.33)

---

## Async events (Story 3.6)

FR-FFI-4's async Rust→Dart signal: Story 3.5's watcher events and FR-FFI-8's
future progress notifications both ride ONE process-global `NativeCallable`
sink, registered once by the Dart worker isolate at startup. There is no
per-handle callback registry.

### `RepoSession` — the handle is now a warm loader + watcher owner

Every handle-producing wrapper (`zanshin_repo_open`/`_init`/`_clone`/`_convert`)
constructs a `RepoSession { repo, watcher, dispatch }` and arms its filesystem
watcher **before returning** (AR-G-5). The `u64` handle Dart holds is a
`*mut RepoSession` (no wire/ABI change — handles were always opaque `u64`).
Each session owns one background dispatch thread that drains the watcher's
`Receiver` and forwards serialised events to the process-global sink.
`zanshin_repo_close` stops the watcher (joins the debouncer thread) and joins
the dispatch thread **before** the session — and the repo it holds — is
dropped, so no callback can fire for a handle after `close` returns.

**Arming failure is strict-fail (OQ-1):** if the watcher cannot be armed
(e.g. a required `.jj` sub-path is missing or unwatchable), the wrapper
returns `watcher.io_error` and **no handle** — the repo is not left open in
an unwatched state. For `init`/`clone`/`convert` the on-disk artefacts
created before the arming failure **persist** (only the arming failed; a
retry will see an existing repo — same posture as other post-init failures) and
the `watcher.io_error` envelope still carries the creation's warnings / snapshot
report (Story 9.33); `open` leaves no residue. Post-arm watch degradation (e.g. an FS error after a
successful open) never re-uses this code string; it rides the event stream
instead (see `WatchError` below) — `watcher.io_error` is emitted in exactly
one place: the arming-failure envelope at open/init/clone/convert.

### Registration

```c
typedef void (*EventCallback)(ZanshinBuf* event);

void zanshin_events_register(EventCallback callback);   // NULL is a defensive no-op
void zanshin_events_unregister(void);
```

Both are **infallible, `void`-returning, and `catch_unwind`-wrapped** — like
`zanshin_log`/`zanshin_logging_init`, they are handle-free and callable from
**any isolate/thread** (exempt from the single-consumer rule, AD-2).

- `register` **overwrites** any previously registered callback — there is no
  stacking. A worker restart simply re-registers.
- `unregister` is **unconditional and idempotent** — there is no
  compare-and-clear against a specific callback pointer, because production
  runs exactly one worker per process. This lets the **main** isolate call
  `unregister` on unexpected worker death without knowing the dead worker's
  callback pointer (`ZanshinWorker._onWorkerDeath`).
- **Ordering on graceful shutdown is load-bearing:** every open repo is closed
  (joining its dispatch thread) **before** `zanshin_events_unregister()`,
  which runs **before** the Dart `NativeCallable.close()`. Invoking a
  `NativeCallable`'s pointer after `close()` is undefined behaviour
  (api.dart.dev); this ordering makes that clause unreachable in practice.
- **`unregister` is a barrier:** the dispatch path holds the registration lock
  **across** the callback invocation, so once `unregister` returns no dispatch
  thread can still be inside a callback it loaded earlier — closing the
  callable or killing its isolate afterwards cannot race a delivery.
- **Shutdown-ack timeout backstop:** if the worker never acks the
  `ShutdownCommand` (hung or died mid-shutdown), the main isolate kills the
  worker and calls `zanshin_events_unregister()` itself — the killed
  isolate's callable must not stay reachable while un-closed sessions'
  dispatch threads are still alive.
- **Unexpected worker death:** the main isolate unregisters the sink
  (unconditional-clear, see above) and kills the worker. The dead worker's
  open sessions — their watchers and dispatch threads — **leak by design**
  (same posture as the handle leak on worker death); after the unregister they
  dispatch into an empty sink and drop. An event whose callback invocation is
  concurrent with the death instant is an **accepted residual race**; tokens
  already queued in the dead isolate leak with it.

### Token ownership across the async hop

`NativeCallable.listener` calls are non-blocking: Rust's `callback(token)`
returns immediately, and the Dart handler runs later, on the isolate that
created the callable. Rust therefore must **not** free the buffer after
invoking the callback — the token transfers to Dart exactly like a
synchronous return value:

```dart
// packages/zanshin_core/lib/src/ffi/events.dart:104
void _handleNativeEvent(
  void Function(ZanshinRawEvent event) onEvent,
  ffi.Pointer<ZanshinBuf> token,
) {
  try {
    final Uint8List bytes = readToken(token);   // copies out, then frees the token
    onEvent(decodeEventEnvelope(bytes));
  } catch (e, st) {
    _log.warning('dropping malformed event: $e', e, st);  // never unwind into Rust
  }
}
```

`readToken` is the shared outbound helper in
`packages/zanshin_core/lib/src/ffi/request_bytes.dart:99-106` — the same one every
`extern "C"` adapter uses. This handler is its one caller whose token is not an
`extern "C"` return value; the guarantee is the same (Rust only ever posts a real
token), and the handler's own `try`/`catch` is what keeps a violation from
unwinding into the callback.

**Undelivered tokens at callable-close leak by design.** If the callable is
closed while events are still in flight, those tokens are never freed. This
is bounded (at most the channel capacity — 256 — per repo, per Story 3.5) and
shutdown-only; the graceful-shutdown ordering above (repos closed → threads
joined → *then* the callable closes) makes the window empty in practice. No
machinery is built to reclaim it.

### Payload schemas

Both tables are appended to the existing `Payload` union (`schemas/envelope.fbs`)
— no second root type, no JSON, no `schema_version` (ADR-0001). Event
envelopes are always `ok == true`.

```
enum WatcherEventKind : byte { OpHeadsChanged, WorkingCopyHeartbeat, WatchError }

WatcherEvent {
  session_id:  uint64          // correlation id — process-unique, never reused
  kind:        WatcherEventKind
  paths:       [string]?       // absent for WatchError (null-for-absence)
  message:     string?         // set only for WatchError
}

Progress {
  session_id:  uint64          // same correlation id (a clone's: its cancel token, Story 9.52)
  operation:   string          // "fetch" (6-4a), "clone" or "push" (Story 9.20)
  progress:    float           // ∈ [0, 1]
  message:     string
}
```

Story 9.20 adds two producers. `zanshin_git_push` tags its events with the session's id like
`zanshin_git_fetch`; a push's progress arrives mostly as git sideband text, which Zanshin does not
forward, so a push may report none. `zanshin_repo_clone` has no session yet while it runs: it
allocates the session id BEFORE the clone and tags its events with it, so they carry the id the
returned `RepoHandle.session_id` names.

**Live delivery (Story 9.52).** `events::dispatch` runs on the calling thread, which for the four
network calls is no longer the worker's: the worker hands each fetch, push, clone and remote-change
poll (Story 9.24; its Dart progress operation `remote_changes` never emits, git sends no progress
for `ls-remote`) to a short-lived helper isolate (`Isolate.run`) and keeps serving, so the worker-owned
`NativeCallable.listener` receives the events while the call runs and forwards them to main
before the call's reply (one message queue per isolate). A clone is passed a non-zero
`cancel_token` (see *Cancel* below), which IS its session id: the worker maps that id to the handle
id it reserves for the clone BEFORE the helper starts, and announces the pair to main on the event
port, so the clone's progress is routed live under the handle id the clone will get (the mapping
is dropped again if the clone fails). In Dart each call's events are also its
`NetworkOperation.progress`.

`WatchError` is a **degraded-watch signal, not a failed call** — it never
carries the `watcher.io_error` code string (single-emission-point rule).

### Correlation and demux

Events carry the session's **`session_id`** — a process-unique `u64` allocated
from a monotonic counter when the session is armed (starts at 1; 0 is never
issued) and returned to the worker alongside the raw handle in the `RepoHandle`
payload (`RepoHandle { handle, session_id }`). The lookup lives in the
`registerEventSink` closure the worker installs
(`packages/zanshin_core/lib/src/worker/isolate.dart:1349-1352`): it reads
`sessionToId[raw.sessionId]` to recover the small dense `handleId` before
constructing the public `RepoEvent` sent to main; an unknown session id (a benign
close race) is logged and dropped, never thrown. Raw pointers still never reach
the main isolate (Model A holds); the raw handle is the worker-side token for
calls back INTO the cdylib — `zanshin_repo_close`, every read wrapper, and — since
Story 6.5 and Epic 9 — every mutation wrapper too.

**Resolved (2026-07-04) — raw-pointer ABA** (formerly a known accepted gap,
3-6 review): events used to carry the raw `*mut RepoSession`-derived `u64`; a
close → reopen could reuse the freed allocation's address, so a stale event
queued during the close window could be misattributed to the NEW repo's
`handleId` (first observed in the wild as a load-induced flake of the 3.6
two-repos isolation test, 2026-07-03). Session ids are never reused, so a
stale event can now only be dropped — never misattributed. Pulled forward
from Story 6-4a during the 3-10 code review (Ralph, 2026-07-04); Story 6-4a's
`Progress` producer inherits the same correlation id.

### Dart worker integration

- `lib/src/ffi/events.dart` — owns the `NativeCallable.listener`, the
  try/catch-wrapped native handler, and `registerEventSink` / `closeEventSink` /
  `unregisterEventSink`. It is **not** the only file that imports `dart:ffi`;
  every adapter under `lib/src/ffi/` does. The invariant is the layer boundary:
  **`dart:ffi` never reaches `lib/src/worker/`** — the worker deals in raw `int`
  handles and `Uint8List` envelopes only, which is what keeps `Pointer` out of
  the isolate seam.
- `lib/src/worker/events.dart` — pure Dart `RepoEvent` sealed family
  (`OpHeadsChangedEvent` / `WorkingCopyHeartbeatEvent` / `WatchErrorEvent` /
  `ProgressEvent`), exported from `zanshin_core.dart`.
- `ZanshinWorker.events` — a broadcast `Stream<RepoEvent>` fed by the
  previously-unused (Story 3.9) event `SendPort`.
- `ZanshinWorker.close()` is now `Future<void>`: it sends a `ShutdownCommand`
  the worker uses to run the shutdown ordering above, then awaits an ack
  (bounded timeout) before killing the isolate as a backstop. Since Story 9.52
  the worker first cancels every running network call and runs the ordering
  only once no helper isolate still uses a session (see *Cancel* below).

---

## Cancel (Story 9.52)

The four network calls — `zanshin_git_fetch`, `zanshin_git_push`, `zanshin_repo_clone` and the
remote-change poll `zanshin_git_remote_changes` (Story 9.24) — take a **cancel token**:
`zanshin_git_remote_changes`' third argument, the `cancel_token` field of `GitFetchRequest` /
`GitPushRequest` / `RepoCloneRequest`. `0` (the absent-field default) is no token: the call is not
cancellable and never answers `jj.cancelled`.

**Token lifetime.** `zanshin_network_token()` returns a fresh id from the session-id counter
(never `0`, never reused, never a live session's id) and registers it; the call it is passed to
attaches it and ends it when it returns. `zanshin_network_cancel(token)` sets the token's flag; it
is idempotent, callable from any thread, and a no-op for `0`, an unknown or a finished token. A
token cancelled before its call starts (a call queued behind another call on its handle) makes the
call start cancelled. A clone uses a live (registered, not finished) token as the new session's
id, so its `Progress` events are routable before it returns (*Payload schemas* above).

**Checkpoints.** A cancelled token refuses at its verb's next checkpoint:

- fetch: before git's fetch, and after it but before the import — a cancelled fetch imports
  nothing and writes no operation;
- clone: before and after the fetch's git work (the fetch and the default-branch query), inside
  the clone's clean-up scope, so what the clone created is removed (a pre-existing empty
  destination stays) — `jj.clone_cleanup_failed` warns as for any failure there;
- push: before each remote's git push. There is no checkpoint after the last remote: once every
  remote's git push has run, the push finishes normally;
- remote-change poll: before its `git ls-remote`, and after it before the diff — it writes nothing
  either way.

A `git` failure while the token is cancelled is the cancel too (a killed git is indistinguishable
from any other failure in jj-lib); every other error passes through unchanged — a refusal raised
before the call reaches a checkpoint (no git backend, a malformed config key, a refused push
argument) answers exactly as it does without a cancel.

**Kill scope.** While a cancelled token's call runs, Zanshin polls every ~50 ms for the call's git
processes among the DESCENDANTS of its own process and signals them: SIGTERM first (git removes its
lock and temp files, as on the CLI's Ctrl-C), SIGKILL for any still alive 2 s after the cancel. Each
one is stopped (SIGSTOP) before its children are listed and continued (SIGCONT) after the signal,
so a child it forks during the scan cannot escape as the orphan of a killed parent. The polling keeps
running until the call ends, so a git spawned after the cancel is caught too.
Which descendants are the call's: every git of a call that carries a token runs with
`ZANSHIN_CANCEL_TOKEN=<token>` in its environment (added to jj-lib's `GitSubprocessOptions`, which
git's helpers inherit), and a process whose environment carries that exact pair is the call's,
with its descendants. macOS hides the environment of Apple's platform binaries from other processes
(`sysctl(KERN_PROCARGS2)` stops after the arguments) — `/usr/bin/git`, the Command Line Tools' git
and its helpers, `/bin/sh`, `ssh` — so for a process whose environment is hidden its arguments
decide instead: jj-lib runs every git as `git … --git-dir <dir> …`, and the call names its
repository's git dir — used only when exactly one live call watches that dir (two calls on two
handles of one repository give that dir no fallback; the environment match still applies). No
other process is signalled. Residual: a git without a token on that dir — a concurrent `workspace
add`'s worktree git — is not told apart from the call's. Elsewhere than macOS a cancel sets the flag
and the checkpoints refuse, nothing more.

**Outcomes.** A cancelled fetch, clone or remote-change poll answers `jj.cancelled` (context `Cancelled`); a
cancelled push answers its ok `GitPushResult` with `failure.kind = Cancelled` (message
`Cancelled`), `recorded = false`, and the per-remote rows saying which remotes' git push completed
(`PushRemote.finished`, `PushRef.status`) — the push failure model of Story 9.20 keeps a push's
outcome data. A remote whose git push the cancel killed is not `finished`, though the remote may
already have accepted some of its refs, as after any failed git push. A cancel that arrives after
the last checkpoint and after the git work changes nothing.

**Dart.** The worker owns the tokens: each fetch, push and clone runs on a short-lived helper
isolate (`Isolate.run`) with a token the worker allocates (`zanshin_network_token`, on the worker),
and every call on the same handle — `closeRepo` included — waits for it in arrival order, so the
helper is the only isolate touching the raw session (AD-2; Rust adds no handle locking). Calls on
other handles, handle-free commands and events do not wait. `ZanshinWorker.gitFetch` / `gitPush` /
`cloneRepo` and `RepoHandle.gitFetch` / `gitPush` return a `NetworkOperation<T>`: `result` (the
verb's payload and refusals as before), `progress` (this call's `ProgressEvent`s, closing with
`result`) and `cancel()` (a `NetworkCancelCommand`; a no-op after `result` completed or after the
worker closed). A helper isolate that throws answers `internal.dispatch_error`.

---

## GraphTopology payload and `zanshin_graph_topology` (Story 4.12)

The whole revset's index-only topology (Story 4.10's `zanshin_jj::Repo::graph_topology`)
crosses FFI as a `GraphTopology` member of the `Payload` union — in **slot 11**, the slot
the removed `GraphSlice` held (union member order is the wire discriminant; nothing was
renumbered). The payload is **scalar vectors indexed by node plus CSR offset vectors** for
the edges and the anchors — no table per node — so Dart reads it through typed-data views
with O(1) access per node. The symbol calls `Repo::graph_topology`, encodes the ids
(`crates/zanshin-ffi/src/graph.rs::TopologyIds::encode`) and serialises the result
(`graph_topology_to_envelope`). The card content of a node is `zanshin_commit_contents`
(below) at the returned `operation_id`.

*(2026-10-01, Story 4.12: this replaces the `GraphSlice` payload and `zanshin_graph_slice`
of Stories 4.2 / 4.6 / 4.8 — lanes, per-row metadata, synthetic "(elided revisions)" rows —
together with the `zanshin-graph` lane crate. The layout is computed in Dart (Story 4.11);
`zanshin_jj::Repo::walk_graph` stays as the `jj log`-faithful read. The old section is in
git history.)*

### `zanshin_graph_topology`

```c
ZanshinBuf* zanshin_graph_topology(uint64_t handle, const uint8_t* data, uintptr_t len);
```

**Request:** `GraphTopologyRequest { kind: GraphTopology, revset, prioritize,
short_prefixes, anchors, with_timestamps }` (the *Request-buffer contract* above; the
request is read BEFORE the handle is borrowed). Every argument is a caller pass-through
(FR-JJ-17); Rust bakes in no default:

- `revset` — the nodes, in `jj log` order (children before parents, `prioritize` first).
  **Required** (row 4 of the refusal ladder: `revset is required`). The CLI's
  `revsets.log` default is the Dart constant `defaultLogRevset` (and the effective value is
  `zanshin_log_defaults`' `log`), a pre-fill the UI passes explicitly.
- `prioritize` — `jj log`'s `revsets.log-graph-prioritize`. **Required.** CLI default
  `present(@)` (Dart `defaultGraphPrioritize`); `none()` = none; a blank expression is a
  `jj.revset_parse_error`.
- `short_prefixes` — the shortest-prefix disambiguation set. **Required.** CLI default
  `revsets.log` (Dart `defaultShortPrefixes`). An **EMPTY string DISABLES**
  disambiguation (full-index prefix lengths) — the CLI's toggle, deliberately unlike
  `prioritize`. A PARSE failure is a hard `jj.revset_parse_error`; everything that can
  only fail while LOADING the disambiguation index — symbol resolution included — is a
  `jj.short_prefixes_failed` warning and degrades to full-index prefixes, as the CLI does
  (`cli/tests/test_log_command.rs::test_log_bad_short_prefixes` @ v0.44.0).
- `anchors` — an ordered list of revsets, each intersected with `revset` and evaluated
  once; the layout's priority rule reads the node indices each selects. An ABSENT vector is
  the empty list. The editable pre-fill is the Dart constant `defaultGraphAnchors`
  (`['trunk()', 'present(@)']`); nothing applies it on its own.
- `with_timestamps` — load each non-root commit for its committer timestamp (the one
  per-node object load; per call, never cached). Absent = `false`.

All three expressions and every anchor resolve aliases from the repo's EFFECTIVE jj config
(Story 4.9), re-read per call. Interior NULs are guarded Dart-side (*Interior NUL* above).

**Precondition and warnings.** The call runs the pre-verb snapshot exactly once (Story
9.26) and re-derives from the head operation; Rust retains nothing (ADR-0002). Its
envelope carries `precondition` and `warnings` on the ok arm and on every error arm after
the snapshot ran (the shared `precondition_envelope`), and `RepoHandle.lastPrecondition`
is updated by every ok call. The op-heads watcher's `OpHeadsChangedEvent` is the UI's
re-request trigger.

**Success payload:** `Envelope<GraphTopology>` (n nodes, E edges, A anchors):

```
enum GraphEdgeKind : byte { Direct, Indirect, Missing }   // == zanshin_jj::GraphEdgeKind order
enum TopologyRefKind : ubyte { Bookmark, Tag }

TopologyRef {
  node:       uint             // the node index
  kind:       TopologyRefKind
  name:       string
  remote:     string           // ABSENT (Dart null) for the local entry
  synced:     bool
  conflicted: bool
}

TopologyWorkingCopy {
  node:      uint
  workspace: string
}

GraphTopology {
  operation_id:         string                 // full hex; the content call's pin
  all_count:            ulong                  // |all()|, VISIBLE commits only
  commit_ids:           [ubyte]                // n × commit_id_stride raw id bytes
  change_ids:           [ubyte]                // n × change_id_stride raw id bytes
  commit_id_stride:     ubyte                  // bytes per id; 0 iff n = 0
  change_id_stride:     ubyte                  // bytes per id; 0 iff n = 0
  flags:                [ubyte]                // n; bit 0 working_copy, 1 immutable, 2 hidden,
                                               //    3 divergent, 4 root, 5 has_change_offset
  change_offset:        [uint]                 // n; meaningful iff flags bit 5, else 0
  change_id_prefix_len: [ubyte]                // n; hex digits
  commit_id_prefix_len: [ubyte]                // n; hex digits
  parent_count:         [uint]                 // n; Missing parents included, 0 for the root
  edge_start:           [uint]                 // n + 1; edge_start[0] == 0, edge_start[n] == E
  edge_target:          [int]                  // E; node index, -1 iff Missing
  edge_kind:            [GraphEdgeKind]        // E; jj stream order, repeated targets kept
  timestamps:           [long]                 // n iff requested (epoch ms), ABSENT otherwise
  refs:                 [TopologyRef]          // sorted by node; per node bookmarks, then tags
  working_copies:       [TopologyWorkingCopy]  // sorted by node
  anchor_start:         [uint]                 // A + 1
  anchor_node:          [uint]                 // anchor_start[A] entries, ascending per anchor
}
```

- **Every vector but `timestamps` is always written**, empty when n = 0 (`edge_start` is
  then `[0]` and `anchor_start` has A + 1 zeros). A reader treats an absent one, or one of
  the wrong length, as a malformed buffer.
- **Ids are raw bytes at one fixed stride per column** (OQ 2 option (b), decided by
  measurement — spec-4-12 § Measurements): node i's id is `[i × stride, (i + 1) × stride)`
  of its column. A reader formats a commit id as lowercase hex and a change id as jj
  reverse-hex (nibble v → `'z' − v`, high nibble first: 0 → `z`, 15 → `k`; jj-lib
  `hex_util.rs`). Rust refuses an id it cannot encode (odd length, a digit outside its
  alphabet, a stride mismatch) as `jj.jj_lib_error` — `zanshin-jj` never produces one.
- **Flags** are one byte per node (bits 6–7 zero). `has_change_offset` is the presence bit
  of `change_offset` — flatc 25.12.19 has no optional scalar for Dart.
- **Edges (CSR).** Node i's edges are `[edge_start[i], edge_start[i + 1])`, in jj's stream
  order with repeated targets kept: a merge can carry a Direct AND an Indirect edge to one
  node. `edge_target` is **kind-gated**: defined iff `edge_kind != Missing`; a Missing
  edge's slot holds **−1** (not 0), so a reader that skips the kind check fails loudly
  instead of linking node 0. A Missing edge carries no target id (OQ 3). No synthetic
  "(elided revisions)" node exists.
- **Null for absence.** `timestamps` is absent iff the call did not request them; when
  present, the root's slot is 0 and reads as `null` in Dart (the root carries none).
  `change_offset` reads `null` without its presence bit, a Missing edge's target `null`,
  a local ref's `remote` `null`.
- **Refs / working copies** are sparse tables sorted by node: per node its bookmarks, then
  its tags, each in `zanshin-jj`'s order (the CLI's `collect_distinct_refs` filter: a
  tracked-and-synced remote entry is not emitted); working copies per node in `zanshin-jj`'s
  order, empty in a single-workspace repo (the CLI's guard).
- **Anchors (CSR).** Anchor a's nodes are `anchor_node[anchor_start[a] .. anchor_start[a + 1]]`,
  ascending (= `jj log` order); an anchor selecting nothing in `revset` is an empty range.
- **`all_count`** is `|all()|` by iterating — the VISIBLE commits only, so a revset naming
  hidden commits can yield more nodes than `all_count`.
- **Indices** fit `u32` / `i32`: a FlatBuffer is smaller than 2 GiB, so the saturating
  casts Rust carries are unreachable.

**Copies across the isolate boundary.** The topology crosses with **one** copy: the worker
reads the native buffer through `FfiBuffer.bytes` (a view over Rust's allocation), copies it
ONCE into a `TransferableTypedData`, frees the native buffer and sends a `TransferResult`;
the main isolate's `materialize()` hands the bytes over without a further copy, and
`GraphTopologyView` reads them in place. **Every other envelope crosses with two**:
`readToken`'s copy out of native memory (`Uint8List.fromList`) plus the `SendPort` copy of
the `BufferResult`. *(2026-10-01, Story 4.11: `RepoHandle.graphLayout` is a second one-copy
consumer: its `GraphLayoutResult` carries the topology envelope (one copy) and the layout's grid
buffer (one copy), each as a `TransferableTypedData`; the worker lays the topology out over the
native bytes before it frees them. See `docs/graph-layout.md` §13.)*

**Error codes:**

| Code                         | Condition                                                                 |
|------------------------------|---------------------------------------------------------------------------|
| `ffi.invalid_handle`         | Rust: `handle == 0`. Worker: unknown/closed `handleId` (Model A lookup; a `BufferResult`). |
| `ffi.null_pointer`           | `data` is null.                                                           |
| `ffi.invalid_argument`       | `data` does not verify as a `GraphTopologyRequest`, or its `kind` is not `GraphTopology`. |
| `jj.invalid_input`           | `revset`, `prioritize` or `short_prefixes` is absent (`<field> is required`). |
| `jj.revset_parse_error`      | An expression or an anchor is syntactically invalid / an unknown function (incl. a blank `prioritize`; an EMPTY `short_prefixes` is NOT an error). Reason in `context`. |
| `jj.revset_resolution_error` | `revset`, `prioritize` or an anchor names a symbol that cannot be resolved. NOT raised for `short_prefixes` (it warns and degrades). |
| `jj.stale_working_copy`      | The pre-verb snapshot found the working copy stale (Story 9.26); nothing is written. |
| `jj.config_error`            | The repo's effective jj config is unreadable, not valid TOML, has a malformed `config-id`, or a wrong-typed value; the file path or key in `context`. A single bad `[revset-aliases]` entry only warns. |
| `jj.jj_lib_error`            | A jj-lib load, evaluation, index or (with `with_timestamps`) commit-load failure, a failed snapshot backend, or an id the encoder refuses; detail in `context`. |
| `graph.dangling_edge`        | A Direct/Indirect edge names a target outside the node set — unreachable with jj-lib's stream contract; the target id in `context`. |

An error envelope never carries a partial payload.

**Dart worker integration:**

- `GraphTopologyCommand(handleId, revset, prioritize, shortPrefixes, anchors,
  withTimestamps)` — the worker looks up the raw handle (unknown id → `ffi.invalid_handle`
  envelope as a `BufferResult`), calls `zanshinGraphTopology(raw, …)`
  (`lib/src/ffi/graph.dart`, which returns the `FfiBuffer` WITHOUT `readToken`'s copy) and
  replies with the one-copy `TransferResult` above.
- `ZanshinWorker.graphTopology(handleId, {revset, prioritize, shortPrefixes, anchors,
  withTimestamps})` → `GraphTopologyView`; the interior-NUL guards run on the calling side
  (`ArgumentError`) before `send`, and the precondition is recorded.
- `RepoHandle.graphTopology({required revset, prioritize = defaultGraphPrioritize,
  shortPrefixes = defaultShortPrefixes, required anchors, required withTimestamps})` —
  closed-handle guard (`StateError`), delegates. `anchors` and `withTimestamps` are
  required: nothing pre-fills the anchors on its own, and the timestamp cost is the layout
  mode's call.
- *(2026-10-01, Story 4.11)* `GraphLayoutCommand(handleId, revset, prioritize, shortPrefixes,
  anchors, mode, order, utcOffsetMin, budget)` — the same topology call (timestamps iff `mode` is
  `free`), then the Dart layout engine over the native bytes before they are freed; replies with
  a `GraphLayoutResult`: the topology envelope (one copy) plus the layout grid (one copy), or a
  `LayoutContractException` instead of the grid (unknown id → `ffi.invalid_handle` envelope as a
  `BufferResult`). `ZanshinWorker.graphLayout` / `RepoHandle.graphLayout` return
  `({GraphTopologyView topology, GraphGridView grid})`; the precondition is recorded as for
  `graphTopology`. Contract: `docs/graph-layout.md` §13.
  *(2026-10-01, Story 4.13: `GraphLayoutCommand` gains four fields — `stacks`, `expandedKeys`,
  `collapsedKeys`, `keepOpenKeys` — required on the command and on `ZanshinWorker.graphLayout`,
  pre-filled `false` / empty on `RepoHandle.graphLayout`. They never cross FFI: the worker
  resolves the keys against the topology and, with `stacks`, groups linear runs (§4.8); the grid
  is then format version 2. With `stacks` false the keys are ignored and the grid is version 1,
  unchanged.)*
- **Decode contract (`GraphTopologyView.fromEnvelope`).** `!ok` →
  `ZanshinFfiException(code, context)` carrying the envelope's `precondition` and
  `warnings`; `ok` with a non-`GraphTopology` payload, a missing `operation_id` / `refs` /
  `working_copies`, a missing or wrong-length structurally required vector, or nodes with a
  zero stride → `ZanshinFfiException('ffi.unknown', …)` — never a `?? ''` / `?? []`
  coercion. Each vector is located by hand and checked in O(1) (presence, length, bounds);
  the values are read on access through typed-data views over the envelope bytes (a vector
  not aligned for its element size is copied — that one vector only). An unknown
  `edge_kind` byte throws `ffi.unknown` on access. Id → index lookups
  (`indexOfCommitId`, `indicesOfChangeId` — several indices for a divergent change) are
  built on first use. A view over native memory is valid only while its `FfiBuffer`
  lives; the views the worker returns own their bytes.
- The view types are not exported from `package:zanshin_core/zanshin_core.dart` yet
  (Story 10.12 exports them); tests import them via `src/`.

## `LogDefaults` payload and `zanshin_log_defaults` (Story 4.9)

The repo's EFFECTIVE `jj log` defaults cross FFI as a `LogDefaults` member of the
`Payload` union (`schemas/envelope.fbs`, appended after `GraphSlice` — *(2026-10-01,
Story 4.12: `GraphTopology` took that slot)* — union
member order is the wire discriminant, so it is append-only). The exported
symbol calls `zanshin_jj::Repo::log_defaults()` and serialises the result with
`zanshin_ffi::log_defaults::log_defaults_to_envelope` (infallible, always
`ok == true`). The Dart worker command `LogDefaultsCommand` carries only the
`handleId`; the worker isolate calls the adapter and replies with the raw bytes
as a `BufferResult`, and the decode happens main-isolate-side in
`ZanshinWorker.logDefaults` via `decodeLogDefaultsEnvelopeInternal`
(`packages/zanshin_core/lib/src/ffi/log_defaults.dart`).

### `zanshin_log_defaults`

```c
ZanshinBuf* zanshin_log_defaults(uint64_t handle);
```

Handle-only — no C-string argument, so there is no `ffi.null_pointer` /
`ffi.utf8_error` path (the same asymmetry as `zanshin_remotes`).

**What "effective" means.** `zanshin-jj` rebuilds, per call, the layered config
the jj CLI would have at the pinned **v0.44.0** for that workspace and reads the
four values out of it:

| Layer (ascending precedence) | Source |
|------------------------------|--------|
| `ConfigSource::Default`      | jj-lib's own defaults + Zanshin's builtin layer (`[revsets] log` / `log-graph-prioritize`, `ui.log-synthetic-elided-nodes`, `ui.conflict-marker-style` (Story 9.4 — the style `zanshin_file_show` materializes a conflicted file with), and the CLI's 7-entry `[revset-aliases]` table, verbatim from `cli/src/config/{revsets,misc}.toml` @ v0.46.0) |
| `ConfigSource::System`       | `/etc/jj/config.toml`, `/etc/jj/conf.d/` — ONLY when `JJ_CONFIG` is unset (`cli/src/config.rs:334-345` @ v0.44.0). Non-existent entries are skipped silently. |
| `ConfigSource::EnvBase`      | `operation.hostname` / `operation.username` from `whoami` (the CLI's own crate; `$USER` as the username fallback), `NO_COLOR` (non-empty) → `ui.color = "never"`, `VISUAL` else `EDITOR` → `ui.editor` — values config files override |
| `ConfigSource::User`         | `JJ_CONFIG` (a `PATH`-style list of files and/or directories, which REPLACES discovery — including when it is the empty string, which disables user config entirely), else `$HOME/.jjconfig.toml`, `<config_dir>/jj/config.toml`, `<config_dir>/jj/conf.d/`. Non-existent entries are skipped silently. `<config_dir>` = `$XDG_CONFIG_HOME` when absolute, else `$HOME/.config`. |
| `ConfigSource::Repo`         | `.jj/repo/config-id` (20 ASCII hex chars) → `<config_dir>/jj/repos/<id>/config.toml`; absent id file → legacy `.jj/repo/config.toml` |
| `ConfigSource::Workspace`    | `.jj/workspace-config-id` → `<config_dir>/jj/workspaces/<id>/config.toml`; absent id file → legacy `.jj/workspace-config.toml` |
| `ConfigSource::EnvOverrides` | `JJ_USER` → `user.name`, `JJ_EMAIL` → `user.email`, `JJ_TIMESTAMP`, `JJ_RANDOMNESS_SEED`, `JJ_OP_TIMESTAMP`, `JJ_OP_HOSTNAME`, `JJ_OP_USERNAME`, `JJ_EDITOR`, `JJ_PAGER` — values that override every file (`cli/src/config.rs:789-819` @ v0.44.0) |

then flattens `--when` / `[[--scope]]` blocks through
`jj_lib::config::resolve`. **Read-only by construction:** the CLI reaches the
repo/workspace layer through `jj_lib::secure_config::SecureConfig`, whose
`maybe_load_config` writes (creates directories, writes `metadata.binpb`,
generates a `config-id`, copies configs on repo-copy detection, symlinks the
legacy file away); this symbol resolves the `config-id` → path indirection by hand
instead, so it creates, migrates or symlinks nothing. That write is the CLI's
start-up fix-up, which Zanshin runs where a command starts — at `zanshin_repo_open`
and at every snapshotting call (Story 9.37, see *`warnings`* above) — but NOT here:
`zanshin_log_defaults` runs no fix-up, so it reads the state as of the handle's last
open or snapshotting call (a repo copied or a secure directory deleted since is fixed
up only by the next such call). Not layered: the
`--config`/`--config-file` command-line layer (Zanshin has no command line).
`config_resolver::resolve` runs with `command: None`, so `--when.commands` scopes
never match; `hostname` is `whoami::hostname()`, so `--when.hostnames` scopes match
as in the CLI (Story 9.27).

**The same stack opens the workspace (Story 9.27).** `zanshin_repo_open` / `_init` /
`_clone` / `_convert` build the `UserSettings` jj-lib signs commits and operations
with — and its working-copy knobs (`fsmonitor.*`, `snapshot.*`) — from this stack
(creation paths: the user-level stack is checked first, as the CLI's start-up, then
resolved for the NEW workspace's paths, as the CLI's `settings_for_new_workspace` —
normally no repo or workspace file exists there yet, but `--when.repositories` /
`--when.workspaces` scopes already apply), and every
snapshotting call (see *`precondition`* above) re-derives them first when a stack file
or the environment changed. There is
no hardcoded identity and no `.gitconfig` fallback: an empty identity is jj-lib's
default and is reported per committing call as the `jj.identity_missing` warning
(Story 9.32).

**Re-read per call (ADR-0002 extended to config).** Nothing is cached: config
files change externally and the op-heads watcher does not cover them, so a file
edited between two calls on the same handle is visible in the second.

**Success payload:** `Envelope<LogDefaults>`.

```
LogDefaults {
  log:                  string   // revsets.log
  log_graph_prioritize: string   // revsets.log-graph-prioritize
  short_prefixes:       string   // revsets.short-prefixes (see below)
  synthetic_elided:     bool     // ui.log-synthetic-elided-nodes
}
```

- **`short_prefixes` fallback rule.** `revsets.short-prefixes` falls back to the
  EFFECTIVE `revsets.log` when the key is ABSENT from every layer — never when it
  is present but empty. An explicit `""` means "prefix disambiguation disabled"
  and is returned verbatim (`cli/src/cli_util.rs:987-1009`, the citation the
  implementing code carries at `crates/zanshin-jj/src/config.rs:407`).
- **These are offers, not policy (FR-JJ-17).** `zanshin_graph_topology`'s
  `revset` / `prioritize` / `short_prefixes` remain caller pass-throughs;
  nothing Rust-side substitutes a config value for a caller argument. The UI
  pre-fills from this read and the user edits. The Dart compile-time constants
  (`defaultLogRevset`, `defaultGraphPrioritize`, `defaultShortPrefixes`) stay as
  the BUILTIN pre-fills for a pre-handle UI; `RepoHandle.graphTopology`'s
  `prioritize` / `shortPrefixes` default to those builtin constants, not to this
  read (Dart defaults must be compile-time constants).
  `synthetic_elided` is the effective config value only: the topology call takes no
  such parameter (it emits no synthetic nodes), and the Dart `defaultSyntheticElided`
  constant was removed with the slice in Story 4.12.

**Error codes:**

| Code                  | Condition                                                                     |
|-----------------------|-------------------------------------------------------------------------------|
| `ffi.invalid_handle`  | Rust: `handle == 0`. Worker: unknown/closed `handleId`. `context` is absent.   |
| `jj.config_error`     | A config file is unreadable or not valid TOML, a `config-id` is not exactly 20 ASCII hex characters, or one of the four values has the wrong type; the file path or config key in `context`. Never a silent fall-back to the builtin defaults. |

The two `[revset-aliases]` failure levels differ, exactly as in the CLI:

- **Table level → error.** A layer whose `revset-aliases` key is not a table
  fails the call with `jj.config_error` (`cli/src/config.rs:1000-1007` @ v0.44.0, `ConfigGetError::Type`).
- **Entry level → warn and continue.** A single entry with a non-string value or
  a declaration jj-lib's parser rejects is skipped with a `jj.config_alias_invalid`
  warning (Story 9.32), and the call succeeds with every other alias loaded
  (`cli/src/config.rs:1009-1032` @ v0.44.0).
  A malformed alias DEFINITION is not caught at load time at all — it surfaces
  as `jj.revset_parse_error` when the alias is used.

**Dart worker integration:**

- `LogDefaultsCommand(handleId)` — worker looks up the raw handle (unknown id →
  `ffi.invalid_handle` envelope built Dart-side), calls
  `zanshinLogDefaults(raw)` (`lib/src/ffi/log_defaults.dart`), and replies
  `BufferResult` with the `Envelope<LogDefaults>` bytes.
- `ZanshinWorker.logDefaults(handleId)` → `LogDefaults` via
  `decodeLogDefaultsEnvelopeInternal`.
- `RepoHandle.logDefaults()` — closed-handle guard (`StateError`), delegates.
- Decode contract: `!ok` → `ZanshinFfiException(code, context)` carrying the
  envelope's `precondition` (always `null` here: this symbol runs no pre-verb
  snapshot) and `warnings` (Story 9.35); `ok` with a
  non-`LogDefaults` union variant → `ZanshinFfiException('ffi.unknown')`. Absent
  strings coalesce to `''`, so an explicitly empty `short_prefixes` and an
  absent one are indistinguishable Dart-side — Rust always writes all three.

## `CommitContents` payload and `zanshin_commit_contents` (Story 4.10)

The object half of a `jj log` row — author, committer timestamp, the FULL
description, conflict, empty — crosses FFI as a `CommitContents` member of the
`Payload` union (appended after `ConfigGcResult`; union member order is the wire
discriminant). The symbol calls `zanshin_jj::Repo::commit_contents` and serialises
the result (`crates/zanshin-ffi/src/commit_contents.rs::commit_contents_to_envelope`). The
view half (change id, prefix lengths, refs, flags, `parent_count`) and the edges
come from `zanshin_jj::Repo::graph_topology`, on the wire since Story 4.12 as
`zanshin_graph_topology` (above); the view composes the two calls.

### `zanshin_commit_contents`

```c
ZanshinBuf* zanshin_commit_contents(uint64_t handle, const uint8_t* data, uintptr_t len);
```

**A pinned read, framed as the continuation of the topology call's `jj log`.** The
CLI's `jj log` loads each row's commit object while it renders; Zanshin moves that
load out of the topology call and into this one, answering at the operation the
topology call returned (`GraphTopology.operation_id`) with `load_operation` +
`load_at` — never `load_at_head`, which prunes ancestor op heads and reconciles
divergent ones. So this symbol:

- runs NO pre-verb snapshot, import, config load or secure-config fix-up — its
  envelope carries NO `precondition` and NO `warnings`, on the ok arm and on every
  error arm alike, and `RepoHandle.lastPrecondition` is left untouched;
- writes no operation and no op head (like any load, `load_at` may write the
  operation's index files when they are missing);
- returns commit-intrinsic values only, so a head that moved since the topology
  call changes nothing — the caller re-requests the topology on the watcher's
  `OpHeadsChanged` (ADR-0002 Addendum 2026-09-30).

**Request:** `CommitContentsRequest { kind: CommitContents, operation_id, commit_ids }`.
Both are FULL hex ids — prefixes are not resolved (the caller got the full ids from
the topology call); uppercase hex is accepted. `operation_id` is required (row 4 of
the refusal ladder, `operation_id is required`); an absent or empty `commit_ids` is
an empty request. Interior NULs are guarded Dart-side (*Interior NUL* above); one
that reaches Rust is simply not hex.

**Check order** (after the ladder's rows 1–5):

| Order | Check | Code | `context` |
|-------|-------|------|-----------|
| a | `operation_id` is empty or not hex | `jj.invalid_input` | `Operation ID "<x>" is not a valid hexadecimal prefix` (the CLI's text) |
| a | `operation_id` is hex but not the op store's full length | `jj.invalid_input` | `Operation ID "<x>" is not a full operation ID` |
| b | the operation is not in the operation store | `jj.operation_not_found` | `No operation ID matching "<id>"` (the CLI's text) |
| b | the operation or its repo cannot be loaded | `jj.jj_lib_error` | jj-lib's reason |
| c | EVERY commit id: empty, not hex, or not the store's full length | `jj.invalid_input` | `Commit ID "<x>" is not a valid hexadecimal prefix` / `… is not a full commit ID` |
| c | then EVERY commit id: not in the pinned operation's index | `jj.change_not_found` | the caller's hex |
| d | a load: the commit, or — for `empty` — its parent | `jj.jj_lib_error` | jj-lib's reason |

Every id is validated before the first load, so a malformed id is refused wherever
it sits, and the index check is the only thing that separates an unknown id
(`jj.change_not_found`) from an indexed but unloadable one (`jj.jj_lib_error`) —
`get_commit_async` answers `ObjectNotFound` for both.

**Success payload:** `Envelope<CommitContents>`, one entry per requested id in
REQUEST order (not `jj log` order):

```
CommitContent {
  commit_id:                   string  // full hex, lowercase — the entry describes itself
  author_name:                 string  // may be ""
  author_email:                string  // may be ""
  committer_timestamp_millis:  long    // committer timestamp, millis since the Unix epoch
  committer_tz_offset_minutes: int     // minutes east of UTC
  description:                 string  // the FULL description; "" when empty
  conflict:                    bool
  empty:                       bool
}
```

Every string is always written. The root commit's entry carries jj-lib's fabricated
values, as `jj log` shows them: empty author name and email, an empty description, and a
committer timestamp of `0` (the epoch) with offset `0` — unlike the topology, which gives
the root no timestamp at all. `empty` is the one field that may load more than the
commit: `Commit::is_empty` asks jj's changed-path index first and otherwise loads the
parents and, for a merge, merges their trees.

**Dart worker integration:**

- `CommitContentsCommand(handleId, operationId, commitIds)` — worker looks up the raw
  handle (unknown id → `ffi.invalid_handle` envelope built Dart-side), calls
  `zanshinCommitContents(raw, operationId:, commitIds:)`
  (`lib/src/ffi/commit_contents.dart`), and replies `BufferResult`.
- `ZanshinWorker.commitContents(handleId, operationId:, commitIds:)` →
  `WarnedList<CommitContent>` (its `warnings` always empty) via
  `decodeCommitContentsEnvelopeInternal`; interior-NUL guards run on the calling side
  (`ArgumentError`) before `send`.
- `RepoHandle.commitContents(operationId:, commitIds:)` — closed-handle guard
  (`StateError`), delegates.
- Decode contract: `!ok` → `ZanshinFfiException(code, context)`; `ok` with a
  non-`CommitContents` union variant, an absent `contents` vector (Rust always writes it,
  an empty one included), or an entry missing a required string →
  `ZanshinFfiException('ffi.unknown', …)` — no `?? ''` / `?? const []` coercion.
- `defaultGraphAnchors` (`['trunk()', 'present(@)']`, `lib/src/ffi/graph.dart`) is the
  editable pre-fill for the topology call's required `anchors`
  (`RepoHandle.graphTopology`, Story 4.12); nothing applies it on its own.

## `Bookmarks` payload and `zanshin_bookmarks` (Story 9.29)

`zanshin_bookmarks` (handle-only, signature unchanged since Story 3.4b) returns the row set
`jj bookmark list --all-remotes` prints at the pinned v0.46.0 (`cli/src/commit_ref_list.rs::collect_items`
with every predicate open), sorted by name, then the `Local` row, then `Remote` rows by remote name:

- a `Local` row when the local target is present OR the name has at least one tracked remote ref —
  with an absent local target it is the CLI's `(deleted)` row and `target` is ABSENT;
- a `Remote` row for every tracked remote ref, synced or not, present or not — a tracked ref with an
  absent target is the CLI's `@origin (not created yet)` row, `target` ABSENT;
- a `Remote` row for every untracked remote ref (`tracked == false`).

`@git` is a remote like any other: no row is filtered and no sort key applied (both are Story 9.19's
or the UI's). Each `Bookmark` table carries:

| Field | Rows | Meaning |
|-------|------|---------|
| `target` | all | Change id (reverse-hex) of the target's first present add; ABSENT (null-for-absence) when the target is absent. |
| `conflicted` | all | The target is an unresolved conflict (`!RefTarget::is_resolved`). |
| `synced` | all | `Local`: every TRACKED remote ref points where the local does (true with none). `Remote`: tracked AND pointing where the local does; untracked → false. |
| `remote_name` | `Remote` | The remote, never fabricated (absent on a `Remote` row is corruption → `ffi.unknown` in Dart). |
| `tracked` | `Remote` | `RemoteRef::is_tracked`; false on `Local` rows. |
| `ahead` / `behind` | `Remote` | `RefDistance { lower, upper, has_upper }`, present only on a tracked row whose own target AND the local target are present (the template's `ref.present()` + `tracking_present()`). Direction is the REMOTE row's: `ahead` = commits the remote has that the local lacks (`walk_revs(remote, local)`), `behind` = the reverse. A synced row is `(0, 0)` without evaluating a revset; otherwise `Revset::count_estimate`, carried as-is — `has_upper == false` is the CLI's "at least `lower` commits" (presence pair: flatc 25.12.19 rejects optional scalars for Dart). |

The read is local (last-fetched remote targets, no network) and runs in the same `load_at_head` scope
as the listing; a failing distance revset is `jj.jj_lib_error`. Dart: `Bookmark.target` is
`String?`, `conflicted`/`synced` sit on `Bookmark`, `tracked`/`ahead`/`behind` on `RemoteBookmark`,
and `RefDistance.upper` is null when `has_upper` is false
(`packages/zanshin_core/lib/src/ffi/bookmarks.dart`).

---

## Edited editor text and `GitPushRemotes` (Story 9.54)

**Edited editor text.** `SquashRequest.edited_description` and `SplitRequest`'s
`edited_selected_description` / `edited_remaining_description` (appended at the end of both
tables) carry the user's edit of the text `zanshin_squash_plan` returns, or of split's two editor
texts. Each is the CLI's `--editor` whose editor saves exactly that text: the description step
runs as with the editor (`templates.commit_trailers` added, `templates.draft_commit_description`
rendered — their refusals and warnings included), then the edited text is written through
`cleanup_description_lines` (`JJ:` lines and blank edges dropped), with NO trailers added — `-m`
would add them again. Refusals, `jj.invalid_input`: `message` together with an edited text
("--message cannot be used with an edited description"; `zanshin_squash_plan` too, which otherwise
ignores the field) and, for split, one edited text without the other ("an edited split needs both
descriptions: the selected and the remaining"). A squash that moves nothing writes no description
(the CLI opens no editor). Dart: `RepoHandle.squash(editedDescription:)` and
`RepoHandle.split(editedSelectedDescription:, editedRemainingDescription:)`, interior-NUL guarded
on the calling side.

**`GitPushRemotes`.** `zanshin_git_push_remotes(handle)` answers `GitPushRemotes { names }`: the
remotes `jj git push` without `--remote` would push to, in remote-name order — `git.push` (a
name, a list or a pattern), else the single remote, else `origin`, each only when it exists
(`push.rs:294-323`, `get_default_push_remotes` `:1107-1130` @ v0.46.0, shared with
`zanshin_git_push`). Empty when none matches (the push itself refuses then) and on a non-Git
backend; an exact name no remote carries — a `git.push` name, or the implicit `origin` — warns
`jj.push_remotes_unmatched`, as the push does. Dart:
`RepoHandle.gitPushRemotes()` → `WarnedList<String>`; an absent `names` vector is
`ffi.unknown`. The app's project dot counts a tracked remote row with no target as "ahead" only
for these remotes (`trackingStatusOf`'s `pushRemotes`); the distances count for every tracked
remote.

---

## `RemoteChanges` payload and `zanshin_git_remote_changes` (Story 9.24)

`zanshin_git_remote_changes(handle, remote_name, cancel_token)` answers
`RemoteChanges { changes: [RemoteRefChange] }` without fetching: it runs `git ls-remote --heads
--tags -- <remote>` the way jj-lib runs every git (`git.executable-path`, `-c
core.fsmonitor=false -c submodule.recurse=false --git-dir <store>`, `LC_MESSAGES=C`, the adopted
environment plus the cancel token; `git_subprocess.rs:102-160` @ v0.46.0) and diffs the
advertisement against the head view's `<name>@<remote>` targets. `remote_name` must name a
configured remote exactly (else `jj.remote_not_found`, git never runs). Each `RemoteRefChange` is
`{ kind: RemoteRefKind (Bookmark | Tag), name, change: RemoteRefChangeKind (Moved | New | Deleted),
old_commit_ids: [string], new_commit_id: string }`: `New` has no old ids, `Deleted` an ABSENT
`new_commit_id`, `Moved` the view target's added ids (several for a conflicted target) and the
advertised commit. Branches are `refs/heads/*` except `HEAD`; tags are `refs/tags/*`, an annotated
tag at the commit its `^{}` line peels to. Order: bookmarks before tags, each by name; an empty
list means a fetch would bring nothing new. No pre-verb snapshot, no transaction, no operation of
its own (loading the head may reconcile divergent operation heads, as every jj command does); the
envelope carries the start-up fix-up's warnings and NO `precondition`. git's failure is
`jj.network_error` with jj-lib's own text (`External git program failed:` + stderr, or the spawn
error); output that is not a ref advertisement is `jj.jj_lib_error`. Only the refs a bare
`zanshin_git_fetch` of the remote would fetch take part (Story 9.30): the remote's
`remotes.<name>.fetch-bookmarks`, else its Git fetch refspecs (the ones jj ignores dropped
silently), and `remotes.<name>.fetch-tags`, else every tag — both the advertised names and the
view's are filtered, so a malformed setting is `jj.config_error` and an unreadable Git remote
configuration `jj.invalid_input`. A tag of a non-commit object reads "new" on every poll. Dart: `RepoHandle.remoteChanges(remoteName)`
→ `NetworkOperation<WarnedList<RemoteRefChange>>`, on the worker's helper isolate like a fetch
(progress operation `remote_changes`, no events).

## `GitFetchResult` payload and `zanshin_git_fetch` (Story 9.30)

`zanshin_git_fetch` is the CLI's `jj git fetch` at v0.46.0 (`cmd_git_fetch`) with its parameters
passed through as `GitFetchRequest`, whose two enums make the CLI's clap conflicts
unrepresentable:

| Field | Meaning |
|-------|---------|
| `remotes_mode` | `Default` (no `--remote`: `git.fetch` — a list or a string of name patterns —, else the only remote, else `origin`), `Named` (`--remote`: the union of the `remotes` patterns; a bare word is a glob), `All` (`--all-remotes`). |
| `refs_mode` | `Default` (per remote: `remotes.<name>.fetch-bookmarks`, else the Git config's fetch refspecs; `remotes.<name>.fetch-tags`, else every tag), `Patterns` (`-b` / `-t`: the `branches` / `tags` unions; an absent or empty list fetches none of that kind), `Tracked` (`--tracked`: the bookmarks and tags tracked from each remote, by exact name). |
| `cancel_token` | See § Cancel. |

An exact remote name no remote carries warns `jj.fetch_remotes_unmatched` ("No matching remotes
for names: a, b"); no match at all refuses `jj.invalid_input` "No git remotes to fetch from"
BEFORE any transaction — also for a `Named` miss, which was `jj.remote_not_found` before Story 9.30
(CLI parity). Then ONE transaction: each remote is fetched (its ignored Git refspecs warn
`jj.fetch_refspec_ignored`), the refs are imported once (`jj.git_import_failed`), with `Patterns`
the branch names no matched remote has warn `jj.fetch_branches_unmatched`, and the operation is
`fetch from git remote(s) <names as symbols joined by ",">` — also when nothing changed (the
tracked 9.40 divergence). The answer is `GitFetchResult`:

| Field | Meaning |
|-------|---------|
| `mutation` | The shared `MutationResult`; `abandoned_change_ids` are the commits the import abandoned (`git.abandon-unreachable-commits`). |
| `remotes` | The remotes fetched from, in remote-name order. |
| `hints` | The CLI's hints, verbatim: "Fetching from the only existing remote: R" (when that remote is not `origin`). |
| `failed_ref_names` | The Git refs the import could not read, lossy UTF-8 — what `jj.git_import_failed` lists. |

`zanshin_git_fetch_remotes(handle)` answers `GitFetchRemotes { names }` with the `Default`
resolution alone — the Fetch button's enable rule: empty when none matches (warning
`jj.fetch_remotes_unmatched`, as the fetch warns it) and on a non-Git backend; the hint is not
reported; no operation of its own. Dart: `RepoHandle.gitFetch({remotes, refs})` →
`NetworkOperation<GitFetchResult>` (sealed `FetchRemotes` / `FetchRefs`), and
`RepoHandle.gitFetchRemotes()` → `WarnedList<String>`.

## `DropActions` / `ChangeActions` payloads (Story 9.31)

The capability query the graph's drag-and-drop and card menu ask BEFORE anything runs.
`zanshin_drop_actions` takes a `DropActionsRequest` — the source (`source_kind` `Change` with
`change_id`, `Selection` with `change_id` + `paths`, or `Bookmark` with `bookmark`; a field the kind
needs that is absent is `jj.invalid_input` "<field> is required") and the `locations`, each a
`DropLocation` with the CLI's `onto` / `insert_after` / `insert_before` (absent or empty = the flag
not given). A location that gives `onto` with an insert list, or none of the three, refuses the
WHOLE call `jj.invalid_input` with `compute_commit_location`'s text, before anything resolves.
`zanshin_change_actions(handle, change_id)` takes the change id as a C string.

Every row is answered by the verb's own plan — the fn the verb runs before its first write — on
its own transaction from one head, dropped afterwards: neither call writes an operation of its
own, only the pre-verb snapshot's, and the envelope's warnings are the precondition's only.

| Table | Fields |
|-------|--------|
| `DropActions` | `actions: [DropAction]` — every location's rows, in location order. |
| `DropAction` | `verb: DropVerb`, `location: uint` (index into the request's `locations`), `outcome: ActionOutcome`. |
| `ChangeActions` | Seven `ActionOutcome`s, always present: `new_onto` (`new X`), `new_insert_after` (`new -A X`), `new_insert_before` (`new -B X`), `edit`, `describe`, `squash_into_parent` (`squash -r X`), `abandon`. |
| `ActionOutcome` | `status: ActionStatus` (`Available`, `NoOp`, `Refused`), `refusal: FfiError` (present exactly for `Refused`), `combined_description_needed` (a squash row: two or more non-empty descriptions would be combined — `zanshin_squash_plan` returns the text), `allow_backwards_needed` (a bookmark row: the move is not a fast-forward). |

The rows per location (`DropVerb`, append-only): a `Change` at `onto` — `RebaseSource`
(`rebase -s S -o T…`), `RebaseRevisions` (`rebase -r S -o T…`), `Squash` (`squash --from S --into
T`, only for exactly one target), `NewMerge` (`new T… S`), `Duplicate` (`duplicate S -o T…`); a
`Change` at `-A`/`-B` — `RebaseRevisions`. A `Selection` at `onto` with one target — `Squash` with
the paths; at `-A`/`-B` — `Split` (`split -r S <paths> -A/-B …`). A `Bookmark` at `onto` with one
target — `BookmarkMove` (`bookmark move N --to T`). `NoOp` means the verb would write no
operation (a rebase whose planned move changes nothing, a squash with nothing to squash, a
bookmark already at the target or of a name no local bookmark has); only those three report it.

A row's `refusal` is the `FfiError` the verb's own wrapper returns, mapped through the same
`map_mutate_err` — same code, same `context` (`jj.invalid_input`, `jj.change_not_found` for an id
that does not resolve, `jj.immutable`, `jj.config_error`). A jj-lib failure in any row fails the
whole call `jj.jj_lib_error`. Dart: `RepoHandle.dropActions(source, locations)` → `DropActions`
(sealed `DropSource`: `ChangeDropSource` / `SelectionDropSource` / `BookmarkDropSource`; a refusal
is an `ActionRefusal(code, context)`), `RepoHandle.changeActions(changeId)` → `ChangeActions`.

## `GitPushResult` payload and `zanshin_git_push` (Story 9.20)

`zanshin_git_push` is the CLI's `jj git push` at v0.46.0 with every parameter passed through
(`GitPushRequest`: `remotes` — ABSENT = `--remote` not given —, `bookmarks`, `tags`, `all`,
`tracked`, `deleted`, the three `allow_*`, `revisions`, `changes`, `named`, `dry_run`, `options`).
It runs the pre-verb snapshot, then ONE transaction whose planning phase — remotes, the
`--change` / `--named` bookmarks, the targets of the mode, the classification per remote, the
commit checks, the operation description — is shared by the dry run and the real run. A refusal
before the network is an error envelope (`jj.invalid_input`, `jj.push_ref_refused`,
`jj.push_commit_rejected`, …); once the push loop has started, the outcome is DATA on an ok
envelope:

| Field | Meaning |
|-------|---------|
| `remotes` | `PushRemote` per matched remote, sorted: `name`, `refs`, `already_matches` (explicit refs already where the push would put them — the CLI's "Bookmark N@R already matches N"), `finished` (the push to it ran), `error` (the CLI's `GitPushError` text that stopped the push there). |
| `PushRef` | `kind` (`Bookmark`/`Tag`), `name`, `before` / `after` (full hex, ABSENT when absent there, or for a ref refused as conflicted or untracked), `action` (jj's words: "move forward/backward/sideways from <old> to <new>", "add to <new>", "delete from <old>"), `path` (`Push`, `Skip` — the mode refused it and warned —, `Abort` — an explicit ref refused, dry run only), `refusal` / `explicit_refusal` (`PushRefusal { message, hint }` verbatim; the second is what `-b`/`-t` would get — ABSENT = tickable), `rejection` (`PushCommitRejection { commit_id, reasons, message, hints }`), `status` (`NotReached`, `Pushed`, `LeaseRejected`, `RemoteRejected`, `Unexported`) and `status_reason`. |
| `created_bookmarks` | The bookmarks `--change` created (`name`, `change_id`). |
| `hints` | Hints a UI shows verbatim: "Pushing to the only existing remote: R", the push-stats hints. |
| `signing` | `PushSigning { updated_signatures, rebased_descendants }` when sign-on-push signed; ABSENT otherwise. |
| `nothing_changed` / `dry_run` / `recorded` | The CLI's "Nothing changed."; a plan; the operation was written (only when every ref succeeded or one was exported — "Undo works"). |
| `description` / `new_op_id` | The operation's description (a dry run's: the one the real push writes; ABSENT when nothing changed) and the head after the call. |
| `failure` | `PushFailure { kind, message, hint }`: `RefRefused` / `CommitRejected` (a dry run's explicit refusal), `SomeRefsFailed` ("Failed to push some bookmarks", possibly recorded), `PushError` (stopped at a remote; nothing recorded), `Cancelled` (Story 9.52: the push's cancel token was cancelled — it stopped before the next remote, nothing recorded; see § Cancel). ABSENT on full success. |

Warnings: `jj.push_remotes_unmatched`, `jj.push_bookmarks_unmatched`, `jj.push_tags_unmatched`,
`jj.push_revset_empty`, `jj.push_revisions_empty`, `jj.push_ref_skipped`, `jj.push_commit_skipped`,
`jj.push_signing_skipped_immutable`, `jj.push_refs_moved_on_remote`, `jj.push_remote_rejected`,
`jj.push_bookmarks_not_updated_locally`, plus the finish's. Dart: `RepoHandle.gitPush(...)` →
`NetworkOperation<GitPushResult>` (Story 9.52; `GitPushResult` in
`packages/zanshin_core/lib/src/ffi/push.dart`).

`zanshin_repo_init` (`RepoInitRequest`: `path`, `backend`, `colocate` / `no_colocate`,
`object_hash`) and `zanshin_repo_clone` (`RepoCloneRequest`: `source`, `destination`,
`remote_name`, `colocate` / `no_colocate`, `depth` — 0 = absent —, `branches` / `tags` — ABSENT =
the flag not given —, `object_hash`, and since Story 9.52 `cancel_token`) take request buffers
since Story 9.20 and follow `jj git init` / `jj git clone` step for step: the destination rules, colocation by `git.colocate`, the clone's
three operations and repo presets, its clean-up scope. Both colocation flags set is
`jj.invalid_input`.
