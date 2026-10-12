SHELL := /bin/bash
APP := build/Simwisp.app
SOURCES := $(wildcard Sources/*.swift)
NODE ?= node
ARCH := $(shell uname -m)
SDK := $(shell xcrun --sdk macosx --show-sdk-path)

.PHONY: build check test test-pairing test-accessibility test-input test-video test-sps test-decoder test-tls test-browser-accessibility run clean install
build:
	@mkdir -p '$(APP)/Contents/MacOS' '$(APP)/Contents/Resources'
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
test: test-pairing test-accessibility test-input test-video
test-pairing:
	@mkdir -p build/tests
	xcrun swiftc -swift-version 5 -O -g -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/Support.swift Sources/Pairing.swift Tests/main.swift -o build/tests/pairing-tests
	@build/tests/pairing-tests
test-accessibility:
	@mkdir -p build/tests
	xcrun swiftc -swift-version 5 -O -g -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/Support.swift Sources/Pairing.swift Sources/Accessibility.swift Tests/Accessibility/main.swift -o build/tests/accessibility-tests
	@build/tests/accessibility-tests
test-input:
	@mkdir -p build/tests
	xcrun swiftc -swift-version 5 -O -g -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/Support.swift Sources/Pairing.swift Sources/Devices.swift Sources/Input.swift Tests/Input/main.swift -o build/tests/input-tests
	@build/tests/input-tests
test-sps:
	@set -euo pipefail; exe=$$(mktemp /tmp/simwisp-sps-tests.XXXXXX); trap 'rm -f "$$exe"' EXIT; \
	 xcrun swiftc -swift-version 5 -O Sources/H264SPS.swift Tests/Video/SPS/main.swift -o "$$exe"; \
	 "$$exe"
test-video: test-sps
	@set -euo pipefail; root=$$(mktemp -d /tmp/simwisp-video-tests.XXXXXX); trap 'rm -rf "$$root"' EXIT; \
	 xcrun swiftc -swift-version 5 -O -sdk '$(SDK)' -target $(ARCH)-apple-macosx14.0 Sources/Support.swift Sources/Pairing.swift Sources/H264SPS.swift Sources/Video.swift Sources/TLS.swift Sources/Devices.swift Sources/Capture.swift Tests/Video/main.swift -o "$$root/video-tests"; \
	 "$$root/video-tests" "$$root/results"; \
	 if [[ -n "$${TEST_OUTPUT:-}" ]]; then mkdir -p "$$TEST_OUTPUT"; cp "$$root/results/video-review.json" "$$TEST_OUTPUT/"; fi
test-decoder:
	NODE="$(NODE)" Tests/Video/run-decoder.sh
test-tls:
	NODE="$(NODE)" Tests/TLS/run.sh
test-browser-accessibility:
	@NODE='$(NODE)' Tests/Browser/run.sh
run: build
	open '$(APP)'
install:
	@echo 'No automatic installation. Build and run in this project; ask permission before installing anything.'
	@exit 1
clean:
	rm -rf build
