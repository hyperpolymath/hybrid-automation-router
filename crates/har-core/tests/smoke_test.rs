// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! Smoke tests for har-core (CRG C)
//!
//! Validates that the crate compiles and its public API is accessible.

use har_core::{Error, Result};

#[test]
fn crate_compiles_and_links() {
    assert!(true, "har-core linked successfully");
}

#[test]
fn error_type_is_debug() {
    // Error must implement Debug for use in Result unwrap/expect
    let e: Result<()> = Err(Error::Routing("test".to_string()));
    let msg = format!("{:?}", e);
    assert!(!msg.is_empty());
}

#[test]
fn result_alias_works() {
    let ok: Result<u32> = Ok(42);
    assert_eq!(ok.unwrap(), 42);
}
