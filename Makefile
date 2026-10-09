SHELL := /bin/bash
.DEFAULT_GOAL := help

PERSONAL_REPO := abhinavm24/typewhisper-mac
FORCE ?= false

.PHONY: help sync-main release update check

help:
	@printf '%s\n' \
		'Run these commands from the personal-ci worktree:' \
		'  make sync-main          Fast-forward fork main from upstream on GitHub' \
		'  make release            Push a build request to personal-ci' \
		'  make release FORCE=true Rebuild even if these inputs have a release' \
		'  make update             Download, verify and install the latest personal DMG' \
		'  make check              Verify personal CI and installer tooling'

sync-main:
	gh repo sync "$(PERSONAL_REPO)" --branch main

release:
	bash scripts/request_personal_release.sh "$(FORCE)"

update:
	python3 scripts/update_personal.py

check:
	python3 -m unittest discover -s .github/personal-integration -p 'test_*.py' -v
	python3 scripts/test_request_personal_release.py
	python3 scripts/test_install_local.py
	python3 scripts/test_update_personal.py
	python3 scripts/test_personal_appcast.py
	bash -n scripts/request_personal_release.sh scripts/install_local.sh
	bash -n .github/personal-integration/build.sh .github/personal-integration/publish-feed.sh
