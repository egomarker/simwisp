#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Browser fixture runs on macOS only.' >&2; exit 1; }
: "${NODE:=node}"
root=$(mktemp -d /tmp/simwisp-browser-tests.XXXXXX)
fixture_pid=''
cleanup() {
  if [[ -n "$fixture_pid" ]] && kill -0 "$fixture_pid" 2>/dev/null; then
    kill -TERM "$fixture_pid"
    wait "$fixture_pid" || true
  fi
  if [[ -n "${TEST_OUTPUT:-}" ]]; then
    mkdir -p "$TEST_OUTPUT"
    cp "$root"/*.png "$root"/browser-review*.json "$TEST_OUTPUT"/ 2>/dev/null || true
    cp "$root"/fixture.log "$TEST_OUTPUT"/fixture.log
  fi
  rm -rf "$root"
}
trap cleanup EXIT
xcrun swiftc -swift-version 5 -O Sources/Support.swift Sources/Pairing.swift Sources/Accessibility.swift Sources/HTTPServer.swift Sources/SocketTransport.swift Tests/Browser/main.swift -o "$root/fixture"
"$root/fixture" "$root" > "$root/fixture.log" 2>&1 &
fixture_pid=$!
for ((i=0; i<100; i++)); do
  if grep -q 'Isolated accessibility fixture ready' "$root/fixture.log"; then break; fi
  if ! kill -0 "$fixture_pid" 2>/dev/null; then cat "$root/fixture.log" >&2; exit 1; fi
  sleep .05
done
grep -q 'Isolated accessibility fixture ready' "$root/fixture.log" || { cat "$root/fixture.log" >&2; exit 1; }
"$NODE" Tests/Browser/accessibility-review.mjs "$root" "$@"
