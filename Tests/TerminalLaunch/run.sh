#!/bin/bash
set -euo pipefail
root=$(mktemp -d /tmp/simwisp-terminal-launch-tests.XXXXXX)
trap 'status=$?; if [[ -n "${TEST_OUTPUT:-}" ]]; then mkdir -p "$TEST_OUTPUT"; cp "$root"/*.json "$TEST_OUTPUT/" 2>/dev/null || true; fi; rm -rf -- "$root"; exit "$status"' EXIT
xcrun clang -O2 -Wall -Wextra -Werror -fobjc-arc -framework AppKit Sources/TerminalLauncher.m -o "$root/launcher"
codesign --force --sign - --identifier io.simwisp.terminal-launcher "$root/launcher"
xcrun swiftc -swift-version 5 -O Sources/Support.swift Sources/Pairing.swift Sources/TerminalLaunch.swift Tests/TerminalLaunch/integration.swift Tests/TerminalLaunch/lifecycle.swift Tests/TerminalLaunch/main.swift -o "$root/tests"
xcrun clang -O2 -Wall -Wextra -Werror Sources/TerminalHost.c -o "$root/shell-host"
phase="${TERMINAL_LAUNCH_PHASE:-all}"
case "$phase" in all|native|integration|lifecycle) ;; *) echo "Unknown terminal launch phase" >&2; exit 64 ;; esac
if [[ "$phase" == all || "$phase" == native ]]; then
  "$root/tests" "$root" "$root/launcher"
  "${NODE:-node}" Tests/TerminalLaunch/frontend.mjs "$root"
fi
if [[ "$phase" == all || "$phase" == integration ]]; then "$root/tests" "$root" "$root/launcher" integration; fi
if [[ "$phase" == all || "$phase" == lifecycle ]]; then "$root/tests" "$root" "$root/launcher" lifecycle; fi
