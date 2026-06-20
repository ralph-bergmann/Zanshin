// SPDX-License-Identifier: MIT

use std::path::PathBuf;

use tempfile::TempDir;

/// Handle returned by [`extract_fixture`]. Keeps the temp directory alive while the caller holds
/// this value; dropped automatically on `Drop`, which deletes the extracted files.
pub struct FixtureHandle {
    _temp: TempDir,
    /// Absolute path to the extracted workspace root (the directory containing `.jj/`).
    pub path: PathBuf,
}

/// Extracts the named fixture archive into a fresh temp directory and returns a handle.
///
/// `name` must match a file under `test-fixtures/repos/<name>.tar.zst` at the workspace root.
/// The archive is located via `CARGO_MANIFEST_DIR` so this works regardless of which crate's
/// integration tests call it.
///
/// # Panics
/// Panics if `CARGO_MANIFEST_DIR` is not at least two directory levels deep (invariant guaranteed
/// by Cargo for any crate inside `crates/*`).
///
/// # Errors
/// Returns an error if the archive cannot be opened, decompressed, or extracted.
pub fn extract_fixture(name: &str) -> Result<FixtureHandle, Box<dyn std::error::Error>> {
    // CARGO_MANIFEST_DIR is crates/test-helpers/ — two parents up is the workspace root.
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let workspace_root = manifest
        .parent()
        .expect("crates/test-helpers has a parent")
        .parent()
        .expect("crates has a parent (workspace root)");

    let archive_path = workspace_root
        .join("test-fixtures")
        .join("repos")
        .join(format!("{name}.tar.zst"));

    let archive_file = std::fs::File::open(&archive_path)
        .map_err(|e| format!("cannot open fixture archive {}: {e}", archive_path.display()))?;

    let decoder = zstd::Decoder::new(archive_file)?;
    let mut archive = tar::Archive::new(decoder);

    let temp = TempDir::new()?;
    archive.unpack(temp.path())?;

    let path = temp.path().to_path_buf();
    Ok(FixtureHandle { _temp: temp, path })
}
