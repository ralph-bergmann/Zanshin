// SPDX-License-Identifier: MIT

//! `zanshin_op_log` — operation-log read FFI wrapper (Story 3.4b, `op_log` slice).
//!
//! Calls `zanshin_jj::Repo::op_log(limit)` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying an `OpLog` payload. The handle is borrowed
//! (not consumed). `limit` is a fixed scalar (negative ⇒ all).

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{OpLogError, Operation};

use crate::envelope::{catch, FfiErrorObj, FFI_INVALID_HANDLE, JJ_JJ_LIB_ERROR};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::handle::handle_from_raw;
use crate::repo::RepoSession;

fn map_op_log_err(e: OpLogError) -> FfiErrorObj {
    match e {
        OpLogError::Backend(reason) => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

/// Serialise `&[Operation]` into a finished `Envelope<OpLog>` buffer.
///
/// Children before parents (`FlatBuffers` requirement): for each `Operation`, its
/// strings and `parent_ids` vector are built before its table; the `operations`
/// vector and `OpLog` table are built after the loop.
fn op_log_to_envelope(ops: &[Operation]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let mut op_offsets = Vec::with_capacity(ops.len());
    for op in ops {
        let id_off = b.create_string(&op.id.0);
        let parent_offs: Vec<_> = op.parent_ids.iter().map(|p| b.create_string(&p.0)).collect();
        let parents_vec = b.create_vector(&parent_offs);
        let user_off = b.create_string(&op.user);
        let host_off = b.create_string(&op.host);
        let desc_off = b.create_string(&op.description);
        let op_off = fbs::Operation::create(
            &mut b,
            &fbs::OperationArgs {
                id: Some(id_off),
                parent_ids: Some(parents_vec),
                timestamp_millis: op.timestamp.millis_since_epoch,
                tz_offset_minutes: op.timestamp.tz_offset_minutes,
                user: Some(user_off),
                host: Some(host_off),
                description: Some(desc_off),
                root_op: op.root_op,
                is_snapshot: op.is_snapshot,
            },
        );
        op_offsets.push(op_off);
    }
    let ops_vec = b.create_vector(&op_offsets);
    let oplog_off = fbs::OpLog::create(
        &mut b,
        &fbs::OpLogArgs {
            operations: Some(ops_vec),
        },
    );
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::OpLog,
            data: Some(oplog_off.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// Read the operation log of the repo identified by `handle`.
///
/// `limit < 0` ⇒ all operations; `limit >= 0` ⇒ at most `limit` most-recent ops.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` or the borrow yields `None`.
/// - `jj.jj_lib_error` — an unclassified jj-lib error; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, or `zanshin_repo_clone` that has not been closed.
/// `0` is detected and returned as `ffi.invalid_handle`.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_op_log(handle: u64, limit: i64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_op_log", handle, limit);
    let buf = catch(|| {
        // SAFETY: non-zero handle originated from arm_session's handle_into_raw
        // (Box<RepoSession>) in zanshin_repo_open/init/clone/convert; single-isolate
        // model (AD-2) guarantees no concurrent access.
        let session =
            unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }.ok_or_else(|| FfiErrorObj {
                code: FFI_INVALID_HANDLE.to_owned(),
                context: None,
            })?;
        // limit < 0 ⇒ None (all); 0 ⇒ Some(0); n ⇒ Some(n). No `as` cast (clippy-clean).
        let ops = session
            .repo
            .op_log(usize::try_from(limit).ok())
            .map_err(map_op_log_err)?;
        Ok(op_log_to_envelope(&ops))
    });
    vec_into_token(buf)
}

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use zanshin_jj::{OpLogError, Operation, OperationId, Timestamp};

    use super::{map_op_log_err, op_log_to_envelope};
    use crate::fbs;
    use crate::JJ_JJ_LIB_ERROR;

    #[allow(clippy::too_many_arguments)]
    fn make_op(
        id: &str,
        parent_ids: Vec<&str>,
        millis: i64,
        tz: i32,
        user: &str,
        host: &str,
        desc: &str,
        root_op: bool,
        is_snapshot: bool,
    ) -> Operation {
        Operation {
            id: OperationId(id.to_owned()),
            parent_ids: parent_ids.into_iter().map(|p| OperationId(p.to_owned())).collect(),
            timestamp: Timestamp {
                millis_since_epoch: millis,
                tz_offset_minutes: tz,
            },
            user: user.to_owned(),
            host: host.to_owned(),
            description: desc.to_owned(),
            root_op,
            is_snapshot,
        }
    }

    #[test]
    fn op_log_to_envelope_roundtrips_all_fields() {
        let root_op = make_op("aabbcc", vec![], 0, 0, "", "", "", true, false);
        let non_root = make_op(
            "ddeeff",
            vec!["aabbcc"],
            1_700_000_000_000,
            60,
            "alice",
            "host.local",
            "new empty commit",
            false,
            false,
        );
        let multi_parent = make_op(
            "112233",
            vec!["ddeeff", "aabbcc"],
            1_700_000_001_000,
            -120,
            "bob",
            "builder",
            "snapshot working copy",
            false,
            true,
        );

        let ops = vec![multi_parent.clone(), non_root.clone(), root_op.clone()];
        let buf = op_log_to_envelope(&ops);

        let env = fb_root::<fbs::Envelope>(&buf).expect("FlatBuffers Verifier must pass");
        assert!(env.ok(), "envelope must be ok");
        assert_eq!(env.data_type(), fbs::Payload::OpLog, "data_type must be OpLog");

        let payload = env.data_as_op_log().expect("data_as_op_log must succeed");
        let fbs_ops = payload.operations().expect("operations must be present");
        assert_eq!(fbs_ops.len(), 3, "must have 3 operations");

        // multi_parent op
        let fbs_mp = fbs_ops.get(0);
        assert_eq!(fbs_mp.id(), Some("112233"), "multi-parent id");
        let pids: Vec<_> = fbs_mp.parent_ids().map(|v| v.iter().collect()).unwrap_or_default();
        assert_eq!(pids, vec!["ddeeff", "aabbcc"], "multi-parent parent_ids");
        assert_eq!(fbs_mp.timestamp_millis(), 1_700_000_001_000, "multi-parent timestamp");
        assert_eq!(fbs_mp.tz_offset_minutes(), -120, "multi-parent tz");
        assert_eq!(fbs_mp.user(), Some("bob"), "multi-parent user");
        assert_eq!(fbs_mp.host(), Some("builder"), "multi-parent host");
        assert_eq!(fbs_mp.description(), Some("snapshot working copy"), "multi-parent desc");
        assert!(!fbs_mp.root_op(), "multi-parent root_op must be false");
        assert!(fbs_mp.is_snapshot(), "multi-parent is_snapshot must be true");

        // non-root op
        let fbs_nr = fbs_ops.get(1);
        assert_eq!(fbs_nr.id(), Some("ddeeff"), "non-root id");
        let nr_pids: Vec<_> = fbs_nr.parent_ids().map(|v| v.iter().collect()).unwrap_or_default();
        assert_eq!(nr_pids, vec!["aabbcc"], "non-root parent_ids");
        assert_eq!(fbs_nr.timestamp_millis(), 1_700_000_000_000, "non-root timestamp");
        assert_eq!(fbs_nr.tz_offset_minutes(), 60, "non-root tz");
        assert!(!fbs_nr.root_op(), "non-root root_op must be false");
        assert!(!fbs_nr.is_snapshot(), "non-root is_snapshot must be false");

        // root op
        let fbs_root = fbs_ops.get(2);
        assert_eq!(fbs_root.id(), Some("aabbcc"), "root id");
        let root_pids: Vec<_> = fbs_root.parent_ids().map(|v| v.iter().collect()).unwrap_or_default();
        assert!(root_pids.is_empty(), "root parent_ids must be empty");
        assert!(fbs_root.root_op(), "root root_op must be true");
        assert_eq!(fbs_root.description(), Some(""), "root description must be empty");
    }

    #[test]
    fn map_op_log_err_backend_maps_to_jj_lib_error() {
        let obj = map_op_log_err(OpLogError::Backend("boom".into()));
        assert_eq!(obj.code, JJ_JJ_LIB_ERROR, "code must be jj.jj_lib_error");
        assert_eq!(obj.context, Some("boom".to_owned()), "context must be forwarded");
    }
}
