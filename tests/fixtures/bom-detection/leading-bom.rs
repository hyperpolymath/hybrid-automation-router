// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

// Test fixture: file with leading UTF-8 BOM (EF BB BF) that should be detected

fn main() {
    println!("This file has a leading BOM");
}
