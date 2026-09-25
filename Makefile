SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT := TypeWhisper.xcodeproj
SCHEME := TypeWhisper
CONFIGURATION ?= Release
LOCAL_UID := $(shell id -u)
BUILD_DIR ?= $(CURDIR)/build-local-$(LOCAL_UID)
APP_DESTINATION ?= /Applications/TypeWhisper.app
APP_PATH := $(BUILD_DIR)/Build/Products/$(CONFIGURATION)/TypeWhisper.app
DMG_PATH ?= $(BUILD_DIR)/TypeWhisper-local-$(shell date +%Y%m%d-%H%M%S).dmg
BUILD_MARKER := $(BUILD_DIR)/.typewhisper-build-dir
BUILD_COMPLETE_MARKER := $(BUILD_DIR)/.typewhisper-build-complete
XCODEBUILD ?= xcodebuild
INSTALL_SUDO ?= sudo
# "auto" uses the first valid Apple Development certificate in the login
# keychain. Set this to a certificate name/hash, or "-" to force ad-hoc signing.
LOCAL_SIGNING_IDENTITY ?= auto

XCODE_COMMON := -skipPackagePluginValidation \
	-project "$(PROJECT)" \
	-scheme "$(SCHEME)" \
	CODE_SIGN_IDENTITY="-" \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGNING_ALLOWED=NO

.PHONY: help require-non-root prepare-build-dir require-built-app build dmg test test-sdk test-install test-update-personal check update update-local install install-dry-run reinstall run clean

help:
	@printf '%s\n' \
		'TypeWhisper local development commands:' \
		'  make update           Download and install the latest personal CI release' \
		'  make build            Build and sign the app into build-local-<uid>/' \
		'  make dmg              Package the completed app as a shareable local DMG' \
		'  make test             Run the macOS app test suite' \
		'  make test-sdk         Run Plugin SDK tests' \
		'  make check            Run app, SDK, and installer tests' \
		'  make install          Install the latest completed build (does not build)' \
		'  make install-dry-run  Preview installation of the latest completed build' \
		'  make reinstall        Alias for install' \
		'  make run              Open the installed app' \
		'  make clean            Remove repo-local build products' \
		'' \
		'Overrides:' \
		'  CONFIGURATION=Release BUILD_DIR=path APP_DESTINATION=path XCODEBUILD=path' \
		'  LOCAL_SIGNING_IDENTITY=auto  Prefer an Apple Development certificate' \
		'  LOCAL_SIGNING_IDENTITY="Apple Development: Name (TEAMID)"  Choose a certificate' \
		'  LOCAL_SIGNING_IDENTITY=-     Force ad-hoc signing (privacy grants may reset)' \
		'  INSTALL_SUDO=           Install without sudo when the destination is writable' \
		'' \
		'Workflow: run "make build", then "make install".' \
		'Do not run make with sudo; make install elevates only the app replacement.'

require-non-root:
	@if [[ "$$(id -u)" -eq 0 ]]; then \
		printf '%s\n' \
			'error: do not run make with sudo' \
			'error: run "make install" as your normal user; the installer elevates only when needed'; \
		exit 2; \
	fi

prepare-build-dir: require-non-root
	@mkdir -p "$(BUILD_DIR)"
	@resolved="$$(cd "$(BUILD_DIR)" && pwd -P)"; \
		repository="$$(pwd -P)"; \
		test "$$resolved" != "$$repository" || { \
			echo "error: BUILD_DIR cannot be the repository root" >&2; \
			exit 2; \
		}
	@foreign="$$(find "$(BUILD_DIR)" ! -user "$$(id -u)" -print -quit)"; \
		if [[ -n "$$foreign" ]]; then \
			printf '%s\n' \
				"error: BUILD_DIR contains files owned by another user: $$foreign" \
				'error: choose a clean BUILD_DIR or repair/remove that generated directory'; \
			exit 2; \
		fi
	@touch "$(BUILD_MARKER)"

build: prepare-build-dir
	@rm -f "$(BUILD_COMPLETE_MARKER)"
	@set -o pipefail; $(XCODEBUILD) build $(XCODE_COMMON) \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(BUILD_DIR)" \
		-destination 'generic/platform=macOS' \
		ENABLE_CODE_COVERAGE=NO | tee "$(BUILD_DIR)/build.log"
	@identity="$(LOCAL_SIGNING_IDENTITY)"; \
	if [[ "$$identity" == auto ]]; then \
		identity="$$(security find-identity -v -p codesigning 2>/dev/null | \
			awk '/"Apple Development:/{ print $$2; exit }')"; \
	fi; \
	if [[ -z "$$identity" ]]; then \
		identity=-; \
		printf '%s\n' \
			'warning: no Apple Development signing identity was found; using ad-hoc signing' \
			'warning: changed ad-hoc builds require fresh macOS privacy permission grants' \
			'warning: install an Apple Development certificate or set LOCAL_SIGNING_IDENTITY'; \
	fi; \
	if [[ "$$identity" == - ]]; then \
		printf 'signing (ad-hoc): %s\n' "$(APP_PATH)"; \
	else \
		printf 'signing (stable identity %s): %s\n' "$$identity" "$(APP_PATH)"; \
	fi; \
	codesign --force --deep --sign "$$identity" "$(APP_PATH)"
	@codesign --verify --deep --strict "$(APP_PATH)"
	@touch "$(BUILD_COMPLETE_MARKER)"
	@printf 'built: %s\n' "$(APP_PATH)"

test: prepare-build-dir
	@set -o pipefail; $(XCODEBUILD) test $(XCODE_COMMON) \
		-derivedDataPath "$(BUILD_DIR)" \
		-destination 'platform=macOS,arch=arm64' \
		-parallel-testing-enabled NO | tee "$(BUILD_DIR)/test.log"

test-sdk:
	swift test --package-path TypeWhisperPluginSDK

test-install:
	python3 scripts/test_install_local.py

test-update-personal:
	python3 scripts/test_update_personal.py

check: test test-sdk test-install test-update-personal

# Normal updates download a tested Release asset instead of compiling locally.
update: require-non-root
	python3 scripts/update_personal.py --destination "$(APP_DESTINATION)" --signing-identity "$(LOCAL_SIGNING_IDENTITY)"

update-local: update

require-built-app: require-non-root
	@test -f "$(BUILD_COMPLETE_MARKER)" && test -d "$(APP_PATH)" || { \
		echo "error: no completed build found in $(BUILD_DIR)" >&2; \
		echo "error: run 'make build' first" >&2; \
		exit 2; \
	}

dmg: require-built-app
	bash scripts/package_local_dmg.sh "$(APP_PATH)" "$(DMG_PATH)" "$(CURDIR)/LICENSE"

install: require-built-app
	@if pgrep -x TypeWhisper >/dev/null; then \
		osascript -e 'tell application "TypeWhisper" to quit' >/dev/null 2>&1 || true; \
		for _ in {1..20}; do \
			pgrep -x TypeWhisper >/dev/null || break; \
			sleep 0.25; \
		done; \
		pgrep -x TypeWhisper >/dev/null && { \
			echo "error: TypeWhisper is still running; quit it and retry" >&2; \
			exit 1; \
		} || true; \
	fi
	$(INSTALL_SUDO) scripts/install_local.sh --source "$(APP_PATH)" \
		--destination "$(APP_DESTINATION)" --skip-quit

install-dry-run: require-built-app
	scripts/install_local.sh --source "$(APP_PATH)" --destination "$(APP_DESTINATION)" --dry-run

reinstall: install

run:
	@test -d "$(APP_DESTINATION)" || { \
		echo "error: app not installed at $(APP_DESTINATION); run 'make install' first" >&2; \
		exit 1; \
	}
	open "$(APP_DESTINATION)"

clean:
	@test -f "$(BUILD_MARKER)" || { \
		echo "error: refusing to clean unmarked BUILD_DIR: $(BUILD_DIR)" >&2; \
		exit 2; \
	}
	@resolved="$$(cd "$(BUILD_DIR)" && pwd -P)"; \
		repository="$$(pwd -P)"; \
		test "$$resolved" != "$$repository" || { \
			echo "error: refusing to remove repository root" >&2; \
			exit 2; \
		}
	rm -rf "$(BUILD_DIR)"
