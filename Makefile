SHELL := /bin/zsh

PROJECT := SpeedRead.xcodeproj
SCHEME := SpeedRead
LOGIC_SCHEME := SpeedReadLogicTests
INTEGRATION_SCHEME := SpeedReadIntegrationTests
HOST_ARCH := $(shell uname -m)
CONFIGURATION ?= Debug
DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro
DERIVED_DATA ?= .build/DerivedData
LOGIC_DERIVED_DATA ?= .build/LogicDerivedData
ARCHIVE_PATH ?= .build/SpeedRead.xcarchive
TOOLS_BIN ?= $(abspath .build/tools/bin)
XCODEGEN ?= $(TOOLS_BIN)/xcodegen
SWIFTFORMAT ?= $(TOOLS_BIN)/swiftformat
SWIFTLINT ?= $(TOOLS_BIN)/swiftlint
TEST ?=
UI_TEST ?=
UI_RETRY ?= NO
UI_RESULT_BUNDLE ?=
APP_STORE_SCREENSHOTS ?= AppStore/Screenshots
IPHONE_SCREENSHOT_SIMULATOR ?= iPhone 17 Pro Max
IPAD_SCREENSHOT_SIMULATOR ?= iPad Pro 13-inch (M5)

export PATH := $(TOOLS_BIN):$(PATH)

UI_RETRY_OPTIONS = $(if $(filter YES yes true 1,$(UI_RETRY)),-retry-tests-on-failure -test-iterations 2,)
UI_RESULT_OPTIONS = $(if $(UI_RESULT_BUNDLE),-resultBundlePath $(UI_RESULT_BUNDLE),)

.PHONY: bootstrap fixtures generate format format-check lint tooling-check build build-for-testing test unit-test unit-test-without-building
.PHONY: logic-test test-one ui-test ui-smoke ui-test-without-building device-deploy project-check archive-check ci ci-fast version-check
.PHONY: cloudkit-static-check cloudkit-check cloudkit-validate-development cloudkit-import-development cloudkit-verify-development cloudkit-verify-production
.PHONY: app-store-check app-store-live-check app-store-screenshots

bootstrap:
	./Tools/install_tools.sh
	$(MAKE) version-check
	$(MAKE) generate

fixtures:
	./Tools/build_fixtures.sh

generate:
	$(XCODEGEN) generate

format:
	$(SWIFTFORMAT) SpeedRead SpeedReadLogicTests SpeedReadTests SpeedReadUITests

format-check:
	$(SWIFTFORMAT) SpeedRead SpeedReadLogicTests SpeedReadTests SpeedReadUITests --lint

lint:
	$(SWIFTLINT) lint --strict

tooling-check:
	/usr/bin/python3 Tools/Tests/test_summarize_xcresult.py

version-check:
	./Tools/check_versions.sh

build:
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO

build-for-testing:
	xcodebuild build-for-testing \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-testPlan SpeedReadFull \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO

unit-test: build-for-testing unit-test-without-building

unit-test-without-building:
	xcodebuild test-without-building \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-testPlan SpeedReadUnit \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO

logic-test:
	@selector='$(TEST)'; \
	args=(); \
	if [[ -n "$$selector" ]]; then \
		[[ "$$selector" == SpeedReadLogicTests/* ]] || selector="SpeedReadLogicTests/$$selector"; \
		[[ "$$selector" != */*/* || "$$selector" == *'('* ]] || selector="$$selector()"; \
		args+=("-only-testing:$$selector"); \
	fi; \
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(LOGIC_SCHEME) \
		-destination 'platform=macOS,arch=$(HOST_ARCH)' \
		-derivedDataPath $(LOGIC_DERIVED_DATA) \
		"$${args[@]}" \
		CODE_SIGNING_ALLOWED=NO

test-one:
	@test -n "$(TEST)" || { echo "Usage: make test-one TEST=<target/suite/test>"; exit 2; }
	@selector='$(TEST)'; \
	[[ "$$selector" == *'('* ]] || selector="$$selector()"; \
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(INTEGRATION_SCHEME) \
		-testPlan SpeedReadUnit \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:"$$selector" \
		CODE_SIGNING_ALLOWED=NO

ui-test:
	@test -n "$(UI_TEST)" || { echo "Usage: make ui-test UI_TEST=<method|class/method>"; exit 2; }
	@selector='$(UI_TEST)'; \
	[[ "$$selector" == */* ]] || selector="SpeedReadUITests/$$selector"; \
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-testPlan SpeedReadFull \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:"SpeedReadUITests/$$selector" \
		CODE_SIGNING_ALLOWED=NO

ui-smoke:
	xcodebuild test-without-building \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-testPlan SpeedReadFull \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:SpeedReadUITests/SpeedReadUITests/testEmptyLibraryIsVisible \
		-only-testing:SpeedReadUITests/SpeedReadUITests/testImportAndOpenRegularReader \
		-only-testing:SpeedReadUITests/PDFUITests/testImportNativePDFAndPrepareLocalOCRSpeedMode \
		-only-testing:SpeedReadUITests/SpeedReadUITests/testFreeLibraryLimitOffersAndUnlocksPro \
		$(UI_RETRY_OPTIONS) \
		$(UI_RESULT_OPTIONS) \
		CODE_SIGNING_ALLOWED=NO

ui-test-without-building:
	xcodebuild test-without-building \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-testPlan SpeedReadFull \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:SpeedReadUITests \
		$(UI_RETRY_OPTIONS) \
		$(UI_RESULT_OPTIONS) \
		CODE_SIGNING_ALLOWED=NO

test: build-for-testing unit-test-without-building ui-test-without-building

device-deploy:
	DERIVED_DATA="$(abspath $(DERIVED_DATA))" \
	CONFIGURATION="$(CONFIGURATION)" \
	DEVICE_UDID="$(DEVICE_UDID)" \
	CORE_DEVICE_ID="$(CORE_DEVICE_ID)" \
	DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" \
		./Tools/device_deploy.sh

cloudkit-static-check:
	/usr/bin/python3 Tools/test_verify_cloudkit_schema.py
	/usr/bin/python3 Tools/verify_cloudkit_schema.py local \
		--schema CloudKit/SpeedRead.ckdb \
		--record-source SpeedRead/Core/Sync/LibrarySyncRecord.swift \
		--codec-source SpeedRead/Core/Sync/CloudKitRecordCodec.swift \
		--entitlements SpeedRead/Resources/SpeedRead.entitlements \
		--project project.yml \
		--debug-config Config/Debug.xcconfig \
		--release-config Config/Release.xcconfig

cloudkit-check: cloudkit-static-check
	./Tools/cloudkit_setup.sh check

cloudkit-validate-development:
	./Tools/cloudkit_setup.sh validate-development

cloudkit-import-development:
	./Tools/cloudkit_setup.sh import-development

cloudkit-verify-development:
	./Tools/cloudkit_setup.sh verify-development

cloudkit-verify-production:
	./Tools/cloudkit_setup.sh verify-production

app-store-check:
	/usr/bin/python3 Tools/Tests/test_app_store_submission.py
	/usr/bin/python3 Tools/app_store_submission.py check \
		--root . \
		--screenshots-root $(APP_STORE_SCREENSHOTS)

app-store-live-check:
	/usr/bin/python3 Tools/app_store_submission.py live-check --root .

app-store-screenshots:
	IPHONE_SCREENSHOT_SIMULATOR='$(IPHONE_SCREENSHOT_SIMULATOR)' \
	IPAD_SCREENSHOT_SIMULATOR='$(IPAD_SCREENSHOT_SIMULATOR)' \
	DERIVED_DATA='$(abspath $(DERIVED_DATA))' \
	OUTPUT_ROOT='$(abspath $(APP_STORE_SCREENSHOTS))' \
		./Tools/capture_app_store_screenshots.sh

project-check:
	$(XCODEGEN) generate
	git diff --exit-code -- $(PROJECT)

archive-check:
	xcodebuild archive \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath $(ARCHIVE_PATH) \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO

ci-fast: version-check tooling-check cloudkit-check app-store-check project-check format-check lint logic-test build-for-testing unit-test-without-building ui-smoke

ci: version-check tooling-check cloudkit-check app-store-check project-check format-check lint logic-test test archive-check
