# SwiftApoderado / apoderado CLI Makefile
# Build and install the apoderado CLI

SCHEME = apoderado
TEST_SCHEME = SwiftApoderado-Package
BINARY = apoderado
BIN_DIR = ./bin
DESTINATION = platform=macOS,arch=arm64
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData

.PHONY: all build release install clean test test-unit test-integration resolve lint help

all: install

resolve:
	xcodebuild -resolvePackageDependencies -scheme $(SCHEME) -destination '$(DESTINATION)'
	@echo "Package dependencies resolved."

build: resolve
	xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' build

release: resolve
	xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' -configuration Release build
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(find $(DERIVED_DATA)/SwiftApoderado-*/Build/Products/Release -name $(BINARY) -type f 2>/dev/null | head -1 | xargs dirname); \
	if [ -n "$$PRODUCT_DIR" ]; then \
		cp "$$PRODUCT_DIR/$(BINARY)" $(BIN_DIR)/; \
		echo "Installed $(BINARY) to $(BIN_DIR)/ (Release)"; \
	else \
		echo "Error: Could not find $(BINARY) in DerivedData"; \
		exit 1; \
	fi

install: resolve
	xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' build
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(find $(DERIVED_DATA)/SwiftApoderado-*/Build/Products/Debug -name $(BINARY) -type f 2>/dev/null | head -1 | xargs dirname); \
	if [ -n "$$PRODUCT_DIR" ]; then \
		cp "$$PRODUCT_DIR/$(BINARY)" $(BIN_DIR)/; \
		echo "Installed $(BINARY) to $(BIN_DIR)/ (Debug)"; \
	else \
		echo "Error: Could not find $(BINARY) in DerivedData"; \
		exit 1; \
	fi

# Fast unit tests (no binary required)
test-unit:
	@echo "Running unit tests..."
	xcodebuild test \
	  -scheme $(TEST_SCHEME) \
	  -destination '$(DESTINATION)' \
	  -skip-testing:ApoderadoTests/ApoderadoBinaryIntegrationTests

# Integration tests (requires compiled binary at ./bin/apoderado)
test-integration: install
	@echo "Running binary integration tests against ./bin/$(BINARY)..."
	xcodebuild test \
	  -scheme $(TEST_SCHEME) \
	  -destination '$(DESTINATION)' \
	  -only-testing:ApoderadoTests/ApoderadoBinaryIntegrationTests

test: test-unit test-integration
	@echo "All tests complete!"

lint:
	swift format -i -r .

clean:
	xcodebuild clean -scheme $(SCHEME) -destination '$(DESTINATION)' 2>/dev/null || true
	rm -rf $(BIN_DIR)
	rm -rf $(DERIVED_DATA)/SwiftApoderado-*

help:
	@echo "SwiftApoderado / apoderado CLI Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  resolve          - Resolve all SPM package dependencies"
	@echo "  build            - Development build (xcodebuild debug, no copy)"
	@echo "  install          - Debug build + copy to ./bin (default)"
	@echo "  release          - Release build + copy to ./bin"
	@echo "  lint             - Format Swift source files"
	@echo "  test             - Run all tests (unit + integration)"
	@echo "  test-unit        - Run fast unit tests only"
	@echo "  test-integration - Run binary integration tests (requires built binary)"
	@echo "  clean            - Clean build artifacts"
	@echo "  help             - Show this help"
	@echo ""
	@echo "All builds use: -destination '$(DESTINATION)'"
