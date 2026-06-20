// SPDX-License-Identifier: MIT

/// Verifies the tiny fixture can be extracted and has a well-formed jj workspace layout.
#[test]
fn tiny_fixture_extracts_with_jj_dir() {
    let handle = test_helpers::extract_fixture("tiny-3-commits").expect("tiny-3-commits fixture must be extractable");

    assert!(
        handle.path.join(".jj").is_dir(),
        ".jj directory must exist in extracted workspace"
    );
    assert!(
        handle.path.join(".jj").join("repo").is_dir(),
        ".jj/repo directory must exist"
    );
    assert!(
        handle.path.join(".jj").join("working_copy").is_dir(),
        ".jj/working_copy directory must exist"
    );
}

/// Edge case 25: extracted path is in a fresh temp dir distinct from the archive location.
#[test]
fn extracted_path_is_relocatable_tmpdir() {
    let handle = test_helpers::extract_fixture("tiny-3-commits").expect("tiny-3-commits fixture must be extractable");

    let jj_dir = handle.path.join(".jj");
    assert!(jj_dir.is_dir(), ".jj must be present in relocated temp dir");

    // Confirm the path is under the system temp dir (i.e. not the source tree).
    let tmp = std::env::temp_dir();
    assert!(
        handle.path.starts_with(&tmp),
        "extracted path {} must be under system temp dir {}",
        handle.path.display(),
        tmp.display()
    );
}
