SHELL := /usr/bin/env bash

SCRIPTS := package-builder \
           lib/logging.sh \
           lib/parser.sh \
           lib/cli.sh \
           lib/container.sh \
           lib/builder.sh \
           lib/appimage.sh \
           lib/desktop.sh \
           container/build-package.sh \
           tests/test_parser.sh \
           tests/test_builder.sh

SHELLCHECK := shellcheck
SHELLCHECK_OPTS := --shell=bash --severity=warning

.PHONY: test lint lint-fix help

help:
	@echo "Targets:"
	@echo "  test      — run all tests"
	@echo "  lint      — check scripts with shellcheck"
	@echo "  lint-fix  — apply shellcheck auto-fixes (requires shellcheck >= 0.7)"

test:
	@echo "==> test_parser"
	@bash tests/test_parser.sh
	@echo ""
	@echo "==> test_builder"
	@bash tests/test_builder.sh

lint:
	@$(SHELLCHECK) $(SHELLCHECK_OPTS) $(SCRIPTS)

lint-fix:
	@for f in $(SCRIPTS); do \
	  $(SHELLCHECK) $(SHELLCHECK_OPTS) --format=diff "$$f" | patch -p1 && \
	  echo "fixed: $$f" || true; \
	done
