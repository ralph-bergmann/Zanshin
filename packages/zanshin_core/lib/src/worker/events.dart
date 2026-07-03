// SPDX-License-Identifier: MIT

/// Public event family surfaced on `ZanshinWorker.events` (Story 3.6).
///
/// Demuxed from the raw FFI-side `ZanshinRawEvent` (`ffi/events.dart`) by the
/// worker: `rawRepoHandle` is mapped to the small dense `handleId` the main
/// isolate already knows (Model A — raw pointers never reach main). Every
/// field is `int`/`String`/`List<String>`/`double` — sendable across the
/// isolate port without copying concerns.
sealed class RepoEvent {
  const RepoEvent(this.handleId);

  /// Opaque dense handle id (matches `RepoHandle.handleId`).
  final int handleId;
}

/// One or more files changed under `.jj/repo/op_heads/heads/` — a jj
/// operation was committed (FR-RX-1).
final class OpHeadsChangedEvent extends RepoEvent {
  const OpHeadsChangedEvent(super.handleId, this.paths);

  /// Paths that changed.
  final List<String> paths;
}

/// The working-copy checkout file changed — fires on any jj activity
/// (heartbeat, not necessarily an `op_heads` change).
final class WorkingCopyHeartbeatEvent extends RepoEvent {
  const WorkingCopyHeartbeatEvent(super.handleId, this.paths);

  /// Paths that changed.
  final List<String> paths;
}

/// The filesystem-watch subsystem for this repo encountered an error.
///
/// A degraded-watch signal, not a failed call — no `error.code` accompanies
/// this event (see `docs/rust-error-codes.md`'s `watcher.io_error` note: that
/// code is reserved exclusively for the arming-failure error envelope).
final class WatchErrorEvent extends RepoEvent {
  const WatchErrorEvent(super.handleId, this.message);

  /// Human-readable error description.
  final String message;
}

/// Progress notification for a long-running operation (FR-FFI-8), e.g. `git
/// fetch`. No producer exists yet — the first real one lands in Story 6-4a.
final class ProgressEvent extends RepoEvent {
  const ProgressEvent(super.handleId, this.operation, this.progress, this.message);

  /// The operation name, e.g. `"fetch"`.
  final String operation;

  /// Fractional completion in `[0, 1]`.
  final double progress;

  /// Human-readable status message.
  final String message;
}
