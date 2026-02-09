APP_NAME = Ripcord
BUILD_DIR = .build
BUNDLE = $(APP_NAME).app
INSTALL_DIR = $(HOME)/Applications

SWIFTC = swiftc

TEST_SOURCES = Tests/test_components.swift \
	Sources/Ripcord/AudioConstants.swift \
	Sources/Ripcord/CircularAudioBuffer.swift \
	Sources/Ripcord/AudioFileWriter.swift

.PHONY: build bundle bundle-unsigned install clean test test-e2e

build:
	swift build -c release

BIN_PATH = $(shell swift build -c release --show-bin-path)

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(BIN_PATH)/$(APP_NAME) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp $(BIN_PATH)/transcribe $(BUNDLE)/Contents/MacOS/transcribe
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	@if codesign --force --sign "Ripcord Development" --entitlements Ripcord.entitlements $(BUNDLE) 2>/dev/null; then \
		echo "Signed with 'Ripcord Development' identity"; \
	else \
		echo "WARNING: Code signing skipped ('Ripcord Development' certificate not found). You will need to re-grant audio permissions after each rebuild."; \
	fi

install: bundle
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALL_DIR)/$(BUNDLE)
	cp -R $(BUNDLE) $(INSTALL_DIR)/$(BUNDLE)

test:
	mkdir -p $(BUILD_DIR)
	$(SWIFTC) -O -target arm64-apple-macosx14.2 -framework AudioToolbox -framework AVFoundation -parse-as-library -o $(BUILD_DIR)/test_components Sources/Ripcord/AudioConstants.swift Sources/Ripcord/CircularAudioBuffer.swift Sources/Ripcord/AudioFileWriter.swift Tests/test_components.swift
	$(BUILD_DIR)/test_components

E2E_BUNDLE = $(BUILD_DIR)/RipcordE2ETest.app

test-e2e:
	mkdir -p $(BUILD_DIR)
	$(SWIFTC) -O -target arm64-apple-macosx14.2 \
	  -framework AudioToolbox -framework AVFoundation \
	  -framework CoreAudio -framework Accelerate \
	  -parse-as-library \
	  -o $(BUILD_DIR)/test_e2e \
	  Sources/Ripcord/AudioConstants.swift \
	  Sources/Ripcord/CircularAudioBuffer.swift \
	  Sources/Ripcord/AudioFileWriter.swift \
	  Sources/Ripcord/SystemAudioCapture.swift \
	  Tests/test_e2e.swift
	rm -rf $(E2E_BUNDLE)
	mkdir -p $(E2E_BUNDLE)/Contents/MacOS
	cp $(BUILD_DIR)/test_e2e $(E2E_BUNDLE)/Contents/MacOS/RipcordE2ETest
	/usr/libexec/PlistBuddy \
	  -c "Add :CFBundleIdentifier string com.vibe.ripcord.e2etest" \
	  -c "Add :CFBundleName string RipcordE2ETest" \
	  -c "Add :CFBundleExecutable string RipcordE2ETest" \
	  -c "Add :CFBundlePackageType string APPL" \
	  -c "Add :LSUIElement bool true" \
	  -c "Add :NSAudioCaptureUsageDescription string 'Ripcord E2E test needs system audio recording to verify capture pipeline.'" \
	  -c "Add :NSMicrophoneUsageDescription string 'Ripcord E2E test needs microphone access.'" \
	  $(E2E_BUNDLE)/Contents/Info.plist
	codesign --force --sign "Ripcord Development" --entitlements Ripcord.entitlements $(E2E_BUNDLE)
	@echo "Launching E2E test (requires Screen & System Audio Recording permission)..."
	@LOG=$$(mktemp /tmp/ripcord_e2e.XXXXXX); \
	  open -W --stdout "$$LOG" --stderr "$$LOG" $(E2E_BUNDLE); \
	  EXIT=$$?; cat "$$LOG"; rm -f "$$LOG"; exit $$EXIT

clean:
	rm -rf $(BUILD_DIR) $(BUNDLE)
