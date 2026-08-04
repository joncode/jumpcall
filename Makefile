# jumpcall — build & bundle without Xcode (SwiftPM + Command Line Tools only)

APP_NAME    := JumpCall
BUNDLE_ID   := io.github.joncode.jumpcall
BIN         := jumpcall
BUILD_DIR   := .build/release
BUNDLE      := build/$(APP_NAME).app
INSTALL_APP := $(HOME)/Applications/$(APP_NAME).app

.PHONY: build bundle run install uninstall clean

build:
	swift build -c release

# Assemble a real .app bundle. This matters: launching the bundle (via `open` /
# launchd) gives jumpcall its own TCC identity, so Automation permission prompts
# say "JumpCall wants to control Safari" instead of attributing to the terminal.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BUILD_DIR)/$(BIN) $(BUNDLE)/Contents/MacOS/$(BIN)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign - --identifier $(BUNDLE_ID) $(BUNDLE)

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
