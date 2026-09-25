SWIFT ?= swift
SWIFT_SOURCES = Sources Tests Package.swift

.PHONY: build test run app open lint format l10n clean help

build: ## Build all targets
	$(SWIFT) build

test: ## Run the test suite
	$(SWIFT) test

run: ## Build and launch Momo from the command line (English UI only)
	$(SWIFT) run Momo

app: ## Build dist/Momo.app with all localizations
	./Scripts/build-app.sh

open: app ## Build and open dist/Momo.app
	open dist/Momo.app

lint: ## Check formatting
	$(SWIFT) format lint --strict --recursive $(SWIFT_SOURCES)

l10n: ## Check that every user-facing string is translated
	./Scripts/check-localizations.py

format: ## Format the code in place
	$(SWIFT) format --in-place --recursive $(SWIFT_SOURCES)

clean: ## Remove build products
	rm -rf .build dist

help: ## List the available targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'
