SHELL := /bin/zsh

PROJECT := SpeedRead.xcodeproj
SCHEME := SpeedRead
CONFIGURATION ?= Debug
DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro
DERIVED_DATA ?= .build/DerivedData
ARCHIVE_PATH ?= .build/SpeedRead.xcarchive
UI_TEST ?=
APP_STORE_SCREENSHOTS ?= AppStore/Screenshots
IPHONE_SCREENSHOT_SIMULATOR ?= iPhone 17 Pro Max
IPAD_SCREENSHOT_SIMULATOR ?= iPad Pro 13-inch (M5)

.PHONY: bootstrap fixtures generate format format-check lint build test unit-test ui-test device-deploy project-check archive-check ci version-check
.PHONY: cloudkit-check cloudkit-validate-development cloudkit-import-development cloudkit-verify-development cloudkit-verify-production
.PHONY: app-store-check app-store-live-check app-store-screenshots

bootstrap:
	brew bundle
	$(MAKE) version-check
	$(MAKE) generate

fixtures:
	./Tools/build_fixtures.sh

generate:
	xcodegen generate

format:
	swiftformat SpeedRead SpeedReadTests SpeedReadUITests

format-check:
	swiftformat SpeedRead SpeedReadTests SpeedReadUITests --lint

lint:
	swiftlint lint --strict

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

test:
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-testPlan SpeedReadFull \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO

unit-test:
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-testPlan SpeedReadUnit \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO

ui-test:
	@test -n "$(UI_TEST)" || { echo "Usage: make ui-test UI_TEST=<SpeedReadUITests method>"; exit 2; }
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-testPlan SpeedReadFull \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:SpeedReadUITests/SpeedReadUITests/$(UI_TEST) \
		CODE_SIGNING_ALLOWED=NO

device-deploy:
	DERIVED_DATA="$(abspath $(DERIVED_DATA))" \
	CONFIGURATION="$(CONFIGURATION)" \
	DEVICE_UDID="$(DEVICE_UDID)" \
	CORE_DEVICE_ID="$(CORE_DEVICE_ID)" \
	DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" \
		./Tools/device_deploy.sh

cloudkit-check:
	/usr/bin/python3 Tools/test_verify_cloudkit_schema.py
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
	xcodegen generate
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

ci: version-check cloudkit-check app-store-check project-check format-check lint build test archive-check
