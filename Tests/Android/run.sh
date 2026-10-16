#!/bin/bash
set -euo pipefail
: "${NODE:=node}"
root=$(mktemp -d /tmp/simwisp-android-tests.XXXXXX)
pid=''
cleanup(){ if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null;then kill -TERM "$pid";wait "$pid" || true;fi; if [[ -n "${TEST_OUTPUT:-}" ]];then mkdir -p "$TEST_OUTPUT";cp "$root"/*review.json "$root"/*.png "$root"/*.log "$TEST_OUTPUT"/ 2>/dev/null || true;fi;"$NODE" -e 'const cp=require("child_process");for(const l of cp.execFileSync("/bin/ps",["-axo","pid=,command="],{encoding:"utf8"}).split("\n")){if(l.includes(process.argv[1])&&(l.includes("Tests/Android/server.mjs")||l.includes("Tests/Android/raw-peer.mjs"))){const pid=Number(l.trim().split(/\s+/)[0]);if(pid!==process.pid&&pid!==process.ppid){try{process.kill(pid,"SIGTERM")}catch{}}}}' "$root"; sleep .2; rm -rf "$root"; }
trap cleanup EXIT
xcrun swiftc -swift-version 5 -O $(find Sources -name '*.swift' ! -name SimwispApp.swift | sort) Tests/Android/main.swift Tests/Android/JPEG.swift Tests/Android/Raw.swift Tests/Android/RawStorage.swift -o "$root/tests"
"$root/tests" "$root" "$NODE"
if [[ "${ANDROID_BROWSER:-0}" = 1 || "${ANDROID_PERFORMANCE:-0}" = 1 || "${ANDROID_PARITY:-0}" = 1 || "${ANDROID_JPEG:-0}" = 1 || "${ANDROID_RAW:-0}" = 1 ]];then
 if [[ "${ANDROID_PERFORMANCE:-0}" = 1 ]];then touch "$root/performance";fi
 cp -R Resources/Web "$root/Web"
 "$root/tests" "$root" "$NODE" --serve > "$root/service.log" 2>&1 & pid=$!
 for ((i=0;i<200;i++));do grep -q 'Isolated Android service ready' "$root/service.log" && break;kill -0 "$pid" 2>/dev/null || { cat "$root/service.log";exit 1; };sleep .05;done
 if [[ "${ANDROID_RAW:-0}" = 1 ]];then NODE_EXTRA_CA_CERTS="$root/tls/root.pem" "$NODE" Tests/Android/raw.mjs "$root";fi
 if [[ "${ANDROID_JPEG:-0}" = 1 ]];then NODE_EXTRA_CA_CERTS="$root/tls/root.pem" "$NODE" Tests/Android/jpeg.mjs "$root";fi
 if [[ "${ANDROID_BROWSER:-0}" = 1 ]];then NODE_EXTRA_CA_CERTS="$root/tls/root.pem" "$NODE" Tests/Android/review.mjs "$root";fi
 if [[ "${ANDROID_PARITY:-0}" = 1 ]];then NODE_EXTRA_CA_CERTS="$root/tls/root.pem" "$NODE" Tests/Android/parity.mjs "$root";fi
 if [[ "${ANDROID_PERFORMANCE:-0}" = 1 ]];then NODE_EXTRA_CA_CERTS="$root/tls/root.pem" "$NODE" Tests/Android/performance.mjs "$root";fi
fi
