APP_NAME ?= Neovim
BUNDLE_ID ?= io.github.amadeus.rex-to-nvim
VERSION ?= 0.1.0
INSTALL_DIR ?= /Applications
DEVICONS ?= $(HOME)/.local/share/nvim/lazy/nvim-web-devicons

BUILD := build
APP := $(BUILD)/$(APP_NAME).app
INSTALLED := $(INSTALL_DIR)/$(APP_NAME).app
FONT := assets/fonts/SymbolsNerdFont-Regular.ttf
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all app icons install uninstall clean devicons

all: app

$(BUILD)/rex-to-nvim: Sources/main.swift
	@mkdir -p $(BUILD)
	swiftc -O -target arm64-apple-macos13.0 -o $@ $<

# Writes both Info.plist and types.json.
$(BUILD)/Info.plist: tools/gen-plist.swift data/devicons.json data/extensions.txt
	swift tools/gen-plist.swift data $(BUILD) "$(APP_NAME)" $(BUNDLE_ID) $(VERSION)

$(BUILD)/gen-icons: tools/gen-icons.swift
	@mkdir -p $(BUILD)
	swiftc -O -o $@ $<

$(BUILD)/icons/.stamp: $(BUILD)/gen-icons $(BUILD)/Info.plist $(FONT)
	rm -rf $(BUILD)/icons
	$(BUILD)/gen-icons $(BUILD)/types.json $(FONT) $(BUILD)/icons
	touch $@

icons: $(BUILD)/icons/.stamp

app: $(BUILD)/rex-to-nvim $(BUILD)/Info.plist $(BUILD)/icons/.stamp
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp $(BUILD)/rex-to-nvim "$(APP)/Contents/MacOS/"
	cp $(BUILD)/Info.plist "$(APP)/Contents/"
	# A unique build number per build, so macOS drops its cached icons on install.
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION).$$(date +%s)" "$(APP)/Contents/Info.plist"
	cp $(BUILD)/icons/*.icns "$(APP)/Contents/Resources/"
	codesign --force --sign - "$(APP)"

install: app
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	# macOS registers (and re-registers) the copy in build/ on its own; remove it so
	# only the installed one handles files.
	-$(LSREGISTER) -u "$(APP)"
	rm -rf "$(APP)"
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
