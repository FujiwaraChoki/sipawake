#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
destination="$project/.build/menu-app"
pkill -x -u "$(id -u)" SipAwakeMenu || true
"$project/script/bundle.sh" "$destination"
codesign --force --sign - "$destination/SipAwake.app/Contents/Helpers/sipawake"
codesign --force --sign - "$destination/SipAwake.app"
open -n "$destination/SipAwake.app"

if [[ "${1:-}" == --verify ]]; then
    for _ in 1 2 3 4 5; do
        if pgrep -x -u "$(id -u)" SipAwakeMenu; then exit 0; fi
        sleep 1
    done
    echo "SipAwake did not launch." >&2
    exit 1
fi
