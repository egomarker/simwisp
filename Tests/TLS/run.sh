#!/bin/bash
set -euo pipefail
: "${NODE:=node}"
root=$(mktemp -d /tmp/simwisp-tls-tests.XXXXXX)
pid=''
cleanup(){
 if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid"; wait "$pid" || true; fi
 if [[ -n "${TEST_OUTPUT:-}" ]]; then mkdir -p "$TEST_OUTPUT"; cp "$root"/tls-review.json "$root"/service.log "$TEST_OUTPUT"/ 2>/dev/null || true; fi
 rm -rf "$root"
}
trap cleanup EXIT
sources=()
for file in Sources/*.swift; do [[ "$file" == Sources/SimwispApp.swift ]] || sources+=("$file"); done
xcrun swiftc -swift-version 5 -O "${sources[@]}" Tests/TLS/main.swift -o "$root/service"
cp -R Resources/Web "$root/Web"
"$root/service" "$root" > "$root/service.log" 2>&1 & pid=$!
for ((i=0;i<200;i++)); do
 grep -q 'production TLS service ready' "$root/service.log" && break
 kill -0 "$pid" 2>/dev/null || { cat "$root/service.log" >&2; exit 1; }
 sleep .05
done
grep -q 'production TLS service ready' "$root/service.log" || { cat "$root/service.log" >&2; exit 1; }
NODE_EXTRA_CA_CERTS="$root/tls/root.pem" "$NODE" Tests/TLS/review.mjs "$root"
