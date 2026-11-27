#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# pre-commit-compatible check: inspect only the files supplied by the hook.
# Accept SPDX after a short generated workflow banner (gh actions-lock).
set -uo pipefail

failed=0
for f in "$@"; do
  [ -f "$f" ] || continue
  if ! head -n 12 "$f" | grep -q '^\(#\|//\|--\) SPDX-License-Identifier:'; then
    printf 'ERROR: %s has no SPDX licence marker in its first 12 lines\n' "$f" >&2
    failed=1
  fi
done
exit "$failed"
