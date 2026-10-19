SHELL := /bin/bash
APP := build/Simwisp.app
SOURCES := $(wildcard Sources/*.swift)
NODE ?= node
TEST_BUILD ?= build/tests
ARCH := $(shell uname -m)
SDK := $(shell xcrun --sdk macosx --show-sdk-path)

.PHONY: build check test test-pairing test-accessibility test-input test-capture test-device-control test-video test-video-quality test-sps test-stream-flow test-decoder test-tls test-browser-accessibility test-browser-device-control test-browser-headless test-metro-native test-metro-console run clean install
build:
	@mkdir -p '$(APP)/Contents/MacOS' '$(APP)/Contents/Resources'
	@scripts/build-android-jpeg.sh '$(APP)/Contents/Resources/simwisp-jpeg.jar'
	xcrun clang -O2 -Wall -Wextra -Werror -isysroot '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/TerminalHost.c -o '$(APP)/Contents/MacOS/SimwispShell'
	xcrun swiftc -swift-version 5 -O -g -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 $(SOURCES) -o '$(APP)/Contents/MacOS/Simwisp'
	@cp Resources/Info.plist '$(APP)/Contents/Info.plist'
	@rm -rf '$(APP)/Contents/Resources/Web'
	@cp -R Resources/Web '$(APP)/Contents/Resources/'
	@cp Resources/device-sizes.json '$(APP)/Contents/Resources/'
	@cp -R Resources/Native '$(APP)/Contents/Resources/'
	@rm -f '$(APP)/Contents/Resources/UPSTREAM-LICENSE'
	codesign --force --sign - --identifier io.simwisp.shell '$(APP)/Contents/MacOS/SimwispShell'
	codesign --force --sign - --identifier io.simwisp.app -r '=designated => identifier "io.simwisp.app"' '$(APP)'
	codesign --verify --deep --strict '$(APP)'
check: build
	@/usr/libexec/PlistBuddy -c 'Print :LSUIElement' '$(APP)/Contents/Info.plist'
test: test-metro-native test-pairing test-accessibility test-input test-native-input test-headless-ios-controls test-headless-mode test-capture test-device-control test-android-crash-env test-simulator-quit test-video test-stream-flow
test-pairing:
	@mkdir -p '$(TEST_BUILD)'
	xcrun swiftc -swift-version 5 -O -g -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/Support.swift Sources/Pairing.swift Tests/main.swift -o '$(TEST_BUILD)/pairing-tests'
	@'$(TEST_BUILD)/pairing-tests'
test-accessibility:
	@mkdir -p '$(TEST_BUILD)'
	xcrun swiftc -swift-version 5 -O -g -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/Support.swift Sources/Pairing.swift Sources/Accessibility.swift Tests/Accessibility/main.swift -o '$(TEST_BUILD)/accessibility-tests'
	@'$(TEST_BUILD)/accessibility-tests'
test-input:
	@mkdir -p '$(TEST_BUILD)'
	xcrun swiftc -swift-version 5 -O -g -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/Support.swift Sources/Pairing.swift Sources/DeviceControl.swift Sources/Devices.swift Sources/Input.swift Tests/Input/main.swift -o '$(TEST_BUILD)/input-tests'
	@'$(TEST_BUILD)/input-tests'
test-device-control:
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-device-control-tests.XXXXXX); trap 'rm -rf "$$root"' EXIT; \
	 xcrun swiftc -swift-version 5 -O -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/Support.swift Sources/Pairing.swift Sources/DeviceControl.swift Sources/Devices.swift Tests/DeviceControl/main.swift -o "$$root/device-tests"; \
	 "$$root/device-tests"
.PHONY: test-android-crash-env
test-android-crash-env:
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-android-env-tests.XXXXXX); \
	 trap 'status=$$?; if [[ -n "$(TEST_OUTPUT)" ]]; then mkdir -p "$(TEST_OUTPUT)"; for f in "$$root"/*.json; do [[ ! -f "$$f" ]] || cp "$$f" "$(TEST_OUTPUT)/"; done; fi; if [[ "$$root" == /tmp/simwisp-android-env-tests.* ]]; then rm -rf -- "$$root"; fi; exit $$status' EXIT; \
	 xcrun swiftc -swift-version 5 -O Sources/Support.swift Sources/Pairing.swift Sources/DeviceControl.swift Sources/Devices.swift Tests/AndroidCrashEnv/main.swift -o "$$root/tests"; \
	 "$$root/tests" "$$root" $(ANDROID_CRASH_ENV_PHASE)

.PHONY: test-simulator-quit
# Compatibility alias: the old timing-only contract is superseded.
test-simulator-quit: test-ios-window-processes

test-capture:
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-capture-tests.XXXXXX); trap 'rm -rf "$$root"' EXIT; \
	 xcrun swiftc -swift-version 5 -O -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/Support.swift Sources/Pairing.swift Sources/H264SPS.swift Sources/Video.swift Sources/DeviceControl.swift Sources/Devices.swift Sources/Capture.swift Tests/Capture/main.swift -o "$$root/capture-tests"; \
	 "$$root/capture-tests"
test-metro-native:
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-metro-native.XXXXXX); trap 'rm -rf "$$root"' EXIT; \
	 xcrun swiftc -swift-version 5 -O $(filter-out Sources/SimwispApp.swift,$(SOURCES)) Tests/Metro/Native/main.swift -o "$$root/tests"; "$$root/tests"
test-metro-console:
	@NODE='$(NODE)' Tests/Metro/run.sh
test-sps:
	@set -euo pipefail; exe=$$(mktemp /tmp/simwisp-sps-tests.XXXXXX); trap 'rm -f "$$exe"' EXIT; \
	 xcrun swiftc -swift-version 5 -O Sources/H264SPS.swift Tests/Video/SPS/main.swift -o "$$exe"; \
	 "$$exe"
test-video: test-sps
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-video-tests.XXXXXX); trap 'rm -rf "$$root"' EXIT; \
	 xcrun swiftc -swift-version 5 -O -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/Support.swift Sources/Pairing.swift Sources/H264SPS.swift Sources/Video.swift Sources/TLS.swift Sources/DeviceControl.swift Sources/Devices.swift Sources/Capture.swift Tests/Video/main.swift -o "$$root/video-tests"; \
	 "$$root/video-tests" "$$root/results"; \
	 if [[ -n "$${TEST_OUTPUT:-}" ]]; then mkdir -p "$$TEST_OUTPUT"; cp "$$root/results/video-review.json" "$$TEST_OUTPUT/"; fi
# Opt-in real-codec fidelity regression. Use4200 static frames to cross the
# automatic3600-frame boundary (about4min total for all three capture paths).
VIDEO_QUALITY_SOURCE ?= Sources/Video.swift
test-video-quality:
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-video-quality-tests.XXXXXX); \
	 trap 'status=$$?; if [[ -n "$${TEST_OUTPUT:-}" && -d "$$root/results" ]]; then mkdir -p "$$TEST_OUTPUT"; cp "$$root"/results/*.json "$$TEST_OUTPUT/"; fi; rm -rf "$$root"; exit $$status' EXIT; \
	 xcrun swiftc -swift-version 5 -O -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/Support.swift Sources/Pairing.swift Sources/H264SPS.swift '$(VIDEO_QUALITY_SOURCE)' Sources/DeviceControl.swift Sources/Devices.swift Sources/Capture.swift Tests/Video/Quality/main.swift -o "$$root/quality-tests"; \
	 mkdir -p "$$root/results"; "$$root/quality-tests" "$$root/results"
test-stream-flow:
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-flow-tests.XXXXXX); trap 'rm -rf "$$root"' EXIT; \
	 xcrun swiftc -swift-version 5 -O Sources/StreamFlow.swift Tests/Streaming/main.swift -o "$$root/flow-tests"; \
	 "$$root/flow-tests"
test-decoder:
	NODE="$(NODE)" Tests/Video/run-decoder.sh
test-tls:
	NODE="$(NODE)" Tests/TLS/run.sh
test-browser-accessibility:
	@NODE='$(NODE)' Tests/Browser/run.sh
test-browser-device-control:
	@NODE='$(NODE)' Tests/DeviceControl/run-service.sh
test-browser-headless:
	@HEADLESS_REVIEW=1 NODE='$(NODE)' Tests/DeviceControl/run-service.sh
run: build
	open '$(APP)'
install:
	@echo 'No automatic installation. Build and run in this project; ask permission before installing anything.'
	@exit 1
clean:
	rm -rf build

.PHONY: test-android
test-android:
	@NODE='$(NODE)' Tests/Android/run.sh

.PHONY: test-android-parity
test-android-parity:
	@ANDROID_PARITY=1 NODE='$(NODE)' Tests/Android/run.sh

.PHONY: test-android-performance
test-android-performance:
	@ANDROID_PERFORMANCE=1 NODE='$(NODE)' Tests/Android/run.sh

.PHONY: test-android-jpeg-surface
test-android-jpeg-surface:
	@Tests/Android/run-surface.sh

.PHONY: test-android-jpeg
test-android-jpeg: test-android-jpeg-surface
	@ANDROID_JPEG=1 NODE='$(NODE)' Tests/Android/run.sh

.PHONY: test-raw-storage
test-raw-storage:
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-raw-storage-tests.XXXXXX); trap 'rm -rf "$$root"' EXIT; \
	 xcrun swiftc -swift-version 5 -O Sources/Support.swift Sources/Pairing.swift Sources/H264SPS.swift Sources/Video.swift Sources/ScrcpyProtocol.swift Sources/EmulatorRawWire.swift Tests/Android/RawStorage.swift Tests/Android/Storage/main.swift -o "$$root/tests"; "$$root/tests"

.PHONY: test-raw-cpu
test-raw-cpu:
	@Tests/Android/run-raw-benchmark.sh

.PHONY: test-android-physical
test-android-physical:
	@ANDROID_PHYSICAL=1 NODE='$(NODE)' Tests/Android/run.sh

.PHONY: test-android-raw
test-android-raw:
	@ANDROID_RAW=1 NODE='$(NODE)' Tests/Android/run.sh

.PHONY: test-android-emulator-scrcpy
test-android-emulator-scrcpy:
	@ANDROID_EMULATOR_SCRCPY=1 NODE='$(NODE)' Tests/Android/run.sh

.PHONY: test-native test-native-browser
test-native:
	@NODE='$(NODE)' Tests/Native/run.sh
test-native-browser:
	@NATIVE_BROWSER=1 NODE='$(NODE)' Tests/Native/run.sh

.PHONY: test-backend-ui
test-backend-ui:
	@TEST_OUTPUT="$(TEST_OUTPUT)" "$(NODE)" Tests/Browser/backend-copy.mjs

.PHONY: test-ios-window-processes
test-ios-window-processes: test-ios-boot-frame-state
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-window-process-tests.XXXXXX); \
	 trap 'status=$$?; if [[ -n "$(TEST_OUTPUT)" ]]; then mkdir -p "$(TEST_OUTPUT)"; for f in "$$root"/*.json; do [[ ! -f "$$f" ]] || cp "$$f" "$(TEST_OUTPUT)/"; done; fi; if [[ "$$root" == /tmp/simwisp-window-process-tests.* ]]; then rm -rf -- "$$root"; fi; exit $$status' EXIT; \
	 xcrun swiftc -swift-version 5 -O Sources/Support.swift Sources/Pairing.swift Sources/DeviceControl.swift Sources/Devices.swift Tests/IOSWindowProcesses/main.swift -o "$$root/tests"; \
	 "$$root/tests" "$$root" $(IOS_PROCESS_PHASE); "$(NODE)" Tests/IOSWindowProcesses/frontend.mjs "$$root"; "$(NODE)" Tests/IOSWindowProcesses/stream-refresh.mjs "$$root"

.PHONY: test-ios-boot-frame-state
test-ios-boot-frame-state:
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-boot-frame-tests.XXXXXX); \
	 trap 'status=$$?; if [[ -n "$(TEST_OUTPUT)" ]]; then mkdir -p "$(TEST_OUTPUT)"; for f in "$$root"/*.json; do [[ ! -f "$$f" ]] || cp "$$f" "$(TEST_OUTPUT)/"; done; fi; if [[ "$$root" == /tmp/simwisp-boot-frame-tests.* ]]; then rm -rf -- "$$root"; fi; exit $$status' EXIT; \
	 "$(NODE)" Tests/IOSWindowProcesses/boot-frame-state.mjs "$$root"

.PHONY: test-headless-mode
test-headless-mode:
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-mode-tests.XXXXXX); trap 'rm -rf "$$root"' EXIT; \
	 xcrun swiftc -swift-version 5 -O Sources/Support.swift Sources/Pairing.swift Sources/DeviceControl.swift Sources/Devices.swift Tests/HeadlessMode/main.swift -o "$$root/tests"; \
	 "$$root/tests" "$$root"; \
	 if [[ -n "$(TEST_OUTPUT)" ]]; then mkdir -p "$(TEST_OUTPUT)"; cp "$$root"/*.json "$(TEST_OUTPUT)/"; fi

.PHONY: test-headless-ios-controls
test-headless-ios-controls:
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-headless-control-tests.XXXXXX); trap 'rm -rf "$$root"' EXIT; \
	 xcrun swiftc -swift-version 5 -O Sources/Support.swift Sources/Pairing.swift Sources/NativeRuntime.swift Sources/NativeInput.swift Sources/NativeInputRuntime.swift Sources/HeadlessIOSControl.swift Tests/HeadlessControls/main.swift -o "$$root/tests"; \
	 "$$root/tests" "$$root"; \
	 if [[ -n "$(TEST_OUTPUT)" ]]; then mkdir -p "$(TEST_OUTPUT)"; cp "$$root"/*.json "$(TEST_OUTPUT)/"; fi

.PHONY: test-native-input test-native-input-builders test-native-input-services test-native-input-browser
test-native-input-browser:
	@HEADLESS_REVIEW=1 NATIVE_INPUT_REVIEW=1 NATIVE_INPUT_PHASE="$(NATIVE_INPUT_PHASE)" NODE='$(NODE)' Tests/DeviceControl/run-service.sh

test-native-input test-native-input-builders test-native-input-services:
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-native-input-tests.XXXXXX); trap 'rm -rf "$$root"' EXIT; \
	 xcrun swiftc -swift-version 5 -O Sources/Support.swift Sources/Pairing.swift Sources/NativeRuntime.swift Sources/NativeInput.swift Sources/NativeInputRuntime.swift Tests/NativeInput/main.swift -o "$$root/tests"; \
	 "$$root/tests" "$$root" $(if $(filter test-native-input-builders,$@),--builders,$(if $(filter test-native-input-services,$@),--services,)); \
	 if [[ -n "$(TEST_OUTPUT)" ]]; then mkdir -p "$(TEST_OUTPUT)"; cp "$$root"/*.json "$(TEST_OUTPUT)/"; fi
