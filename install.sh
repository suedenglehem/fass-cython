#!/usr/bin/env bash
# Convenience wrapper — the install is all in setup.sh.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup.sh" "$@"
