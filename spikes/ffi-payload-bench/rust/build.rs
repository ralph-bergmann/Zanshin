// SPDX-License-Identifier: Apache-2.0
//
// Generates Rust FlatBuffers accessors from the shared schema by invoking the
// official `flatc` compiler. Output lands in OUT_DIR and is `include!`d by
// `src/flat.rs`. Fails loudly if `flatc` is missing.

use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR set by cargo");
    let schema = format!("{manifest_dir}/../schema/payload.fbs");
    println!("cargo:rerun-if-changed={schema}");
    println!("cargo:rerun-if-changed=build.rs");

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR set by cargo"));

    let status = Command::new("flatc")
        .arg("--rust")
        .arg("-o")
        .arg(&out_dir)
        .arg(&schema)
        .status()
        .expect("failed to spawn `flatc` — install it with `brew install flatbuffers`");

    assert!(status.success(), "flatc failed to generate Rust code for {schema}");
}
