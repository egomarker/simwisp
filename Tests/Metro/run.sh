#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Metro tests run on macOS.' >&2; exit 1; }
: "${NODE:=node}"
for port in 45152 45153; do if /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then echo "Fixture port $port is occupied; not disturbing it." >&2; exit 1; fi; done
root=$(mktemp -d /tmp/simwisp-metro-fixture.XXXXXX)
pid=''; metro_pid=''
cleanup(){
 if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid"; wait "$pid" || true; fi
 if [[ -n "$metro_pid" ]] && kill -0 "$metro_pid" 2>/dev/null; then kill -TERM "$metro_pid"; wait "$metro_pid" || true; fi
 if [[ -n "${TEST_OUTPUT:-}" ]]; then mkdir -p "$TEST_OUTPUT"; cp "$root"/*.json "$root"/*.png "$root"/*.log "$TEST_OUTPUT"/ 2>/dev/null || true; fi
 rm -rf "$root"
}
trap cleanup EXIT
"$NODE" Tests/Metro/retention.mjs
"$NODE" Tests/Metro/policy.mjs
"$NODE" Tests/Metro/fake-metro.mjs > "$root/metro.log" 2>&1 & metro_pid=$!
sources=();for file in Sources/*.swift;do [[ "$file" == Sources/SimwispApp.swift ]] || sources+=("$file");done
xcrun swiftc -swift-version 5 -O "${sources[@]}" Tests/Metro/Service/main.swift -o "$root/service"
cp -R Resources/Web "$root/Web"
if [[ -n "${METRO_SOURCE_BASELINE:-}" ]]; then cp "$METRO_SOURCE_BASELINE/Resources/Web/js/metro-console.js" "$root/Web/js/metro-console-before.js"; fi
"$root/service" "$root" > "$root/service.log" 2>&1 & pid=$!
for ((i=0;i<200;i++));do grep -q 'Isolated Metro service ready' "$root/service.log" && break;kill -0 "$pid" 2>/dev/null || { cat "$root/service.log" >&2;exit 1; };sleep .05;done
grep -q 'Isolated Metro service ready' "$root/service.log" || { cat "$root/service.log" >&2;exit 1; }
NODE_EXTRA_CA_CERTS="$root/tls/root.pem" "$NODE" Tests/Metro/review.mjs "$root"
