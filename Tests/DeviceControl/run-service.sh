#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Device-control tests run on macOS only.' >&2; exit 1; }
: "${NODE:=node}"
root=$(mktemp -d /tmp/simwisp-device-service-tests.XXXXXX)
pid=''
cleanup() {
 if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
  curl --silent --cacert "$root/tls/root.pem" -X POST https://127.0.0.1:45152/fixture/release-all >/dev/null || true
  kill -TERM "$pid"; wait "$pid" || true
 fi
 if [[ -n "${TEST_OUTPUT:-}" ]]; then mkdir -p "$TEST_OUTPUT"; cp "$root"/*.png "$root"/device-service-review.json "$root"/service.log "$TEST_OUTPUT"/ 2>/dev/null || true; fi
 rm -rf "$root"
}
trap cleanup EXIT
sources=()
for file in Sources/*.swift; do [[ "$file" == Sources/SimwispApp.swift ]] || sources+=("$file"); done
xcrun swiftc -swift-version 5 -O "${sources[@]}" Tests/DeviceControl/Service/main.swift -o "$root/service"
cp -R Resources/Web "$root/Web"
"$root/service" "$root" > "$root/service.log" 2>&1 & pid=$!
for ((i=0;i<200;i++)); do
 grep -q 'Isolated device-control service ready' "$root/service.log" && break
 kill -0 "$pid" 2>/dev/null || { cat "$root/service.log" >&2; exit 1; }
 sleep .05
done
grep -q 'Isolated device-control service ready' "$root/service.log" || { cat "$root/service.log" >&2; exit 1; }
NODE_EXTRA_CA_CERTS="$root/tls/root.pem" "$NODE" Tests/DeviceControl/review.mjs "$root"
