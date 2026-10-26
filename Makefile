SHELL := /bin/bash

.PHONY: check build package verify full help
.DEFAULT_GOAL := help

help:
	@echo "make check    Fast core checks, production app build and basic verification"
	@echo "make package  Build once and package a native DMG"
	@echo "make verify   Verify an existing native DMG, including historical upgrade/rollback"
	@echo "make full     Run the complete native regression suite (manual, longer)"

check:
	bash scripts/test-core.sh
	bash scripts/build-app.sh
	bash scripts/verify-app.sh

build:
	bash scripts/build-app.sh

package:
	bash scripts/build-app.sh
	bash scripts/package-dmg.sh

verify:
	bash scripts/verify-package.sh

# Full coverage is an explicit manual entry, independent of CI scheduling policy.
# Each fixture remains a separate process; no test assertions are discarded.
full:
	@set -euo pipefail; \
	for script in \
		test-task-status \
		test-hook-integration \
		test-token-usage \
		test-task-reliability \
		test-account-token-usage \
		test-verified-quota \
		test-quota-alerts \
		test-host-auto-launcher \
		test-connection-diagnostics \
		test-diagnostic-logging \
		test-diagnostic-upgrade-storage \
		test-diagnostic-upgrade-installer \
		test-diagnostic-upgrade-recovery \
		test-host-lifecycle \
		test-app-termination \
		test-single-instance \
		test-app-update \
		test-app-update-progress \
		test-github-release-fallback \
		test-app-update-notifications \
		test-reset-news-runtime \
		test-hooks \
		test-hud-material \
		test-idle-performance \
		test-status-menu \
		test-notch-hud \
		test-notch-presentation \
		test-touchbar \
		test-touchbar-layout \
		test-design-layout; do \
		echo "Running $$script"; \
		if [[ "$$script" == test-reset-news-runtime ]]; then \
			RESET_NEWS_CORE_DIR="$${RUNNER_TEMP:-$(CURDIR)/.build}/reset-news-core-runtime-$$(uname -m)" \
				bash "scripts/$$script.sh"; \
		else \
			bash "scripts/$$script.sh"; \
		fi; \
	done
