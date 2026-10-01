//! Input parsing and validation (SPEC §2): JSON bytes → flat, index-addressed arrays.

use serde::Deserialize;

/// Every integer in input and output lies in [−2^53, 2^53] (SPEC §1).
pub const MAX_ABS: i64 = 1 << 53;

/// A parent edge's kind, as jj's graph iterator yields it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// A visible parent.
    Direct,
    /// The nearest visible ancestor through hidden commits (drawn dashed).
    Indirect,
    /// No visible ancestor; not a layout edge.
    Missing,
}

impl Kind {
    /// The canonical JSON string.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Direct => "direct",
            Kind::Indirect => "indirect",
            Kind::Missing => "missing",
        }
    }
}

/// The validated input as flat arrays. Parents are CSR: node `i`'s parents are
/// `par_idx[par_off[i]..par_off[i + 1]]` in stream order (`-1` for a missing parent).
#[derive(Debug, Default)]
pub struct Input {
    /// The fixed "now" (time mode only).
    pub now_ms: i64,
    /// The viewer's fixed UTC offset in minutes (time and free mode; free since 2026-10-01).
    pub utc_offset_min: i64,
    /// Committer timestamp in epoch ms; meaningless where `has_ts` is false.
    pub ts: Vec<i64>,
    /// False where `ts_ms` is null.
    pub has_ts: Vec<bool>,
    /// True for the `root()` commit.
    pub is_root: Vec<bool>,
    /// Ordering class, `0 <= priority < 2^31`.
    pub priority: Vec<i32>,
    /// CSR offsets into `par_idx` / `par_kind`, length n + 1.
    pub par_off: Vec<u32>,
    /// Parent node index, or -1 for `missing`.
    pub par_idx: Vec<i32>,
    /// Parent edge kind.
    pub par_kind: Vec<Kind>,
}

impl Input {
    /// Number of nodes.
    #[must_use]
    pub fn len(&self) -> usize {
        self.priority.len()
    }

    /// True when there are no nodes.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.priority.is_empty()
    }
}

#[derive(Deserialize)]
struct RawInput {
    now_ms: i64,
    utc_offset_min: i64,
    nodes: Vec<RawNode>,
}

// `deserialize_with = "Option::deserialize"` makes a nullable field required: without it serde
// reads an absent key as `null` (SPEC §2, clarified during diff: only `id` may be absent).
#[derive(Deserialize)]
struct RawNode {
    #[serde(deserialize_with = "Option::deserialize")]
    ts_ms: Option<i64>,
    is_root: bool,
    priority: i64,
    parents: Vec<RawParent>,
}

#[derive(Deserialize)]
struct RawParent {
    #[serde(deserialize_with = "Option::deserialize")]
    idx: Option<i64>,
    kind: Kind,
}

/// V4 (clarified during diff): a real UTC offset, so `utc_offset_min · 60000` cannot overflow.
pub const MAX_UTC_OFFSET_MIN: i64 = 1440;

fn check_abs(what: &str, v: i64) -> Result<(), String> {
    if (-MAX_ABS..=MAX_ABS).contains(&v) {
        Ok(())
    } else {
        Err(format!("V4: {what} = {v} is outside ±2^53"))
    }
}

/// The typed parse. Two kinds of valid JSON (§2: "any valid JSON") fail it, so a failed parse is
/// retried; only documents the fast path rejects pay for that:
/// - duplicate keys (serde's derive rejects them): the retry goes through `Value`, which keeps
///   the last duplicate like `JSON.parse` and `dart:convert`;
/// - the integer `-0`, which serde_json reads as the float −0.0 (dart:convert: the int 0): the
///   retry rewrites it to `0` first (stage-3 diff, SPEC §2 clarification).
///
/// The whole document is UTF-8-checked first: serde_json skips strings it ignores (`id`, unknown
/// keys) unchecked, where dart:convert's fused decoder rejects invalid UTF-8 (stage-3 diff).
fn parse_raw(bytes: &[u8]) -> Result<RawInput, String> {
    let text = std::str::from_utf8(bytes).map_err(|e| format!("invalid input JSON: not UTF-8: {e}"))?;
    serde_json::from_str(text).or_else(|typed| {
        let fixed = neg_zero_to_zero(text);
        let text = fixed.as_deref().unwrap_or(text);
        serde_json::from_str(text)
            .or_else(|_| serde_json::from_str::<serde_json::Value>(text).and_then(serde_json::from_value))
            .map_err(|_| format!("invalid input JSON: {typed}"))
    })
}

/// Rewrites every number token `-0` (no fraction, exponent or further digit) outside strings to
/// ` 0`; `None` when there is none. `-0.0` and `-0e0` stay floats and stay invalid.
fn neg_zero_to_zero(text: &str) -> Option<String> {
    let mut out = text.as_bytes().to_vec();
    let (mut in_str, mut esc, mut changed) = (false, false, false);
    for k in 0..out.len() {
        let b = out[k];
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
            }
        } else if b == b'"' {
            in_str = true;
        } else if b == b'-'
            && out.get(k + 1) == Some(&b'0')
            && !matches!(out.get(k + 2), Some(b'.' | b'e' | b'E' | b'0'..=b'9'))
        {
            out[k] = b' ';
            changed = true;
        }
    }
    changed.then(|| String::from_utf8(out).expect("an ASCII-for-ASCII edit keeps UTF-8"))
}

/// Parses and validates (V1–V4) an input document into fresh flat arrays.
///
/// # Errors
/// A message for malformed JSON, a missing or mistyped field, or a V1–V4 violation.
pub fn parse_input(bytes: &[u8]) -> Result<Input, String> {
    let raw = parse_raw(bytes)?;
    check_abs("now_ms", raw.now_ms)?;
    if !(-MAX_UTC_OFFSET_MIN..=MAX_UTC_OFFSET_MIN).contains(&raw.utc_offset_min) {
        return Err(format!("V4: utc_offset_min = {} is outside ±1440", raw.utc_offset_min));
    }
    let n = raw.nodes.len();
    if n >= (1usize << 31) {
        return Err(format!("too many nodes: {n}"));
    }
    let total_parents: usize = raw.nodes.iter().map(|node| node.parents.len()).sum();
    let mut input = Input {
        now_ms: raw.now_ms,
        utc_offset_min: raw.utc_offset_min,
        ts: Vec::with_capacity(n),
        has_ts: Vec::with_capacity(n),
        is_root: Vec::with_capacity(n),
        priority: Vec::with_capacity(n),
        par_off: Vec::with_capacity(n + 1),
        par_idx: Vec::with_capacity(total_parents),
        par_kind: Vec::with_capacity(total_parents),
    };
    input.par_off.push(0);
    // seen[j] == i + 1 ⇔ node i already lists parent j (V3), without clearing per node.
    let mut seen = vec![0u32; n];
    for (i, node) in raw.nodes.into_iter().enumerate() {
        if let Some(ts) = node.ts_ms {
            check_abs("ts_ms", ts)?;
        }
        // V4 bounds priority above; the field contract (§2 table: "ordering class ≥ 0")
        // bounds it below, which also makes it fit the Int32 fairness layout (§8.3).
        if !(0..(1i64 << 31)).contains(&node.priority) {
            return Err(format!("V4: node {i}: priority {} is outside [0, 2^31)", node.priority));
        }
        input.ts.push(node.ts_ms.unwrap_or(0));
        input.has_ts.push(node.ts_ms.is_some());
        input.is_root.push(node.is_root);
        input
            .priority
            .push(i32::try_from(node.priority).expect("range-checked"));
        for parent in node.parents {
            match (parent.idx, parent.kind) {
                (None, Kind::Missing) => input.par_idx.push(-1),
                (Some(idx), Kind::Direct | Kind::Indirect) => {
                    // V2 (which also implies V4 for idx): i < idx < n.
                    if idx <= i as i64 || idx >= n as i64 {
                        return Err(format!("V2: node {i}: parent idx {idx} not in ({i}, {n})"));
                    }
                    let j = usize::try_from(idx).expect("range-checked");
                    if seen[j] == i as u32 + 1 {
                        return Err(format!("V3: node {i}: parent idx {idx} listed twice"));
                    }
                    seen[j] = i as u32 + 1;
                    input.par_idx.push(i32::try_from(idx).expect("range-checked"));
                }
                (idx, kind) => {
                    return Err(format!(
                        "V1: node {i}: idx {} with kind {}",
                        idx.map_or_else(|| "null".to_owned(), |v| v.to_string()),
                        kind.as_str()
                    ));
                }
            }
            input.par_kind.push(parent.kind);
        }
        input
            .par_off
            .push(u32::try_from(input.par_idx.len()).map_err(|_| "too many parents".to_owned())?);
    }
    Ok(input)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn err(json: &str) -> String {
        parse_input(json.as_bytes()).expect_err("must be rejected")
    }

    #[test]
    fn parses_flat_arrays_any_key_order_and_whitespace() {
        let json = r#"
        { "nodes": [
            {"parents": [{"kind": "direct", "idx": 1}, {"idx": null, "kind": "missing"}],
             "priority": 2, "is_root": false, "ts_ms": 5, "id": "ab"},
            {"id": "00", "ts_ms": null, "is_root": true, "priority": 0, "parents": []}
          ],
          "utc_offset_min": -120, "now_ms": 10 }"#;
        let input = parse_input(json.as_bytes()).unwrap();
        assert_eq!(input.len(), 2);
        assert_eq!(input.now_ms, 10);
        assert_eq!(input.utc_offset_min, -120);
        assert_eq!(input.ts, vec![5, 0]);
        assert_eq!(input.has_ts, vec![true, false]);
        assert_eq!(input.is_root, vec![false, true]);
        assert_eq!(input.priority, vec![2, 0]);
        assert_eq!(input.par_off, vec![0, 2, 2]);
        assert_eq!(input.par_idx, vec![1, -1]);
        assert_eq!(input.par_kind, vec![Kind::Direct, Kind::Missing]);
    }

    #[test]
    fn duplicate_keys_keep_the_last_value_like_js_and_dart() {
        let input = parse_input(
            br#"{"now_ms":1,"utc_offset_min":0,"now_ms":7,"nodes":[{"ts_ms":1,"is_root":false,"priority":3,"priority":2,"parents":[]}]}"#,
        )
        .unwrap();
        assert_eq!(input.now_ms, 7);
        assert_eq!(input.priority, vec![2]);
        // A document broken beyond its duplicates is still rejected.
        assert!(err(r#"{"now_ms":0,"now_ms":1,"nodes":[]}"#).starts_with("invalid input JSON"));
    }

    #[test]
    fn empty_graph_is_valid() {
        let input = parse_input(br#"{"now_ms":0,"utc_offset_min":0,"nodes":[]}"#).unwrap();
        assert!(input.is_empty());
        assert_eq!(input.par_off, vec![0]);
    }

    #[test]
    fn rejects_v1_idx_kind_mismatch() {
        let base = r#"{"now_ms":0,"utc_offset_min":0,"nodes":[{"ts_ms":1,"is_root":false,"priority":0,"parents":[PAR]},{"ts_ms":null,"is_root":true,"priority":0,"parents":[]}]}"#;
        assert!(err(&base.replace("PAR", r#"{"idx":null,"kind":"direct"}"#)).starts_with("V1"));
        assert!(err(&base.replace("PAR", r#"{"idx":1,"kind":"missing"}"#)).starts_with("V1"));
        assert!(err(&base.replace("PAR", r#"{"idx":1,"kind":"bogus"}"#)).starts_with("invalid input JSON"));
    }

    #[test]
    fn rejects_v2_v3_v4() {
        let base = r#"{"now_ms":NOW,"utc_offset_min":0,"nodes":[{"ts_ms":1,"is_root":false,"priority":PRIO,"parents":[PAR]},{"ts_ms":null,"is_root":true,"priority":0,"parents":[]}]}"#;
        let ok = |s: &str| s.replace("NOW", "0").replace("PRIO", "0");
        assert!(err(&ok(base).replace("PAR", r#"{"idx":0,"kind":"direct"}"#)).starts_with("V2"));
        assert!(err(&ok(base).replace("PAR", r#"{"idx":2,"kind":"direct"}"#)).starts_with("V2"));
        assert!(
            err(&ok(base).replace("PAR", r#"{"idx":1,"kind":"direct"},{"idx":1,"kind":"indirect"}"#)).starts_with("V3")
        );
        let par = r#"{"idx":1,"kind":"direct"}"#;
        assert!(err(&base
            .replace("NOW", "9007199254740993")
            .replace("PRIO", "0")
            .replace("PAR", par))
        .starts_with("V4"));
        assert!(err(&base
            .replace("NOW", "0")
            .replace("PRIO", "2147483648")
            .replace("PAR", par))
        .starts_with("V4"));
        assert!(err(&base.replace("NOW", "0").replace("PRIO", "-1").replace("PAR", par)).starts_with("V4"));
        // Two missing parents are fine: V3 concerns non-null idx only.
        let two_missing = ok(base).replace("PAR", r#"{"idx":null,"kind":"missing"},{"idx":null,"kind":"missing"}"#);
        assert!(parse_input(two_missing.as_bytes()).is_ok());
    }

    /// Stage-3 diff: Rust read an absent `ts_ms` / `idx` as null, Dart rejected it. SPEC §2 now
    /// says every field but `id` is required, so an absent key is invalid input.
    #[test]
    fn rejects_absent_nullable_keys() {
        let base = r#"{"now_ms":0,"utc_offset_min":0,"nodes":[{TS"is_root":false,"priority":0,"parents":[{IDX"kind":"missing"}]}]}"#;
        assert!(parse_input(
            base.replace("TS", r#""ts_ms":null,"#)
                .replace("IDX", r#""idx":null,"#)
                .as_bytes()
        )
        .is_ok());
        assert!(err(&base.replace("TS", "").replace("IDX", r#""idx":null,"#)).contains("missing field `ts_ms`"));
        assert!(err(&base.replace("TS", r#""ts_ms":null,"#).replace("IDX", "")).contains("missing field `idx`"));
    }

    /// Stage-3 diff: `utc_offset_min · 60000` overflowed i64 (wrap in release, panic in debug)
    /// for offsets V4 allowed. SPEC §2 V4 now bounds it to ±1440.
    #[test]
    fn rejects_utc_offsets_beyond_a_day() {
        let doc = |off: &str| format!(r#"{{"now_ms":0,"utc_offset_min":{off},"nodes":[]}}"#);
        for off in ["1440", "-1440", "0"] {
            assert!(parse_input(doc(off).as_bytes()).is_ok(), "{off}");
        }
        for off in ["1441", "-1441", "9007199254740992", "-9223372036854775808"] {
            assert!(err(&doc(off)).starts_with("V4"), "{off}");
        }
    }

    /// Stage-3 diff: serde_json reads the JSON integer `-0` as the float −0.0, so Rust rejected
    /// it where Dart reads the int 0. SPEC §2: `-0` is the integer 0; `-0.0` stays a float.
    #[test]
    fn minus_zero_is_the_integer_zero_but_minus_zero_point_zero_is_not() {
        let doc = |ts: &str, prio: &str| {
            format!(
                r#"{{"now_ms":-0,"utc_offset_min":0,"nodes":[{{"id":"q\"-0,","ts_ms":{ts},"is_root":false,"priority":{prio},"parents":[]}}]}}"#
            )
        };
        let input = parse_input(doc("-0", "-0").as_bytes()).unwrap();
        assert_eq!((input.now_ms, input.ts[0], input.priority[0]), (0, 0, 0));
        assert!(err(&doc("-0.0", "0")).starts_with("invalid input JSON"));
        assert!(err(&doc("0", "-0e0")).starts_with("invalid input JSON"));
        assert!(err(&doc("-01", "0")).starts_with("invalid input JSON"));
        assert_eq!(
            neg_zero_to_zero(r#"[-0,"-0",-0.5,-0e1,-00,"\"-0",-0]"#).unwrap(),
            r#"[ 0,"-0",-0.5,-0e1,-00,"\"-0", 0]"#
        );
        assert!(neg_zero_to_zero(r#"[0,-1,"-0"]"#).is_none());
    }

    /// Stage-3 diff: serde_json skips an ignored string (here `id`) without checking its UTF-8,
    /// so Rust accepted a document Dart's decoder rejects. JSON text is UTF-8 (RFC 8259 §8.1).
    #[test]
    fn rejects_invalid_utf8_even_in_ignored_strings() {
        let mut doc = br#"{"now_ms":0,"utc_offset_min":0,"nodes":[{"id":"#.to_vec();
        doc.extend_from_slice(b"\"\xff\xfe\"");
        doc.extend_from_slice(br#","ts_ms":1,"is_root":false,"priority":0,"parents":[]}]}"#);
        assert!(parse_input(&doc).expect_err("must be rejected").contains("not UTF-8"));
        assert!(parse_input(String::from_utf8_lossy(&doc).as_bytes()).is_ok());
    }
}
