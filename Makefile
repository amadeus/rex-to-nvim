APP_NAME ?= Neovim
BUNDLE_ID ?= local.ft-forwarder.neovim
VERSION ?= 0.1.0
INSTALL_DIR ?= $(HOME)/Applications
DEVICONS ?= $(HOME)/.local/share/nvim/lazy/nvim-web-devicons

BUILD := build
APP := $(BUILD)/$(APP_NAME).app
INSTALLED := $(INSTALL_DIR)/$(APP_NAME).app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all app install uninstall clean devicons

all: app

$(BUILD)/ft-forwarder: Sources/main.swift
	@mkdir -p $(BUILD)
	swiftc -O -target arm64-apple-macos13.0 -o $@ $<

$(BUILD)/Info.plist: tools/gen-plist.swift data/devicons.json data/include.txt data/exclude.txt $(wildcard $(BUILD)/icons/*.icns)
	swift tools/gen-plist.swift data $(BUILD) "$(APP_NAME)" $(BUNDLE_ID) $(VERSION)

app: $(BUILD)/ft-forwarder $(BUILD)/Info.plist
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp $(BUILD)/ft-forwarder "$(APP)/Contents/MacOS/"
	cp $(BUILD)/Info.plist "$(APP)/Contents/"
	if ls $(BUILD)/icons/*.icns >/dev/null 2>&1; then cp $(BUILD)/icons/*.icns "$(APP)/Contents/Resources/"; fi
	codesign --force --sign - "$(APP)"

install: app
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	$(LSREGISTER) -f "$(INSTALLED)"
	@echo "Installed $(INSTALLED)"

uninstall:
	-$(LSREGISTER) -u "$(INSTALLED)"
	rm -rf "$(INSTALLED)"

# Refresh data/devicons.json from the installed nvim-web-devicons plugin.
devicons:
	nvim --headless --clean -l tools/export-devicons.lua "$(DEVICONS)" data/devicons.json

clean:
	rm -rf $(BUILD)
