SHELL := /bin/bash
APP := build/Simwisp.app
SOURCES := $(wildcard Sources/*.swift)
NODE ?= node
TEST_BUILD ?= build/tests
ARCH := $(shell uname -m)
SDK := $(shell xcrun --sdk macosx --show-sdk-path)

.PHONY: build check test test-pairing test-accessibility test-input test-capture test-device-control test-video test-video-quality test-sps test-stream-flow test-decoder test-tls test-browser-accessibility test-browser-device-control test-metro-native test-metro-console run clean install
build:
	@mkdir -p '$(APP)/Contents/MacOS' '$(APP)/Contents/Resources'
	@scripts/build-android-jpeg.sh '$(APP)/Contents/Resources/simwisp-jpeg.jar'
	xcrun clang -O2 -Wall -Wextra -Werror -isysroot '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/TerminalHost.c -o '$(APP)/Contents/MacOS/SimwispShell'
	xcrun swiftc -swift-version 5 -O -g -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 $(SOURCES) -o '$(APP)/Contents/MacOS/Simwisp'
	@cp Resources/Info.plist '$(APP)/Contents/Info.plist'
	@cp -R Resources/Web '$(APP)/Contents/Resources/'
	@cp Resources/device-sizes.json '$(APP)/Contents/Resources/'
	@rm -f '$(APP)/Contents/Resources/UPSTREAM-LICENSE'
	codesign --force --sign - --identifier io.simwisp.shell '$(APP)/Contents/MacOS/SimwispShell'
	codesign --force --sign - --identifier io.simwisp.app -r '=designated => identifier "io.simwisp.app"' '$(APP)'
	codesign --verify --deep --strict '$(APP)'
check: build
	@/usr/libexec/PlistBuddy -c 'Print :LSUIElement' '$(APP)/Contents/Info.plist'
test: test-metro-native test-pairing test-accessibility test-input test-capture test-device-control test-video test-stream-flow
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

.PHONY: test-raw-cpu
test-raw-cpu:
	@Tests/Android/run-raw-benchmark.sh

.PHONY: test-android-physical
test-android-physical:
	@ANDROID_PHYSICAL=1 NODE='$(NODE)' Tests/Android/run.sh

.PHONY: test-android-raw
test-android-raw:
	@ANDROID_RAW=1 NODE='$(NODE)' Tests/Android/run.sh
