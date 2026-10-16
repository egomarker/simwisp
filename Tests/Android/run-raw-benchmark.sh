#!/bin/bash
# Synthetic process-CPU comparison. Never starts any real capture or emulator.
set -euo pipefail
: "${RAW_BASELINE_ROOT:?Set RAW_BASELINE_ROOT to an untouched pre-optimization source snapshot}"
root=$(mktemp -d /tmp/simwisp-raw-cpu-tests.XXXXXX)
trap 's=$?;if [[ -n "${TEST_OUTPUT:-}" ]];then mkdir -p "$TEST_OUTPUT";cp "$root"/*.json "$TEST_OUTPUT"/ 2>/dev/null || true;fi;rm -rf "$root";exit "$s"' EXIT
files=(Support.swift Pairing.swift H264SPS.swift Video.swift ScrcpyProtocol.swift EmulatorRawWire.swift)
old=();new=();for f in "${files[@]}";do old+=("$RAW_BASELINE_ROOT/Sources/$f");new+=("Sources/$f");done
xcrun swiftc -swift-version 5 -O "${old[@]}" Tests/Android/RawBenchmark/main.swift -o "$root/baseline"
xcrun swiftc -swift-version 5 -O -D RAW_OPTIMIZED "${new[@]}" Tests/Android/RawBenchmark/main.swift -o "$root/optimized"
# Both compilers have exited. Do not run this target concurrently with a build.
if pgrep -x swift-frontend >/dev/null;then echo 'Refusing CPU measurement while a compiler is active' >&2;exit 1;fi
for mode in parser static fresh;do
 n=0
 for variant in baseline optimized optimized baseline;do
  n=$((n+1));sleep 1
  "$root/$variant" "$mode" "$root/raw-cpu-$mode-$n-$variant.json"
 done
done
