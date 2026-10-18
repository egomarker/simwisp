#!/bin/bash
set -euo pipefail
: "${NODE:=node}"
root=$(mktemp -d /tmp/simwisp-native-tests.XXXXXX)
pid=''
cleanup(){
 status=$?
 if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null;then kill -TERM "$pid";wait "$pid" || true;fi
 if [[ -n "${TEST_OUTPUT:-}" ]];then mkdir -p "$TEST_OUTPUT";cp "$root"/*.json "$root"/*.log "$root"/*.ndjson "$TEST_OUTPUT"/ 2>/dev/null || true;fi
 rm -rf "$root";exit "$status"
}
trap cleanup EXIT
"$NODE" Tests/Native/policy.mjs
xcrun clang -fobjc-arc -Wall -Wextra -Werror -c Tests/Native/Forwarding.m -o "$root/forwarding.o"
xcrun swiftc -swift-version 5 -O "$root/forwarding.o" $(find Sources -name '*.swift' ! -name SimwispApp.swift | sort) Tests/Native/main.swift -o "$root/tests"
if [[ "${NATIVE_UNIT:-1}" = 1 ]];then "$root/tests" "$root";fi
if [[ "${NATIVE_BROWSER:-0}" = 1 ]];then
 # Unit and browser fixtures have separate journals; preserve both in TEST_OUTPUT.
 if [[ -f "$root/events.ndjson" ]];then mv "$root/events.ndjson" "$root/native-unit-events.ndjson";fi
 cp -R Resources/Web "$root/Web"
 "$root/tests" "$root" --serve > "$root/service.log" 2>&1 & pid=$!
 for ((i=0;i<200;i++));do grep -q 'Isolated Native service ready' "$root/service.log" && break;kill -0 "$pid" 2>/dev/null || { cat "$root/service.log";exit 1;};sleep .05;done
 if [[ -n "${NATIVE_BROWSER_PHASE:-}" ]];then
  NODE_EXTRA_CA_CERTS="$root/tls/root.pem" "$NODE" Tests/Native/browser.mjs "$root"
 else
  # Default CI target includes deadlines and the rapid-retirement regressions.
  for phase in ${NATIVE_BROWSER_PHASES:-all boundary rapid scaling busy reuse discovery finalization};do
   NATIVE_BROWSER_PHASE="$phase" NODE_EXTRA_CA_CERTS="$root/tls/root.pem" "$NODE" Tests/Native/browser.mjs "$root"
   mv "$root/native-browser-review.json" "$root/native-$phase-browser-review.json"
  done
 fi
fi
