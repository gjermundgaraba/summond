.PHONY: build test lint lint-fix install-binary

INSTALL_DIR := $(HOME)/.local/bin
BINARY_NAME := keybindd
SOURCE_BINARY := .build/release/$(BINARY_NAME)
TARGET_BINARY := $(INSTALL_DIR)/$(BINARY_NAME)
TEMP_BINARY := $(INSTALL_DIR)/.$(BINARY_NAME).tmp

build:
	swift build -c release

test:
	swift test

lint:
	xcrun swift format lint --recursive Sources Tests

lint-fix:
	xcrun swift format format --in-place --recursive Sources Tests

install-binary: build
	@mkdir -p "$(INSTALL_DIR)"
	@cp "$(SOURCE_BINARY)" "$(TEMP_BINARY)"
	@chmod 755 "$(TEMP_BINARY)"
	@mv -f "$(TEMP_BINARY)" "$(TARGET_BINARY)"
	@echo "Installed $(TARGET_BINARY)"
	@case ":$(PATH):" in \
		*:"$(INSTALL_DIR)":*) ;; \
		*) echo "PATH hint: add $(INSTALL_DIR) to PATH" ;; \
	esac
