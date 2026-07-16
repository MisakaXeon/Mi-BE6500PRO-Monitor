#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

FILES="
VERSION
bin/router-monitor_linux_arm64
scripts/start.sh
scripts/rmmon
scripts/update.sh
"

: >checksums.txt
for file in $FILES; do
    [ -f "$file" ] || {
        echo "missing release asset: $file" >&2
        exit 1
    }
    hash=$(sha256sum "$file" | awk '{print $1}')
    [ -n "$hash" ] || {
        echo "failed to hash release asset: $file" >&2
        exit 1
    }
    printf '%s  %s\n' "$hash" "$file" >>checksums.txt
done
