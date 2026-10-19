#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

# Keep the old app running if the new build fails.
make check

# Match only this user's main app, not SimwispShell or any simulators.
uid="$(id -u)"
status=0
pkill -TERM -u "$uid" -x Simwisp || status=$?
if (( status > 1 )); then
    echo "Could not stop Simwisp (pkill exit $status)." >&2
    exit "$status"
fi

# Do not let open reuse the old process or start while it is still exiting.
for (( attempt = 0; attempt < 100; attempt++ )); do
    status=0
    pgrep -u "$uid" -x Simwisp >/dev/null || status=$?
    case "$status" in
        1) open build/Simwisp.app --args --lan; exit 0 ;;
        0) sleep 0.1 ;;
        *) echo "Could not verify Simwisp exit (pgrep exit $status)." >&2; exit "$status" ;;
    esac
done

echo "Simwisp did not exit within 10 seconds; refusing to start another instance." >&2
exit 1
