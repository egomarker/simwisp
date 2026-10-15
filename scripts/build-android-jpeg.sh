#!/bin/bash
# Build an optional DEX helper; never install anything or contact a device.
set -euo pipefail
output=${1:?Output JAR path required}
root=$(cd "$(dirname "$0")/.." && pwd)
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
if [[ -z "$sdk" ]]; then
  for candidate in "$HOME/Library/Android/sdk" "$HOME/.androidsdk"; do
    if [[ -d "$candidate/build-tools" ]]; then sdk=$candidate; break; fi
  done
fi
jdk=${JAVA_HOME:-}
if [[ -z "$jdk" && -x '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/javac' ]]; then jdk='/Applications/Android Studio.app/Contents/jbr/Contents/Home'; fi
if [[ -z "$jdk" ]]; then jdk=$(/usr/libexec/java_home 2>/dev/null || true); fi
android=''; d8=''
if [[ -d "$sdk/platforms" ]]; then
  for p in "$sdk"/platforms/android-{34..99}/android.jar; do if [[ -f "$p" ]]; then android=$p; fi; done
  for p in "$sdk"/build-tools/*/d8; do if [[ -x "$p" ]]; then d8=$p; fi; done
fi
if [[ ! -x "$jdk/bin/javac" || -z "$android" || -z "$d8" ]]; then
  rm -f "$output"
  echo 'Android JPEG helper unavailable: build needs JDK + Android SDK platform34+ and build-tools (no automatic installation).' >&2
  [[ "${REQUIRE_ANDROID_JPEG:-0}" != 1 ]]; exit
fi
work=$(mktemp -d /tmp/simwisp-jpeg-build.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/classes" "$work/dex" "$(dirname "$output")"
"$jdk/bin/javac" --release 8 -encoding UTF-8 -classpath "$android" -d "$work/classes" "$root/Resources/Android/SimwispJpeg.java"
# D8 needs a real JVM; never rely on macOS's unconfigured java shim.
JAVA_HOME="$jdk" "$d8" --min-api 34 --lib "$android" --output "$work/dex" "$work"/classes/io/simwisp/*.class
cp "$root/Resources/Android/NOTICE" "$root/Resources/Android/LICENSE" "$work/dex/"
TZ=UTC /usr/bin/touch -t 198001010000.00 "$work/dex/classes.dex" "$work/dex/NOTICE" "$work/dex/LICENSE"
(cd "$work/dex" && /usr/bin/zip -q -X "$work/helper.jar" classes.dex NOTICE LICENSE)
cp "$work/helper.jar" "$output"
