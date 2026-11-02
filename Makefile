# jumpcall — build & bundle without Xcode (SwiftPM + Command Line Tools only)

APP_NAME    := JumpCall
BUNDLE_ID   := io.github.joncode.jumpcall
BIN         := jumpcall
BUILD_DIR   := .build/release
BUNDLE      := build/$(APP_NAME).app
INSTALL_APP := $(HOME)/Applications/$(APP_NAME).app
ARCH_FLAGS  :=
VERSION      = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DIST_NAME    = jumpcall-$(VERSION)
DIST_TARBALL = build/$(DIST_NAME)-macos-universal.tar.gz

.PHONY: preflight build bundle run install uninstall test clean dist

# Friendly failures for the two most common broken-machine cases.
preflight:
	@command -v swift >/dev/null 2>&1 || { \
		echo "error: swift not found."; \
		echo "install the Xcode Command Line Tools first:  xcode-select --install"; \
		exit 1; }
	@swift -version 2>/dev/null | awk '/Swift version/ { split($$4, v, "."); if (v[1] < 6) { \
		print "error: Swift 6+ required, found " $$4 " — update Command Line Tools (Software Update)"; exit 1 } }'
	@sw_vers -productVersion | awk -F. '{ if ($$1 < 14) { \
		print "error: macOS 14 (Sonoma) or newer required, found " $$0; exit 1 } }'

build: preflight
	swift build -c release $(ARCH_FLAGS)

test: preflight
	swift run -c release JumpCallTests

# Prefer a stable signing identity when one exists: ad-hoc signatures ("-")
# change identity on every rebuild, which invalidates granted TCC permissions
# (Accessibility for the hotkey). Create one once in Keychain Access:
# Certificate Assistant → Create a Certificate → name "JumpCall Dev",
# type "Code Signing" — and rebuilds keep their permissions.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"JumpCall Dev"' && echo JumpCall Dev || echo -)

# Assemble a real .app bundle. This matters: launching the bundle (via `open` /
# launchd) gives jumpcall its own TCC identity, so Automation permission prompts
# say "JumpCall wants to control Safari" instead of attributing to the terminal.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BUILD_DIR)/$(BIN) $(BUNDLE)/Contents/MacOS/$(BIN)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	mkdir -p $(BUNDLE)/Contents/Resources
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign "$(SIGN_ID)" --identifier $(BUNDLE_ID) $(BUNDLE)
	@if [ "$(SIGN_ID)" = "-" ]; then \
		echo "note: ad-hoc signed — Accessibility grants reset on each rebuild."; \
		echo "      Create a 'JumpCall Dev' code-signing cert in Keychain Access to fix."; \
	fi

# Release artifact for the Homebrew formula: a universal (arm64 + x86_64)
# JumpCall.app, ad-hoc signed, tarred inside a jumpcall-<version>/ folder.
# The wrapper folder matters: Homebrew cd's into an archive's single
# top-level directory, so the formula finds JumpCall.app right there.
# Multi-arch SwiftPM builds go through Xcode's build system, so this target
# needs full Xcode — it runs in CI (release.yml), not on users' machines.
dist: ARCH_FLAGS := --arch arm64 --arch x86_64
dist: BUILD_DIR  := .build/apple/Products/Release
dist: SIGN_ID    := -
dist: bundle
	@lipo $(BUNDLE)/Contents/MacOS/$(BIN) -verify_arch arm64 x86_64 || { \
		echo "error: $(BIN) is not universal"; exit 1; }
	rm -rf build/$(DIST_NAME) $(DIST_TARBALL)
	mkdir -p build/$(DIST_NAME)
	cp -R $(BUNDLE) LICENSE build/$(DIST_NAME)/
	COPYFILE_DISABLE=1 tar -czf $(DIST_TARBALL) -C build $(DIST_NAME)
	@echo "$(DIST_TARBALL)"
	@shasum -a 256 $(DIST_TARBALL)

run: bundle
	open $(BUNDLE)

# Copy to ~/Applications, register launch-at-login, symlink the CLI, launch.
install: bundle
	$(BUNDLE)/Contents/MacOS/$(BIN) install --from $(BUNDLE)

uninstall:
	@if [ -x "$(INSTALL_APP)/Contents/MacOS/$(BIN)" ]; then \
		"$(INSTALL_APP)/Contents/MacOS/$(BIN)" uninstall; \
	else \
		echo "$(INSTALL_APP) not found — nothing to uninstall"; \
	fi

clean:
	rm -rf .build build
