// SPDX-License-Identifier: MIT

//! The version of `jj-lib` this crate is built on.

/// The version of `jj-lib` Zanshin is built on — the exact pin in the workspace `Cargo.toml`.
///
/// jj-lib exposes no version of its own, so this repeats the pin; the exact pin makes it the
/// compiled version. A test fails, naming both values, when a pin bump leaves it behind the
/// committed `Cargo.lock`.
pub const JJ_LIB_VERSION: &str = "0.47.0";

#[cfg(test)]
mod tests {
    use super::JJ_LIB_VERSION;

    /// The `version` of every `[[package]]` named `jj-lib` in the lockfile `lock`.
    fn locked_jj_lib_versions(lock: &str) -> Vec<&str> {
        let lines: Vec<&str> = lock.lines().collect();
        lines
            .windows(2)
            .filter(|pair| pair[0] == r#"name = "jj-lib""#)
            .filter_map(|pair| pair[1].strip_prefix(r#"version = ""#)?.strip_suffix('"'))
            .collect()
    }

    #[test]
    fn jj_lib_version_is_the_locked_jj_lib() {
        let locked = locked_jj_lib_versions(include_str!("../../../Cargo.lock"));
        assert_eq!(
            locked.len(),
            1,
            "Cargo.lock must hold exactly one jj-lib, holds {locked:?}"
        );
        assert_eq!(
            JJ_LIB_VERSION, locked[0],
            "JJ_LIB_VERSION is {JJ_LIB_VERSION}, Cargo.lock's jj-lib is {}",
            locked[0]
        );
    }

    #[test]
    fn a_lockfile_without_jj_lib_or_with_two_is_read_as_such() {
        let one = "[[package]]\nname = \"jj-lib\"\nversion = \"1.2.3\"\n";
        assert_eq!(locked_jj_lib_versions(one), vec!["1.2.3"]);
        assert_eq!(
            locked_jj_lib_versions("[[package]]\nname = \"jj-cli\"\nversion = \"1.2.3\"\n"),
            Vec::<&str>::new()
        );
        assert_eq!(locked_jj_lib_versions(&format!("{one}{one}")).len(), 2);
    }
}
