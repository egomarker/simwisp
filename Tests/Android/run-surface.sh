#!/bin/bash
# Pure stride/pacing checks. No emulator, APK installation or capture.
set -euo pipefail
cd "$(dirname "$0")/../.."
jdk=${JAVA_HOME:-}
if [[ -z "$jdk" && -x '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/javac' ]];then jdk='/Applications/Android Studio.app/Contents/jbr/Contents/Home';fi
if [[ -z "$jdk" ]];then jdk=$(/usr/libexec/java_home 2>/dev/null || true);fi
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
if [[ -z "$sdk" ]];then
  for candidate in "$HOME/Library/Android/sdk" "$HOME/.androidsdk";do if [[ -d "$candidate/platforms" ]];then sdk=$candidate;break;fi;done
fi
android=''
for p in "$sdk"/platforms/android-{34..99}/android.jar;do if [[ -f "$p" ]];then android=$p;fi;done
if [[ ! -x "$jdk/bin/javac" || -z "$android" ]];then echo 'Surface tests need existing JDK and Android SDK platform34+; no automatic installation.' >&2;exit 1;fi
root=$(mktemp -d /tmp/simwisp-jpeg-surface-tests.XXXXXX)
trap 'rm -rf "$root"' EXIT
"$jdk/bin/javac" --release 8 -encoding UTF-8 -classpath "$android" -d "$root" Resources/Android/SimwispJpeg.java Tests/Android/Surface.java
"$jdk/bin/java" -classpath "$root" io.simwisp.Surface
