// SPDX-License-Identifier: MIT

//! The CLI driver pins the hermetic environment itself (Story 9.47 review fix).
//!
//! Its own test binary, so no other test has called `pin_test_env()` first: in a test that
//! forgets the call, the pinned `jj` must still not fall back to the developer's real
//! `~/.config/jj` (its secure per-repo config would land there).

use std::ffi::OsStr;
use std::path::Path;

#[allow(dead_code)] // WHY: only `command` is exercised here; the oracle binary uses the rest.
#[path = "oracle/driver.rs"]
mod driver;

#[test]
fn the_driver_pins_the_test_xdg_config_home_without_the_caller() {
    let command = driver::command(Path::new("/"), &["log"]);
    let xdg = command
        .get_envs()
        .find(|(name, _)| *name == OsStr::new("XDG_CONFIG_HOME"))
        .and_then(|(_, value)| value)
        .map(Path::new)
        .expect("the driver passes XDG_CONFIG_HOME");
    assert!(
        xdg.starts_with(std::env::temp_dir()),
        "XDG_CONFIG_HOME must be the test's temp dir, got {}",
        xdg.display()
    );
}
