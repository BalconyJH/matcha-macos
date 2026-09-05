PROJECT := Rei.xcodeproj
SCHEME := Rei App

BUILD_CONFIGURATION ?= Release
BUILD_DESTINATION ?= generic/platform=macOS
BUILD_ARCHS ?= arm64 x86_64
DERIVED_DATA_PATH ?= $(CURDIR)/.build/xcode

ARCHIVE_PATH ?= $(CURDIR)/.build/archive/Rei.xcarchive
EXPORT_PATH ?= $(CURDIR)/.build/export
EXPORT_OPTIONS_PLIST ?= $(CURDIR)/.build/ExportOptions.plist
VERSION_CONFIGURATION := Configuration/Shared.xcconfig
APP_PATH ?= $(DERIVED_DATA_PATH)/Build/Products/$(BUILD_CONFIGURATION)/Rei.app
MINIMUM_XCODE_VERSION := 26.6
MINIMUM_MACOS_SDK_VERSION := 26.0

# Signing remains unset for local work. Distribution workflows inject these
# values only after installing credentials into an ephemeral keychain.
CODE_SIGN_STYLE ?=
CODE_SIGN_IDENTITY ?=
DEVELOPMENT_TEAM ?=
CODE_SIGNING_ALLOWED ?=
ALLOW_PROVISIONING_UPDATES ?=
AUTHENTICATION_KEY_PATH ?=
AUTHENTICATION_KEY_ID ?=
AUTHENTICATION_KEY_ISSUER_ID ?=

export PROJECT SCHEME BUILD_CONFIGURATION BUILD_DESTINATION BUILD_ARCHS DERIVED_DATA_PATH
export ARCHIVE_PATH EXPORT_PATH EXPORT_OPTIONS_PLIST APP_PATH
export CODE_SIGN_STYLE CODE_SIGN_IDENTITY DEVELOPMENT_TEAM CODE_SIGNING_ALLOWED
export ALLOW_PROVISIONING_UPDATES AUTHENTICATION_KEY_PATH AUTHENTICATION_KEY_ID
export AUTHENTICATION_KEY_ISSUER_ID

.PHONY: analyze archive build check export format format-check project-check quality release-build-number release-metadata release-version show-settings test verify-universal verify-xcode

check:
	$(MAKE) quality
	$(MAKE) test
	$(MAKE) build BUILD_CONFIGURATION=Debug BUILD_ARCHS="$$(uname -m)"

quality: verify-xcode format-check project-check

verify-xcode:
	@set -eu; \
	if ! xcode_version_output="$$(xcodebuild -version 2>&1)"; then \
		echo "A full Xcode installation is required; Command Line Tools alone are insufficient." >&2; \
		printf '%s\n' "$$xcode_version_output" >&2; \
		exit 1; \
	fi; \
	xcode_version="$$(printf '%s\n' "$$xcode_version_output" | awk 'NR == 1 { print $$2 }')"; \
	sdk_version="$$(xcrun --sdk macosx --show-sdk-version)"; \
	version_at_least() { \
		awk -v actual="$$1" -v minimum="$$2" 'BEGIN { \
			split(actual, actual_parts, "."); \
			split(minimum, minimum_parts, "."); \
			for (i = 1; i <= 3; i++) { \
				actual_part = (i in actual_parts) ? actual_parts[i] + 0 : 0; \
				minimum_part = (i in minimum_parts) ? minimum_parts[i] + 0 : 0; \
				if (actual_part > minimum_part) exit 0; \
				if (actual_part < minimum_part) exit 1; \
			} \
			exit 0; \
		}'; \
	}; \
	for version in "$$xcode_version" "$$sdk_version"; do \
		if ! printf '%s\n' "$$version" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}$$'; then \
			echo "Could not parse the selected Xcode or macOS SDK version: $$version" >&2; \
			exit 1; \
		fi; \
	done; \
	if ! version_at_least "$$xcode_version" "$(MINIMUM_XCODE_VERSION)"; then \
		echo "Xcode $(MINIMUM_XCODE_VERSION) or newer is required; selected $$xcode_version." >&2; \
		exit 1; \
	fi; \
	if ! version_at_least "$$sdk_version" "$(MINIMUM_MACOS_SDK_VERSION)"; then \
		echo "The macOS $(MINIMUM_MACOS_SDK_VERSION) SDK or newer is required; selected $$sdk_version." >&2; \
		exit 1; \
	fi; \
	xcrun swift package dump-package >/dev/null

format-check:
	xcrun swift-format lint \
		--configuration .swift-format \
		--strict \
		--parallel \
		--recursive \
		Package.swift App Sources Tests

format:
	xcrun swift-format format \
		--configuration .swift-format \
		--in-place \
		--parallel \
		--recursive \
		Package.swift App Sources Tests

project-check:
	plutil -lint App/Info.plist
	plutil -lint Rei.xcodeproj/project.pbxproj
	@set -e; \
	version="$$( $(MAKE) --no-print-directory release-version )"; \
	build_number="$$( $(MAKE) --no-print-directory release-build-number )"; \
	settings="$$(xcodebuild -showBuildSettings \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Release \
		-destination '$(BUILD_DESTINATION)' \
		CODE_SIGNING_ALLOWED=NO)"; \
	resolved_version="$$(printf '%s\n' "$$settings" | awk '/^[[:space:]]+MARKETING_VERSION = / { print $$3; exit }')"; \
	resolved_build_number="$$(printf '%s\n' "$$settings" | awk '/^[[:space:]]+CURRENT_PROJECT_VERSION = / { print $$3; exit }')"; \
	if [ "$$resolved_version" != "$$version" ] || [ "$$resolved_build_number" != "$$build_number" ]; then \
		echo "Xcode release metadata does not match $(VERSION_CONFIGURATION)." >&2; \
		exit 1; \
	fi; \
	onebot_version="$$(awk -F '"' '/public static let current = "[0-9]/ { value = $$2; count++ } END { if (count != 1) exit 1; print value }' Sources/ReiOneBot/OneBotAdapter.swift)"; \
	milky_version="$$(awk -F '"' '/"impl_version": "[0-9]/ { value = $$4; count++ } END { if (count != 1) exit 1; print value }' Sources/ReiMilky/MilkyActions.swift)"; \
	if [ "$$onebot_version" != "$$version" ] || [ "$$milky_version" != "$$version" ]; then \
		echo "Protocol implementation versions must match MARKETING_VERSION $$version." >&2; \
		exit 1; \
	fi

release-version:
	@set -e; \
	version="$$(awk -F '=' ' \
		/^[[:space:]]*MARKETING_VERSION[[:space:]]*=/ { \
			value = $$2; \
			sub(/\/\/.*/, "", value); \
			gsub(/[[:space:]]/, "", value); \
			print value; \
			count++; \
		} \
		END { if (count != 1) exit 1 } \
	' "$(VERSION_CONFIGURATION)")"; \
	printf '%s\n' "$$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; \
	printf '%s\n' "$$version"

release-build-number:
	@set -e; \
	build_number="$$(awk -F '=' ' \
		/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=/ { \
			value = $$2; \
			sub(/\/\/.*/, "", value); \
			gsub(/[[:space:]]/, "", value); \
			print value; \
			count++; \
		} \
		END { if (count != 1) exit 1 } \
	' "$(VERSION_CONFIGURATION)")"; \
	printf '%s\n' "$$build_number" | grep -Eq '^[1-9][0-9]*$$'; \
	printf '%s\n' "$$build_number"

release-metadata:
	@set -e; \
	version="$$( $(MAKE) --no-print-directory release-version )"; \
	build_number="$$( $(MAKE) --no-print-directory release-build-number )"; \
	printf 'version=%s\nbuild_number=%s\ntag=v%s\n' "$$version" "$$build_number" "$$version"

show-settings: verify-xcode
	xcodebuild -showBuildSettings \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(BUILD_CONFIGURATION)" \
		-destination '$(BUILD_DESTINATION)'

test: verify-xcode
	swift test -Xswiftc -warnings-as-errors

build: verify-xcode
	xcodebuild build \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(BUILD_CONFIGURATION)" \
		-destination '$(BUILD_DESTINATION)' \
		-derivedDataPath "$(DERIVED_DATA_PATH)" \
		ARCHS="$(BUILD_ARCHS)" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGNING_ALLOWED=NO

verify-universal:
	@set -e; \
	executable="$${APP_PATH}/Contents/MacOS/Rei"; \
	architectures="$$(lipo -archs "$$executable")"; \
	for required_architecture in arm64 x86_64; do \
		case " $$architectures " in \
			*" $$required_architecture "*) ;; \
			*) echo "Release executable is missing $$required_architecture: $$architectures" >&2; exit 1 ;; \
		esac; \
	done; \
	printf 'Release architectures: %s\n' "$$architectures"

analyze: verify-xcode
	xcodebuild analyze \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(BUILD_CONFIGURATION)" \
		-destination '$(BUILD_DESTINATION)' \
		-derivedDataPath "$(DERIVED_DATA_PATH)" \
		ARCHS="$(BUILD_ARCHS)" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGNING_ALLOWED=NO

archive: verify-xcode
	@set -eu; \
	set -- xcodebuild clean archive \
		-project "$$PROJECT" \
		-scheme "$$SCHEME" \
		-configuration "$$BUILD_CONFIGURATION" \
		-destination "$$BUILD_DESTINATION" \
		-derivedDataPath "$$DERIVED_DATA_PATH" \
		-archivePath "$$ARCHIVE_PATH" \
		"ARCHS=$$BUILD_ARCHS" \
		ONLY_ACTIVE_ARCH=NO; \
	if [ "$${ALLOW_PROVISIONING_UPDATES:-}" = YES ]; then set -- "$$@" -allowProvisioningUpdates; fi; \
	if [ -n "$${AUTHENTICATION_KEY_PATH:-}" ]; then set -- "$$@" -authenticationKeyPath "$$AUTHENTICATION_KEY_PATH"; fi; \
	if [ -n "$${AUTHENTICATION_KEY_ID:-}" ]; then set -- "$$@" -authenticationKeyID "$$AUTHENTICATION_KEY_ID"; fi; \
	if [ -n "$${AUTHENTICATION_KEY_ISSUER_ID:-}" ]; then set -- "$$@" -authenticationKeyIssuerID "$$AUTHENTICATION_KEY_ISSUER_ID"; fi; \
	if [ -n "$${CODE_SIGN_STYLE:-}" ]; then set -- "$$@" "CODE_SIGN_STYLE=$$CODE_SIGN_STYLE"; fi; \
	if [ -n "$${CODE_SIGN_IDENTITY:-}" ]; then set -- "$$@" "CODE_SIGN_IDENTITY=$$CODE_SIGN_IDENTITY"; fi; \
	if [ -n "$${DEVELOPMENT_TEAM:-}" ]; then set -- "$$@" "DEVELOPMENT_TEAM=$$DEVELOPMENT_TEAM"; fi; \
	if [ -n "$${CODE_SIGNING_ALLOWED:-}" ]; then set -- "$$@" "CODE_SIGNING_ALLOWED=$$CODE_SIGNING_ALLOWED"; fi; \
	"$$@"

export: verify-xcode
	@set -eu; \
	set -- xcodebuild -exportArchive \
		-archivePath "$$ARCHIVE_PATH" \
		-exportPath "$$EXPORT_PATH" \
		-exportOptionsPlist "$$EXPORT_OPTIONS_PLIST"; \
	if [ "$${ALLOW_PROVISIONING_UPDATES:-}" = YES ]; then set -- "$$@" -allowProvisioningUpdates; fi; \
	if [ -n "$${AUTHENTICATION_KEY_PATH:-}" ]; then set -- "$$@" -authenticationKeyPath "$$AUTHENTICATION_KEY_PATH"; fi; \
	if [ -n "$${AUTHENTICATION_KEY_ID:-}" ]; then set -- "$$@" -authenticationKeyID "$$AUTHENTICATION_KEY_ID"; fi; \
	if [ -n "$${AUTHENTICATION_KEY_ISSUER_ID:-}" ]; then set -- "$$@" -authenticationKeyIssuerID "$$AUTHENTICATION_KEY_ISSUER_ID"; fi; \
	"$$@"
