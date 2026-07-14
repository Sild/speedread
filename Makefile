SHELL := /bin/zsh

PROJECT := FastReader.xcodeproj
SCHEME := FastReader
CONFIGURATION ?= Debug
DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro
DERIVED_DATA ?= .build/DerivedData
ARCHIVE_PATH ?= .build/FastReader.xcarchive
UI_TEST ?=

.PHONY: bootstrap fixtures generate format format-check lint build test unit-test ui-test device-deploy project-check archive-check ci version-check

bootstrap:
	brew bundle
	$(MAKE) version-check
	$(MAKE) generate

fixtures:
	./Tools/build_fixtures.sh

generate:
	xcodegen generate

format:
	swiftformat FastReader FastReaderTests FastReaderUITests

format-check:
	swiftformat FastReader FastReaderTests FastReaderUITests --lint

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
		-testPlan FastReaderFull \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO

unit-test:
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-testPlan FastReaderUnit \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO

ui-test:
	@test -n "$(UI_TEST)" || { echo "Usage: make ui-test UI_TEST=<FastReaderUITests method>"; exit 2; }
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-testPlan FastReaderFull \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA) \
		-only-testing:FastReaderUITests/FastReaderUITests/$(UI_TEST) \
		CODE_SIGNING_ALLOWED=NO

device-deploy:
	DERIVED_DATA="$(abspath $(DERIVED_DATA))" \
	CONFIGURATION="$(CONFIGURATION)" \
	DEVICE_UDID="$(DEVICE_UDID)" \
	CORE_DEVICE_ID="$(CORE_DEVICE_ID)" \
	DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" \
		./Tools/device_deploy.sh

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

ci: version-check project-check format-check lint build test archive-check
