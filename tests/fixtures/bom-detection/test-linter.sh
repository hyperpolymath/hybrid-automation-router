#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

# Test script to verify BOM detection fixtures work correctly

set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$FIXTURE_DIR"

echo "Testing invisible character detection..."
echo ""

# Pattern-based check
PATTERNS='(*UTF)[\x00-\x08\x0B\x0C\x0E-\x1F\x{a0}\x{ad}\x{200b}-\x{200f}\x{202a}-\x{202f}\x{2060}\x{2066}-\x{2069}\x{feff}]'

echo "=== Pattern-based check (mid-file BOMs, C0 controls, invisible Unicode) ==="
grep -aPl "$PATTERNS" *.rs *.yml 2>/dev/null | sort || true
echo ""

# Byte-wise leading-BOM check
echo "=== Byte-wise leading-BOM check ==="
for file in *.rs *.yml; do
    [ ! -f "$file" ] && continue
    if head -c 3 "$file" | od -An -tx1 2>/dev/null | grep -q "ef bb bf"; then
        echo "$file"
    fi
done
echo ""

# Combined results
echo "=== Combined results (unique files) ==="
{
    grep -aPl "$PATTERNS" *.rs *.yml 2>/dev/null || true
    for file in *.rs *.yml; do
        [ ! -f "$file" ] && continue
        if head -c 3 "$file" | od -An -tx1 2>/dev/null | grep -q "ef bb bf"; then
            echo "$file"
        fi
    done
} | sort -u
echo ""

# Expected vs actual
echo "=== Expected results ==="
echo "Should be flagged:"
echo "  - leading-bom.rs (leading BOM)"
echo "  - corrupted-workflow.yml (C0 control character)"
echo ""
echo "Should NOT be flagged:"
echo "  - clean.rs"
echo "  - normal-whitespace.rs"
echo "  - README.adoc"
echo "  - test-linter.sh"
