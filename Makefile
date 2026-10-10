SHELL := /bin/bash
APP := build/Simwisp.app
SOURCES := $(wildcard Sources/*.swift)
ARCH := $(shell uname -m)
SDK := $(shell xcrun --sdk macosx --show-sdk-path)

.PHONY: build check run clean install
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
run: build
	open '$(APP)'
install:
	@echo 'No automatic installation. Build and run in this project; ask permission before installing anything.'
	@exit 1
clean:
	rm -rf build
