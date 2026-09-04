// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

// Test fixture: file with normal whitespace (tabs, CR, LF) that should not be flagged

fn main() {
	// Tab character above is legitimate
	let message = "Line\r\nbreak\ttab";
	println!("{}", message);
}
